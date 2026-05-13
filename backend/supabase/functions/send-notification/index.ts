import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function base64UrlEncode(input: string): string {
  return btoa(input)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const raw = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\n/g, '')
    .replace(/\r/g, '')
    .trim();

  const binary = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    'pkcs8',
    binary.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

async function getGoogleAccessToken(): Promise<string> {
  const clientEmail = Deno.env.get('FIREBASE_CLIENT_EMAIL')!;
  const privateKey = Deno.env.get('FIREBASE_PRIVATE_KEY')!;
  const projectId = Deno.env.get('FIREBASE_PROJECT_ID')!;

  if (!clientEmail || !privateKey || !projectId) {
    throw new Error('Missing Firebase env vars');
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

  const unsignedJwt = `${header}.${payload}`;
  const key = await importPrivateKey(privateKey.replace(/\\n/g, '\n'));
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(unsignedJwt),
  );
  const signature = base64UrlEncode(String.fromCharCode(...new Uint8Array(sig)));
  const assertion = `${unsignedJwt}.${signature}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });

  const json = await res.json();
  if (!res.ok || !json.access_token) {
    throw new Error(`Google OAuth error: ${JSON.stringify(json)}`);
  }
  return json.access_token;
}

async function verifyAuth(req: Request): Promise<string | null> {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return null;
  const token = authHeader.substring(7);
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user.id;
}

function getChannelId(type?: string): string {
  if (type === 'friend_request' || type === 'friend_accept') return 'friend_activity';
  if (type === 'dm_message') return 'dm_messages';
  if (type === 'audio_call' || type === 'voice_call' || type === 'video_call' || type === 'missed_call') return 'calls';
  if (type === 'group_message' || type === 'group_invite' || type === 'mention') return 'group_activity';
  return 'general_channel';
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Method not allowed' }), {
        status: 405,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const callerId = await verifyAuth(req);
    if (!callerId) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const { target_user_id, title, body, data } = await req.json();
    if (!target_user_id || !title || !body) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // Fetch target user's FCM tokens
    const { data: tokenRows, error: tokenError } = await sb
      .from('user_device_tokens')
      .select('id, fcm_token')
      .eq('user_id', target_user_id)
      .is('invalidated_at', null)
      .not('fcm_token', 'is', null);

    if (tokenError || !tokenRows || tokenRows.length === 0) {
      return new Response(JSON.stringify({ message: 'No FCM tokens for user' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Fetch sender profile for notification data
    const senderId = data?.sender_id as string | undefined;
    let senderName = 'User';
    let senderAvatar = '';
    if (senderId) {
      const { data: profile } = await sb
        .from('profiles')
        .select('display_name, username, avatar_url')
        .eq('id', senderId)
        .single();
      if (profile) {
        senderName = profile.display_name || profile.username || 'User';
        senderAvatar = profile.avatar_url || '';
      }
    }

    const accessToken = await getGoogleAccessToken();
    const projectId = Deno.env.get('FIREBASE_PROJECT_ID')!;
    const invalidTokenIds: string[] = [];
    const results: unknown[] = [];

    // Build data payload — all values must be strings for FCM
    const stringData: Record<string, string> = {
      click_action: 'FLUTTER_NOTIFICATION_CLICK',
      sender_name: senderName,
      sender_avatar: senderAvatar,
    };
    if (data) {
      for (const [k, v] of Object.entries(data)) {
        stringData[k] = String(v ?? '');
      }
    }

    const channelId = getChannelId(data?.type as string | undefined);

    for (const row of tokenRows) {
      const payload = {
        message: {
          token: row.fcm_token,
          notification: { title, body },
          data: stringData,
          android: {
            priority: 'high' as const,
            notification: { channel_id: channelId },
          },
          apns: {
            payload: {
              aps: { sound: 'default', badge: 1 },
            },
          },
        },
      };

      let ok = false;
      let result: unknown = null;

      // Retry once on 5xx
      for (let attempt = 0; attempt < 2; attempt++) {
        const fcmRes = await fetch(
          `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
          {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify(payload),
          },
        );

        result = await fcmRes.json();

        if (fcmRes.ok) {
          ok = true;
          break;
        }

        const errObj = (result as Record<string, unknown>)?.error as Record<string, unknown> | undefined;
        const errMsg = String(errObj?.message ?? '');
        const errStatus = errObj?.status as string | undefined;

        // Token is invalid — remove it
        if (
          errStatus === 'NOT_FOUND' ||
          errStatus === 'UNREGISTERED' ||
          errMsg.includes('not a valid FCM') ||
          errMsg.includes('not found')
        ) {
          invalidTokenIds.push(row.id);
          break;
        }

        // Retry on server error
        if (fcmRes.status >= 500 && attempt === 0) {
          await new Promise((r) => setTimeout(r, 500));
          continue;
        }

        break;
      }

      results.push({ token_id: row.id, ok, result });
    }

    // Clean up invalid tokens
    if (invalidTokenIds.length > 0) {
      await sb
        .from('user_device_tokens')
        .update({ invalidated_at: new Date().toISOString() })
        .in('id', invalidTokenIds);
    }

    return new Response(
      JSON.stringify({
        success: true,
        total: tokenRows.length,
        removed: invalidTokenIds.length,
        results,
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  } catch (error) {
    console.error('Error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: String(error) }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
