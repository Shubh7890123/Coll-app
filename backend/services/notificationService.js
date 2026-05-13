const crypto = require('crypto');
const { supabaseAdmin } = require('../config/supabase');

const NOTIFICATION_TYPES = new Set([
  'dm_message',
  'group_message',
  'friend_request',
  'friend_accept',
  'group_invite',
  'mention',
  'audio_call',
  'video_call',
  'voice_call',
  'missed_call',
  'system_alert',
  'silent_sync',
]);

function truncate(text, limit = 120) {
  if (!text) return '';
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}

function base64UrlEncode(value) {
  return Buffer.from(value)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function normalizePrivateKey(rawKey = '') {
  return rawKey.replace(/\\n/g, '\n').trim();
}

async function getGoogleAccessToken() {
  const clientEmail = process.env.FIREBASE_CLIENT_EMAIL;
  const privateKey = normalizePrivateKey(process.env.FIREBASE_PRIVATE_KEY);

  if (!clientEmail || !privateKey || !process.env.FIREBASE_PROJECT_ID) {
    throw new Error('Firebase service account env vars are not configured');
  }

  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlEncode(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = base64UrlEncode(JSON.stringify({
    iss: clientEmail,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));

  const signer = crypto.createSign('RSA-SHA256');
  const unsignedJwt = `${header}.${payload}`;
  signer.update(unsignedJwt);
  signer.end();
  const signature = signer.sign(privateKey, 'base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsignedJwt}.${signature}`,
    }),
  });

  const json = await response.json();
  if (!response.ok || !json.access_token) {
    throw new Error(`Google OAuth error: ${JSON.stringify(json)}`);
  }

  return json.access_token;
}

function resolvePreferenceKey(type) {
  switch (type) {
    case 'dm_message':
      return 'dm_notifications';
    case 'group_message':
    case 'group_invite':
      return 'group_notifications';
    case 'friend_request':
    case 'friend_accept':
      return 'friend_request_notifications';
    case 'mention':
      return 'mention_notifications';
    case 'audio_call':
    case 'voice_call':
    case 'video_call':
    case 'missed_call':
      return 'call_notifications';
    default:
      return null;
  }
}

function getFcmChannel(type) {
  switch (type) {
    case 'dm_message':
      return 'dm_messages';
    case 'group_message':
    case 'mention':
      return 'group_activity';
    case 'friend_request':
    case 'friend_accept':
      return 'friend_activity';
    case 'audio_call':
    case 'voice_call':
    case 'video_call':
    case 'missed_call':
      return 'calls';
    default:
      return 'general';
  }
}

async function ensureSettings(receiverId) {
  const { data } = await supabaseAdmin
    .from('notification_settings')
    .select('*')
    .eq('user_id', receiverId)
    .maybeSingle();

  if (data) return data;

  const { data: inserted, error } = await supabaseAdmin
    .from('notification_settings')
    .insert({ user_id: receiverId })
    .select('*')
    .single();

  if (error) throw error;
  return inserted;
}

async function getUserDevices(receiverId) {
  const { data, error } = await supabaseAdmin
    .from('user_device_tokens')
    .select('id, user_id, fcm_token, device_type, last_seen_at, invalidated_at')
    .eq('user_id', receiverId)
    .is('invalidated_at', null);

  if (error) throw error;
  return data || [];
}

async function createNotificationRecord({
  senderId,
  receiverId,
  type,
  title,
  body,
  data,
  groupedCount = 1,
  groupKey = null,
}) {
  const payload = {
    sender_id: senderId || null,
    receiver_id: receiverId,
    type,
    title,
    body,
    data: data || {},
    is_read: false,
    grouped_count: groupedCount,
    group_key: groupKey,
  };

  const { data: inserted, error } = await supabaseAdmin
    .from('notifications')
    .insert(payload)
    .select('*')
    .single();

  if (error) throw error;
  return inserted;
}

function buildGroupKey({ type, senderId, receiverId, data }) {
  if (type === 'dm_message') {
    return `${type}:${receiverId}:${senderId}:${data?.chatId || data?.conversationId || 'default'}`;
  }
  if (type === 'group_message') {
    return `${type}:${receiverId}:${data?.groupId || 'group'}`;
  }
  return null;
}

async function groupNotificationIfNeeded({ senderId, receiverId, type, title, body, data }) {
  const groupKey = buildGroupKey({ type, senderId, receiverId, data });
  if (!groupKey) {
    return createNotificationRecord({ senderId, receiverId, type, title, body, data });
  }

  const fiveMinutesAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString();

  const { data: existing, error } = await supabaseAdmin
    .from('notifications')
    .select('*')
    .eq('receiver_id', receiverId)
    .eq('type', type)
    .eq('group_key', groupKey)
    .eq('is_read', false)
    .gte('created_at', fiveMinutesAgo)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  if (!existing) {
    return createNotificationRecord({
      senderId,
      receiverId,
      type,
      title,
      body,
      data,
      groupKey,
    });
  }

  const groupedCount = (existing.grouped_count || 1) + 1;
  const groupedBody = type === 'dm_message'
    ? `${title} sent ${groupedCount} new messages`
    : body;

  const { data: updated, error: updateError } = await supabaseAdmin
    .from('notifications')
    .update({
      body: groupedBody,
      data: { ...existing.data, ...data, groupedCount },
      grouped_count: groupedCount,
      updated_at: new Date().toISOString(),
    })
    .eq('id', existing.id)
    .select('*')
    .single();

  if (updateError) throw updateError;
  return updated;
}

