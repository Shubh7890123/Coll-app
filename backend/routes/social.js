const express = require('express');
const { supabaseAdmin } = require('../config/supabase');
const { truncate } = require('../services/notificationService');

function extractMentions(content = '') {
  const matches = content.match(/@([a-zA-Z0-9_.]+)/g) || [];
  return [...new Set(matches.map((match) => match.slice(1).toLowerCase()))];
}

function createSocialRouter({ notificationService, socketGateway }) {
  const router = express.Router();

  router.post('/friend-requests', async (req, res) => {
    try {
      const { receiverId } = req.body;
      if (!receiverId) {
        return res.status(400).json({ success: false, message: 'receiverId is required' });
      }

      const { data: existing } = await supabaseAdmin
        .from('waves')
        .select('id, status')
        .eq('sender_id', req.user.id)
        .eq('receiver_id', receiverId)
        .maybeSingle();

      if (existing) {
        return res.status(200).json({ success: true, data: existing, duplicate: true });
      }

      const { data: wave, error } = await supabaseAdmin
        .from('waves')
        .insert({
          sender_id: req.user.id,
          receiver_id: receiverId,
        })
        .select('*')
        .single();

      if (error) throw error;

      const { data: senderProfile } = await supabaseAdmin
        .from('profiles')
        .select('username, display_name')
        .eq('id', req.user.id)
        .maybeSingle();

      const senderName = senderProfile?.display_name || senderProfile?.username || 'Someone';

      await notificationService.sendNotification({
        receiverId,
        senderId: req.user.id,
        type: 'friend_request',
        title: 'New Friend Request',
        body: `${senderName} sent you a request`,
        data: {
          type: 'friend_request',
          screen: 'friend_requests',
          senderId: req.user.id,
          waveId: wave.id,
        },
      });

      res.status(201).json({ success: true, data: wave });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.post('/friend-requests/:waveId/respond', async (req, res) => {
    try {
      const { waveId } = req.params;
      const { action } = req.body;
      if (!['accepted', 'rejected'].includes(action)) {
        return res.status(400).json({ success: false, message: 'action must be accepted or rejected' });
      }

      const { data: wave, error: waveError } = await supabaseAdmin
        .from('waves')
        .update({
          status: action,
          responded_at: new Date().toISOString(),
        })
        .eq('id', waveId)
        .eq('receiver_id', req.user.id)
        .select('*')
        .single();

      if (waveError) throw waveError;

      if (action === 'accepted') {
        const { data: receiverProfile } = await supabaseAdmin
          .from('profiles')
          .select('username, display_name')
          .eq('id', req.user.id)
          .maybeSingle();

        const receiverName = receiverProfile?.display_name || receiverProfile?.username || 'Someone';

        await notificationService.sendNotification({
          receiverId: wave.sender_id,
          senderId: req.user.id,
          type: 'friend_accept',
          title: 'Friend Request Accepted',
          body: `${receiverName} accepted your request`,
          data: {
            type: 'friend_accept',
            screen: 'chat',
            userId: req.user.id,
          },
        });
      }

      res.status(200).json({ success: true, data: wave });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.post('/groups/:groupId/invites', async (req, res) => {
    try {
      const { groupId } = req.params;
      const { receiverId } = req.body;
      if (!receiverId) {
        return res.status(400).json({ success: false, message: 'receiverId is required' });
      }

      const { data: group, error } = await supabaseAdmin
        .from('groups')
        .select('id, name')
        .eq('id', groupId)
        .single();

      if (error) throw error;

      await notificationService.sendNotification({
        receiverId,
        senderId: req.user.id,
        type: 'group_invite',
        title: 'Group Invitation',
        body: `You were invited to ${group.name}`,
        data: {
          type: 'group_invite',
          screen: 'group_invitations',
          groupId: group.id,
          groupName: group.name,
        },
      });

      res.status(200).json({ success: true });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.post('/groups/:groupId/messages', async (req, res) => {
    try {
      const { groupId } = req.params;
      const { content } = req.body;
      if (!content?.trim()) {
        return res.status(400).json({ success: false, message: 'content is required' });
      }

      const { data: message, error: insertError } = await supabaseAdmin
        .from('group_messages')
        .insert({
          group_id: groupId,
          sender_id: req.user.id,
          content: content.trim(),
        })
        .select('*')
        .single();

      if (insertError) throw insertError;

      const [{ data: group }, { data: members }, { data: sender }] = await Promise.all([
        supabaseAdmin.from('groups').select('id, name').eq('id', groupId).single(),
        supabaseAdmin.from('group_members').select('user_id').eq('group_id', groupId).neq('user_id', req.user.id),
        supabaseAdmin.from('profiles').select('id, username, display_name').eq('id', req.user.id).single(),
      ]);

      const senderName = sender?.display_name || sender?.username || 'Member';
      const preview = truncate(content.trim(), 80);

      for (const member of members || []) {
        await notificationService.sendNotification({
          receiverId: member.user_id,
          senderId: req.user.id,
          type: 'group_message',
          title: group?.name || 'Group',
          body: `${senderName}: ${preview}`,
          data: {
            type: 'group_message',
            screen: 'group_chat',
            groupId,
            messageId: message.id,
            senderId: req.user.id,
          },
          options: {
            socketOnlyWhenOnline: true,
          },
        });
      }

      const mentions = extractMentions(content);
      if (mentions.length) {
        const { data: mentionedUsers } = await supabaseAdmin
          .from('profiles')
          .select('id, username')
          .in('username', mentions);

        for (const mentionedUser of mentionedUsers || []) {
          if (mentionedUser.id === req.user.id) continue;
          await notificationService.sendNotification({
            receiverId: mentionedUser.id,
            senderId: req.user.id,
            type: 'mention',
            title: 'Mentioned in group',
            body: `${senderName} mentioned you`,
            data: {
              type: 'mention',
              screen: 'group_chat',
              groupId,
              messageId: message.id,
              jumpToMessageId: message.id,
            },
          });
        }
      }

      if (socketGateway) {
        socketGateway.io.to(`chat:${groupId}`).emit('group:message', message);
      }

      res.status(201).json({ success: true, data: message });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.post('/calls/ring', async (req, res) => {
    try {
      const { receiverId, conversationId, isVideo, callId } = req.body;
      if (!receiverId || !conversationId || !callId) {
        return res.status(400).json({ success: false, message: 'receiverId, conversationId and callId are required' });
      }

      const { data: sender } = await supabaseAdmin
        .from('profiles')
        .select('display_name, username, avatar_url')
        .eq('id', req.user.id)
        .single();

      const senderName = sender?.display_name || sender?.username || 'Someone';
      const type = isVideo ? 'video_call' : 'voice_call';

      const result = await notificationService.sendNotification({
        receiverId,
        senderId: req.user.id,
        type,
        title: 'Incoming Call',
        body: `${senderName} is calling you`,
        data: {
          type,
          screen: 'call',
          callId,
          conversationId,
          senderId: req.user.id,
          callerName: senderName,
          callerAvatar: sender?.avatar_url,
          action: 'incoming_call',
        },
      });

      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  return router;
}

module.exports = { createSocialRouter };
