const express = require('express');
const { supabaseAdmin } = require('../config/supabase');

function createNotificationsRouter({ notificationService }) {
  const router = express.Router();

  router.post('/device-tokens', async (req, res) => {
    try {
      const { fcmToken, deviceType, deviceId, appVersion } = req.body;
      if (!fcmToken || !deviceId) {
        return res.status(400).json({
          success: false,
          message: 'fcmToken and deviceId are required',
        });
      }

      const payload = {
        user_id: req.user.id,
        fcm_token: fcmToken,
        device_type: deviceType || 'unknown',
        device_id: deviceId,
        app_version: appVersion || null,
        last_seen_at: new Date().toISOString(),
        invalidated_at: null,
        updated_at: new Date().toISOString(),
      };

      const { data, error } = await supabaseAdmin
        .from('user_device_tokens')
        .upsert(payload, { onConflict: 'user_id,device_id' })
        .select('*')
        .single();

      if (error) throw error;
      res.status(200).json({ success: true, data });
    } catch (error) {
      console.error('Failed to save device token', error);
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.delete('/device-tokens/:deviceId', async (req, res) => {
    try {
      const { deviceId } = req.params;
      const { error } = await supabaseAdmin
        .from('user_device_tokens')
        .delete()
        .eq('user_id', req.user.id)
        .eq('device_id', deviceId);

      if (error) throw error;
      res.status(200).json({ success: true });
    } catch (error) {
      console.error('Failed to delete device token', error);
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.get('/settings', async (req, res) => {
    try {
      const { data, error } = await supabaseAdmin
        .from('notification_settings')
        .select('*')
        .eq('user_id', req.user.id)
        .maybeSingle();

      if (error) throw error;
      res.status(200).json({
        success: true,
        data: data || {
          user_id: req.user.id,
          dm_notifications: true,
          group_notifications: true,
          friend_request_notifications: true,
          mention_notifications: true,
          call_notifications: true,
        },
      });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.put('/settings', async (req, res) => {
    try {
      const updates = {
        user_id: req.user.id,
        dm_notifications: req.body.dmNotifications,
        group_notifications: req.body.groupNotifications,
        friend_request_notifications: req.body.friendRequestNotifications,
        mention_notifications: req.body.mentionNotifications,
        call_notifications: req.body.callNotifications,
        updated_at: new Date().toISOString(),
      };

      const cleanedUpdates = Object.fromEntries(
        Object.entries(updates).filter(([, value]) => value !== undefined),
      );

      const { data, error } = await supabaseAdmin
        .from('notification_settings')
        .upsert(cleanedUpdates, { onConflict: 'user_id' })
        .select('*')
        .single();

      if (error) throw error;
      res.status(200).json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.get('/', async (req, res) => {
    try {
      const limit = Math.min(parseInt(req.query.limit, 10) || 20, 50);
      const offset = Math.max(parseInt(req.query.offset, 10) || 0, 0);

      const { data, error } = await supabaseAdmin
        .from('notifications')
        .select('*, sender:profiles!notifications_sender_id_fkey(id, username, display_name, avatar_url)')
        .eq('receiver_id', req.user.id)
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (error) throw error;
      res.status(200).json({ success: true, data: data || [], nextOffset: offset + limit });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.get('/unread-count', async (req, res) => {
    try {
      const { count, error } = await supabaseAdmin
        .from('notifications')
        .select('*', { count: 'exact', head: true })
        .eq('receiver_id', req.user.id)
        .eq('is_read', false);

      if (error) throw error;
      res.status(200).json({ success: true, count: count || 0 });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.patch('/:notificationId/read', async (req, res) => {
    try {
      const data = await notificationService.markAsRead({
        notificationId: req.params.notificationId,
        userId: req.user.id,
      });
      res.status(200).json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.post('/read-all', async (req, res) => {
    try {
      await notificationService.markAllAsRead(req.user.id);
      res.status(200).json({ success: true });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.delete('/clear', async (req, res) => {
    try {
      await notificationService.clearAll(req.user.id);
      res.status(200).json({ success: true });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.post('/send', async (req, res) => {
    try {
      const result = await notificationService.sendNotification({
        receiverId: req.body.receiverId,
        senderId: req.user.id,
        type: req.body.type,
        title: req.body.title,
        body: req.body.body,
        data: req.body.data || {},
        options: req.body.options || {},
      });

      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(400).json({ success: false, message: error.message });
    }
  });

  return router;
}

module.exports = { createNotificationsRouter };