async function recordAttempt(notificationId, deviceTokenId, status, providerResponse = null, errorMessage = null) {
  const { error } = await supabaseAdmin
    .from('notification_delivery_attempts')
    .insert({
      notification_id: notificationId,
      device_token_id: deviceTokenId,
      status,
      provider_response: providerResponse,
      error_message: errorMessage,
    });

  if (error) {
    console.error('Failed to record notification attempt', error);
  }
}

async function invalidateDeviceToken(deviceTokenId) {
  const { error } = await supabaseAdmin
    .from('user_device_tokens')
    .update({
      invalidated_at: new Date().toISOString(),
    })
    .eq('id', deviceTokenId);

  if (error) {
    console.error('Failed to invalidate device token', error);
  }
}

async function sendPushToDevices({ devices, title, body, data, badgeCount, type, notificationId }) {
  if (!devices.length) {
    return { delivered: 0, failed: 0 };
  }

  const accessToken = await getGoogleAccessToken();
  const projectId = process.env.FIREBASE_PROJECT_ID;
  const results = { delivered: 0, failed: 0 };

  for (const device of devices) {
    const message = {
      message: {
        token: device.fcm_token,
        notification: {
          title,
          body,
        },
        data: Object.fromEntries(
          Object.entries({
            ...data,
            notificationId,
            type,
          }).map(([key, value]) => [key, String(value ?? '')]),
        ),
        android: {
          priority: 'high',
          notification: {
            channel_id: getFcmChannel(type),
            click_action: 'FLUTTER_NOTIFICATION_CLICK',
          },
        },
        apns: {
          payload: {
            aps: {
              sound: 'default',
              badge: badgeCount,
            },
          },
        },
      },
    };

    let responseJson = null;
    let success = false;
    let errorMessage = null;

    for (let attempt = 0; attempt < 2; attempt += 1) {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${accessToken}`,
          },
          body: JSON.stringify(message),
        },
      );

      responseJson = await response.json();

      if (response.ok) {
        success = true;
        break;
      }

      errorMessage = responseJson?.error?.message || 'Unknown push error';
      const status = responseJson?.error?.status;
      if (status === 'NOT_FOUND' || status === 'UNREGISTERED') {
        await invalidateDeviceToken(device.id);
        break;
      }

      if (response.status >= 500 && attempt === 0) {
        await new Promise((resolve) => setTimeout(resolve, 500));
        continue;
      }
      break;
    }

    if (success) {
      results.delivered += 1;
      await recordAttempt(notificationId, device.id, 'sent', responseJson, null);
    } else {
      results.failed += 1;
      await recordAttempt(notificationId, device.id, 'failed', responseJson, errorMessage);
    }
  }

  return results;
}

function extractPreview(body, type) {
  if (type === 'silent_sync') {
    return '';
  }
  return truncate(body, 180);
}

function createNotificationService({ socketGateway = null } = {}) {
  return {
    async sendNotification({
      receiverId,
      senderId = null,
      type,
      title,
      body,
      data = {},
      options = {},
    }) {
      if (!receiverId) throw new Error('receiverId is required');
      if (!NOTIFICATION_TYPES.has(type)) {
        throw new Error(`Unsupported notification type: ${type}`);
      }

      const settings = await ensureSettings(receiverId);
      const preferenceKey = resolvePreferenceKey(type);
      const pushEnabled = preferenceKey ? settings[preferenceKey] !== false : true;
      const online = socketGateway ? socketGateway.isUserOnline(receiverId) : false;

      const notification = await groupNotificationIfNeeded({
        senderId,
        receiverId,
        type,
        title,
        body: extractPreview(body, type),
        data,
      });

      const { count: unreadCount } = await supabaseAdmin
        .from('notifications')
        .select('*', { count: 'exact', head: true })
        .eq('receiver_id', receiverId)
        .eq('is_read', false);

      if (socketGateway) {
        socketGateway.emitToUser(receiverId, 'notifications:new', notification);
        socketGateway.emitToUser(receiverId, 'notifications:badge', {
          unreadCount: unreadCount || 0,
        });
      }

      if (options.socketOnlyWhenOnline && online) {
        return {
          notification,
          delivered: { socket: true, push: false },
        };
      }

      if (!pushEnabled && type !== 'silent_sync') {
        return {
          notification,
          delivered: { socket: online, push: false, skippedByPreference: true },
        };
      }

      const devices = await getUserDevices(receiverId);
      const pushResult = await sendPushToDevices({
        devices,
        title,
        body: extractPreview(body, type),
        data,
        badgeCount: unreadCount || 0,
        type,
        notificationId: notification.id,
      });

      return {
        notification,
        delivered: {
          socket: online,
          push: pushResult.delivered > 0,
          pushResult,
        },
      };
    },

    async markAsRead({ notificationId, userId }) {
      const { data, error } = await supabaseAdmin
        .from('notifications')
        .update({
          is_read: true,
          read_at: new Date().toISOString(),
        })
        .eq('id', notificationId)
        .eq('receiver_id', userId)
        .select('*')
        .single();

      if (error) throw error;
      return data;
    },

    async markAllAsRead(userId) {
      const { error } = await supabaseAdmin
        .from('notifications')
        .update({
          is_read: true,
          read_at: new Date().toISOString(),
        })
        .eq('receiver_id', userId)
        .eq('is_read', false);

      if (error) throw error;
    },

    async clearAll(userId) {
      const { error } = await supabaseAdmin
        .from('notifications')
        .delete()
        .eq('receiver_id', userId);

      if (error) throw error;
    },
  };
}

module.exports = {
  createNotificationService,
  truncate,
};
