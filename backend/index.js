require('dotenv').config();
const express = require('express');
const http = require('http');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const swaggerUi = require('swagger-ui-express');
const YAML = require('yamljs');
const path = require('path');
const { supabase, supabaseAdmin, supabaseUrl } = require('./config/supabase');
const { createSocketGateway } = require('./services/socketGateway');
const { createNotificationService, truncate } = require('./services/notificationService');
const { createCallService } = require('./services/callService');
const { createWebrtcSignalingService } = require('./services/webrtcSignalingService');
const { createNotificationsRouter } = require('./routes/notifications');
const { createSocialRouter } = require('./routes/social');
const { createCallsRouter } = require('./routes/calls');

const app = express();
const server = http.createServer(app);
const PORT = process.env.PORT || 3000;
const FRONTEND_URL = process.env.FRONTEND_URL || 'http://localhost:3000';
const socketGateway = createSocketGateway(server, { corsOrigin: FRONTEND_URL });
const notificationService = createNotificationService({ socketGateway });
const callService = createCallService({ socketGateway, notificationService });
createWebrtcSignalingService({ socketGateway });

const swaggerDocument = YAML.load(path.join(__dirname, 'swagger.yaml'));

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function validateUUID(...params) {
  return (req, res, next) => {
    for (const p of params) {
      const value = req.params[p];
      if (value && !UUID_REGEX.test(value)) {
        return res.status(400).json({
          success: false,
          message: `Invalid ${p}: must be a valid UUID`,
        });
      }
    }
    next();
  };
}

async function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ success: false, message: 'Authorization header required' });
  }
  const token = authHeader.split(' ')[1];
  if (!token) {
    return res.status(401).json({ success: false, message: 'No token provided' });
  }
  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !data.user) {
    return res.status(401).json({ success: false, message: 'Invalid or expired token' });
  }
  req.user = data.user;
  req.token = token;
  next();
}

app.use(helmet());
app.use(cors({ origin: FRONTEND_URL, credentials: true }));
app.use(morgan('dev'));
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));

const rateLimitMap = new Map();

// Import routes
const searchRoutes = require('./routes/search');

// Register routes
app.use('/api/search', requireAuth, searchRoutes);
app.use('/api/notifications', requireAuth, createNotificationsRouter({ notificationService }));
app.use('/api/social', requireAuth, createSocialRouter({ notificationService, socketGateway }));
const callsRouter = createCallsRouter({ callService });
app.use('/api/calls', requireAuth, callsRouter);
app.post('/start-call', requireAuth, async (req, res) => {
  try {
    const callerId = req.body.callerId || req.user.id;
    if (callerId !== req.user.id) return res.status(403).json({ success: false, message: 'callerId must match authenticated user' });
    const result = await callService.startCall({ callerId, receiverId: req.body.receiverId, callType: req.body.callType });
    res.status(201).json({ success: true, callId: result.callId, data: result });
  } catch (error) {
    res.status(error.message.includes('busy') ? 409 : 400).json({ success: false, message: error.message });
  }
});
app.post('/accept-call', requireAuth, async (req, res) => {
  try {
    const data = await callService.acceptCall({ callId: req.body.callId, userId: req.user.id });
    res.status(200).json({ success: true, data });
  } catch (error) {
    res.status(400).json({ success: false, message: error.message });
  }
});
app.post('/reject-call', requireAuth, async (req, res) => {
  try {
    const data = await callService.rejectCall({ callId: req.body.callId, userId: req.user.id });
    res.status(200).json({ success: true, data });
  } catch (error) {
    res.status(400).json({ success: false, message: error.message });
  }
});
app.post('/cancel-call', requireAuth, async (req, res) => {
  try {
    const data = await callService.cancelCall({ callId: req.body.callId, userId: req.user.id });
    res.status(200).json({ success: true, data });
  } catch (error) {
    res.status(400).json({ success: false, message: error.message });
  }
});
app.post('/end-call', requireAuth, async (req, res) => {
  try {
    const data = await callService.endCall({ callId: req.body.callId, userId: req.user.id });
    res.status(200).json({ success: true, data });
  } catch (error) {
    res.status(400).json({ success: false, message: error.message });
  }
});
function rateLimit({ windowMs = 60_000, max = 30 } = {}) {
  return (req, res, next) => {
    const key = req.ip + req.path;
    const now = Date.now();
    const entry = rateLimitMap.get(key);
    if (!entry || now - entry.resetAt > windowMs) {
      rateLimitMap.set(key, { count: 1, resetAt: now });
      return next();
    }
    if (entry.count >= max) {
      return res.status(429).json({ success: false, message: 'Too many requests, please try again later' });
    }
    entry.count++;
    next();
  };
}

app.use('/api-docs', swaggerUi.serve, swaggerUi.setup(swaggerDocument, {
  customCss: '.swagger-ui .topbar { display: none }',
  customSiteTitle: 'Colony App API Documentation',
}));

app.get('/swagger.json', (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.send(swaggerDocument);
});

app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    supabase: supabaseUrl ? 'configured' : 'missing',
  });
});

app.get('/', (req, res) => {
  res.json({
    message: 'Backend API is running',
    services: { supabase: { url: supabaseUrl ? 'configured' : 'not configured' } },
    endpoints: {
      health: '/health',
      auth: { signup: 'POST /auth/signup', login: 'POST /auth/login', logout: 'POST /auth/logout', user: 'GET /auth/user', resetPassword: 'POST /auth/reset-password', updateProfile: 'PATCH /auth/profile' },
      profile: { get: 'GET /profile/:userId', update: 'PATCH /profile' },
      groups: { list: 'GET /groups', create: 'POST /groups', get: 'GET /groups/:groupId', join: 'POST /groups/:groupId/join', leave: 'POST /groups/:groupId/leave', members: 'GET /groups/:groupId/members' },
      conversations: { list: 'GET /conversations', create: 'POST /conversations', messages: 'GET /conversations/:id/messages', send: 'POST /conversations/:id/messages' },
      userKeys: { get: 'GET /user-keys/:userId', save: 'POST /user-keys' },
      docs: '/api-docs',
    },
  });
});

// ============== AUTH ROUTES ==============

app.post('/auth/signup', rateLimit({ max: 5, windowMs: 60_000 }), async (req, res) => {
  try {
    const { email, password, displayName } = req.body;
    if (!email || !password) return res.status(400).json({ success: false, message: 'Email and password are required' });
    if (password.length < 6) return res.status(400).json({ success: false, message: 'Password must be at least 6 characters' });

    const { data, error } = await supabaseAdmin.auth.signUp({
      email,
      password,
      options: { data: displayName ? { display_name: displayName } : {} },
    });
    if (error) return res.status(400).json({ success: false, message: error.message });

    res.status(201).json({
      success: true,
      message: 'Account created successfully',
      user: { id: data.user?.id, email: data.user?.email, displayName: data.user?.user_metadata?.display_name },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred during signup', error: error.message });
  }
});

app.post('/auth/login', rateLimit({ max: 10, windowMs: 60_000 }), async (req, res) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ success: false, message: 'Email and password are required' });

    const { data, error } = await supabaseAdmin.auth.signInWithPassword({ email, password });
    if (error) return res.status(401).json({ success: false, message: 'Invalid email or password' });

    res.status(200).json({
      success: true,
      message: 'Login successful',
      user: { id: data.user?.id, email: data.user?.email, displayName: data.user?.user_metadata?.display_name, avatarUrl: data.user?.user_metadata?.avatar_url },
      session: { accessToken: data.session?.access_token, refreshToken: data.session?.refresh_token, expiresAt: data.session?.expires_at },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred during login', error: error.message });
  }
});

app.post('/auth/logout', requireAuth, async (req, res) => {
  try {
    const { error } = await supabaseAdmin.auth.admin.signOut(req.token);
    if (error) return res.status(400).json({ success: false, message: error.message });
    res.status(200).json({ success: true, message: 'Logged out successfully' });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred during logout', error: error.message });
  }
});

app.get('/auth/user', requireAuth, async (req, res) => {
  res.status(200).json({
    success: true,
    user: { id: req.user.id, email: req.user.email, displayName: req.user.user_metadata?.display_name, avatarUrl: req.user.user_metadata?.avatar_url },
  });
});

app.post('/auth/reset-password', rateLimit({ max: 3, windowMs: 60_000 }), async (req, res) => {
  try {
    const { email } = req.body;
    if (!email) return res.status(400).json({ success: false, message: 'Email is required' });

    const { error } = await supabaseAdmin.auth.resetPasswordForEmail(email, {
      redirectTo: `${FRONTEND_URL}/reset-password`,
    });
    if (error) return res.status(400).json({ success: false, message: error.message });
    res.status(200).json({ success: true, message: 'Password reset email sent successfully' });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.patch('/auth/profile', requireAuth, async (req, res) => {
  try {
    const { displayName, avatarUrl } = req.body;

    const { data, error } = await supabaseAdmin.auth.updateUser(req.token, {
      data: { ...(displayName && { display_name: displayName }), ...(avatarUrl && { avatar_url: avatarUrl }) },
    });
    if (error) return res.status(400).json({ success: false, message: error.message });

    res.status(200).json({
      success: true,
      message: 'Profile updated successfully',
      user: { id: data.user?.id, email: data.user?.email, displayName: data.user?.user_metadata?.display_name, avatarUrl: data.user?.user_metadata?.avatar_url },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

// ============== PROFILE ROUTES ==============

app.get('/profile/:userId', requireAuth, validateUUID('userId'), async (req, res) => {
  try {
    const { userId } = req.params;
    const { data, error } = await supabaseAdmin
      .from('profiles')
      .select('id, username, display_name, avatar_url, bio, location_text, last_seen, created_at')
      .eq('id', userId)
      .single();
    if (error) return res.status(404).json({ success: false, message: 'Profile not found', error: error.message });
    res.status(200).json({ success: true, profile: data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.get('/users/nearby', requireAuth, async (req, res) => {
  try {
    const radiusKm = Math.min(parseFloat(req.query.radiusKm || '5'), 5);
    const limit = Math.min(parseInt(req.query.limit || '50', 10), 100);
    const offset = Math.max(parseInt(req.query.offset || '0', 10), 0);
    let latitude = req.query.latitude !== undefined ? parseFloat(req.query.latitude) : null;
    let longitude = req.query.longitude !== undefined ? parseFloat(req.query.longitude) : null;

    if (latitude === null || longitude === null || Number.isNaN(latitude) || Number.isNaN(longitude)) {
      const { data: profile, error: profileError } = await supabaseAdmin
        .from('profiles')
        .select('latitude, longitude, last_location_updated_at')
        .eq('id', req.user.id)
        .single();

      if (profileError || profile?.latitude == null || profile?.longitude == null) {
        return res.status(400).json({
          success: false,
          message: 'Location unavailable',
        });
      }

      latitude = Number(profile.latitude);
      longitude = Number(profile.longitude);
    }

    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
      return res.status(400).json({
        success: false,
        message: 'Invalid coordinates',
      });
    }

    const { data, error } = await supabaseAdmin.rpc('get_nearby_users', {
      user_lat: latitude,
      user_lon: longitude,
      radius_km: radiusKm,
      result_limit: limit,
      result_offset: offset,
    });

    if (error) return res.status(400).json({ success: false, message: error.message });
    res.status(200).json({ success: true, data: data || [] });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.patch('/profile', requireAuth, async (req, res) => {
  try {
    const { displayName, bio, avatarUrl, locationText } = req.body;
    const updateData = {};
    if (displayName !== undefined) updateData.display_name = displayName;
    if (bio !== undefined) updateData.bio = bio;
    if (avatarUrl !== undefined) updateData.avatar_url = avatarUrl;
    if (locationText !== undefined) updateData.location_text = locationText;

    const { data, error } = await supabaseAdmin
      .from('profiles')
      .update(updateData)
      .eq('id', req.user.id)
      .select()
      .single();
    if (error) return res.status(400).json({ success: false, message: error.message });
    res.status(200).json({ success: true, message: 'Profile updated successfully', profile: data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

// ============== GROUP ROUTES ==============

app.post('/groups', requireAuth, async (req, res) => {
  try {
    const { name, description, category, isPrivate = false, latitude, longitude, locationText } = req.body;
    if (!name) return res.status(400).json({ success: false, message: 'Group name is required' });

    const groupData = { name, description: description || null, category: category || 'general', is_private: isPrivate, created_by: req.user.id };
    if (latitude !== undefined && longitude !== undefined) {
      groupData.latitude = parseFloat(latitude);
      groupData.longitude = parseFloat(longitude);
      groupData.location_text = locationText || null;
    }

    const { data: group, error: groupError } = await supabaseAdmin.from('groups').insert(groupData).select().single();
    if (groupError) return res.status(400).json({ success: false, message: groupError.message });

    const { error: memberError } = await supabaseAdmin.from('group_members').insert({ group_id: group.id, user_id: req.user.id, role: 'admin' });
    if (memberError) console.error('Error adding creator as member:', memberError);

    res.status(201).json({ success: true, message: 'Group created successfully', group });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.get('/groups', requireAuth, async (req, res) => {
  try {
    const { latitude, longitude, radius = 5, limit = 20, offset = 0 } = req.query;

    if (latitude && longitude) {
      const { data, error } = await supabaseAdmin.rpc('get_nearby_groups', {
        user_lat: parseFloat(latitude),
        user_lon: parseFloat(longitude),
        radius_km: Math.min(parseFloat(radius), 5),
      });
      if (error) return res.status(400).json({ success: false, message: error.message });
      return res.status(200).json({ success: true, groups: data || [] });
    }

    const { data, error } = await supabaseAdmin
      .from('groups')
      .select('id, name, description, category, cover_image_url, location_text, latitude, longitude, is_private, created_at, created_by')
      .eq('is_private', false)
      .order('created_at', { ascending: false })
      .range(parseInt(offset), parseInt(offset) + parseInt(limit) - 1);
    if (error) return res.status(400).json({ success: false, message: error.message });
    res.status(200).json({ success: true, groups: data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.get('/groups/:groupId', requireAuth, validateUUID('groupId'), async (req, res) => {
  try {
    const { groupId } = req.params;
    const { data, error } = await supabaseAdmin
      .from('groups')
      .select('id, name, description, category, cover_image_url, location_text, latitude, longitude, is_private, created_at, created_by')
      .eq('id', groupId)
      .single();
    if (error) return res.status(404).json({ success: false, message: 'Group not found', error: error.message });
    res.status(200).json({ success: true, group: data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.get('/groups/:groupId/members', requireAuth, validateUUID('groupId'), async (req, res) => {
  try {
    const { groupId } = req.params;
    const { data, error } = await supabaseAdmin
      .from('group_members')
      .select('id, role, joined_at, profiles(id, username, display_name, avatar_url)')
      .eq('group_id', groupId)
      .order('joined_at', { ascending: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    res.status(200).json({ success: true, members: data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.post('/groups/:groupId/join', requireAuth, validateUUID('groupId'), async (req, res) => {
  try {
    const { groupId } = req.params;
    const { data: existingMember } = await supabaseAdmin.from('group_members').select('id').eq('group_id', groupId).eq('user_id', req.user.id).single();
    if (existingMember) return res.status(400).json({ success: false, message: 'Already a member of this group' });

    const { error: memberError } = await supabaseAdmin.from('group_members').insert({ group_id: groupId, user_id: req.user.id, role: 'member' });
    if (memberError) return res.status(400).json({ success: false, message: memberError.message });
    res.status(200).json({ success: true, message: 'Successfully joined the group' });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.post('/groups/:groupId/leave', requireAuth, validateUUID('groupId'), async (req, res) => {
  try {
    const { groupId } = req.params;
    const { error: memberError } = await supabaseAdmin.from('group_members').delete().eq('group_id', groupId).eq('user_id', req.user.id);
    if (memberError) return res.status(400).json({ success: false, message: memberError.message });
    res.status(200).json({ success: true, message: 'Successfully left the group' });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

// ============== CONVERSATIONS ==============

app.get('/conversations', requireAuth, async (req, res) => {
  try {
    const { data: conversations, error: convError } = await supabaseAdmin
      .from('conversations')
      .select('id, created_at, last_message, last_message_at, updated_at, user1_id, user2_id')
      .or(`user1_id.eq.${req.user.id},user2_id.eq.${req.user.id}`)
      .not('last_message_at', 'is', null)
      .order('last_message_at', { ascending: false, nullsFirst: false });
    if (convError) return res.status(400).json({ success: false, message: convError.message });

    const conversationsWithUsers = await Promise.all(
      (conversations || []).map(async (conv) => {
        const otherUserId = conv.user1_id === req.user.id ? conv.user2_id : conv.user1_id;
        const { data: otherUser } = await supabaseAdmin.from('profiles').select('id, username, display_name, avatar_url').eq('id', otherUserId).single();
        const { data: lastMessage } = await supabaseAdmin.from('messages').select('content, created_at, sender_id').eq('conversation_id', conv.id).order('created_at', { ascending: false }).limit(1).single();
        const { count: unreadCount } = await supabaseAdmin
          .from('messages')
          .select('*', { count: 'exact', head: true })
          .eq('conversation_id', conv.id)
          .neq('sender_id', req.user.id)
          .eq('is_read', false);
        return {
          id: conv.id,
          user1_id: conv.user1_id,
          user2_id: conv.user2_id,
          otherUser: otherUser ? { id: otherUser.id, username: otherUser.username, displayName: otherUser.display_name, avatarUrl: otherUser.avatar_url } : null,
          lastMessage: lastMessage ? { content: lastMessage.content, created_at: lastMessage.created_at, createdAt: lastMessage.created_at, sender_id: lastMessage.sender_id, senderId: lastMessage.sender_id, is_read: true } : null,
          createdAt: conv.created_at,
          created_at: conv.created_at,
          lastMessageAt: conv.last_message_at,
          last_message_at: conv.last_message_at,
          unreadCount: unreadCount || 0,
          unread_count: unreadCount || 0,
        };
      })
    );
    res.status(200).json({ success: true, data: conversationsWithUsers });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.post('/conversations', requireAuth, async (req, res) => {
  try {
    const { otherUserId } = req.body;
    if (!otherUserId) return res.status(400).json({ success: false, message: 'otherUserId is required' });
    if (!UUID_REGEX.test(otherUserId)) return res.status(400).json({ success: false, message: 'Invalid otherUserId format' });
    if (req.user.id === otherUserId) return res.status(400).json({ success: false, message: 'Cannot create conversation with yourself' });

    const { data: canChat } = await supabaseAdmin.rpc('can_chat_with', { target_user_id: otherUserId });
    if (!canChat) return res.status(403).json({ success: false, message: 'Cannot chat with this user — mutual wave acceptance required' });

    const { data: existingConv } = await supabaseAdmin
      .from('conversations')
      .select('*')
      .or(`and(user1_id.eq.${req.user.id},user2_id.eq.${otherUserId}),and(user1_id.eq.${otherUserId},user2_id.eq.${req.user.id})`)
      .single();
    if (existingConv) return res.status(200).json({ success: true, data: existingConv, isNew: false });

    const { data: newConv, error: createError } = await supabaseAdmin
      .from('conversations')
      .insert({ user1_id: req.user.id, user2_id: otherUserId })
      .select()
      .single();
    if (createError) return res.status(400).json({ success: false, message: createError.message });
    res.status(201).json({ success: true, data: newConv, isNew: true });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.get('/conversations/:id/messages', requireAuth, validateUUID('id'), async (req, res) => {
  try {
    const { id } = req.params;
    const { data: conversation } = await supabaseAdmin.from('conversations').select('*').eq('id', id).single();
    if (!conversation) return res.status(404).json({ success: false, message: 'Conversation not found' });
    if (conversation.user1_id !== req.user.id && conversation.user2_id !== req.user.id) return res.status(403).json({ success: false, message: 'Access denied' });

    const { data: messages, error: msgError } = await supabaseAdmin
      .from('messages')
      .select('id, content, sender_id, is_read, created_at, media_url, media_type, delivered_at, seen_at')
      .eq('conversation_id', id)
      .order('created_at', { ascending: true });
    if (msgError) return res.status(400).json({ success: false, message: msgError.message });

    await supabaseAdmin.from('messages').update({ is_read: true, seen_at: new Date().toISOString() }).eq('conversation_id', id).neq('sender_id', req.user.id).eq('is_read', false);
    const otherUserId = conversation.user1_id === req.user.id ? conversation.user2_id : conversation.user1_id;
    socketGateway.emitToUser(req.user.id, 'chat_list_updated', { conversationId: id, unreadCount: 0 });
    socketGateway.emitToUser(otherUserId, 'chat_list_updated', { conversationId: id });
    res.status(200).json({ success: true, data: messages || [] });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.post('/conversations/:id/messages', requireAuth, validateUUID('id'), rateLimit({ max: 60, windowMs: 60_000 }), async (req, res) => {
  try {
    const { id } = req.params;
    const { content, mediaUrl, mediaType, replyToId } = req.body;
    if (!content && !mediaUrl) return res.status(400).json({ success: false, message: 'Content or media is required' });

    const { data: conversation } = await supabaseAdmin.from('conversations').select('*').eq('id', id).single();
    if (!conversation) return res.status(404).json({ success: false, message: 'Conversation not found' });
    if (conversation.user1_id !== req.user.id && conversation.user2_id !== req.user.id) return res.status(403).json({ success: false, message: 'Access denied' });
    const receiverId = conversation.user1_id === req.user.id ? conversation.user2_id : conversation.user1_id;

    const { data: message, error: msgError } = await supabaseAdmin
      .from('messages')
      .insert({
        conversation_id: id,
        sender_id: req.user.id,
        content: content || '',
        text: content || '',
        receiver_id: receiverId,
        media_url: mediaUrl,
        media_type: mediaType,
        reply_to_id: replyToId || null,
      })
      .select()
      .single();
    if (msgError) return res.status(400).json({ success: false, message: msgError.message });

    const { data: senderProfile } = await supabaseAdmin
      .from('profiles')
      .select('display_name, username')
      .eq('id', req.user.id)
      .maybeSingle();

    const senderName = senderProfile?.display_name || senderProfile?.username || 'Someone';
    const previewSource = mediaUrl ? `[${mediaType || 'media'}]` : content || 'New message';

    await notificationService.sendNotification({
      receiverId,
      senderId: req.user.id,
      type: 'dm_message',
      title: senderName,
      body: truncate(previewSource, 120),
      data: {
        type: 'dm_message',
        screen: 'chat',
        chatId: id,
        conversationId: id,
        senderId: req.user.id,
        messageId: message.id,
      },
      options: {
        socketOnlyWhenOnline: true,
      },
    });

    const chatListPayload = {
      conversationId: id,
      message,
      lastMessage: message.content,
      lastMessageAt: message.created_at,
      senderId: req.user.id,
      receiverId,
    };
    socketGateway.emitToUser(req.user.id, 'chat_list_updated', chatListPayload);
    socketGateway.emitToUser(receiverId, 'chat_list_updated', chatListPayload);

    res.status(201).json({ success: true, data: message });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

// ============== USER KEYS ==============

app.get('/user-keys/:userId', requireAuth, validateUUID('userId'), async (req, res) => {
  try {
    const { userId } = req.params;
    const { data: userKey, error } = await supabaseAdmin
      .from('user_keys')
      .select('public_key, key_version, key_scheme, created_at')
      .eq('user_id', userId)
      .single();
    if (error) return res.status(404).json({ success: false, message: 'Public key not found for this user' });
    res.status(200).json({ success: true, data: userKey });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

app.post('/user-keys', requireAuth, async (req, res) => {
  try {
    const { publicKey, keyVersion, keyScheme } = req.body;
    if (!publicKey) return res.status(400).json({ success: false, message: 'publicKey is required' });

    const { data: userKey, error: keyError } = await supabaseAdmin
      .from('user_keys')
      .upsert({ user_id: req.user.id, public_key: publicKey, key_version: keyVersion || 1, key_scheme: keyScheme || 1, updated_at: new Date().toISOString() }, { onConflict: 'user_id' })
      .select()
      .single();
    if (keyError) return res.status(400).json({ success: false, message: keyError.message });
    res.status(201).json({ success: true, data: userKey });
  } catch (error) {
    res.status(500).json({ success: false, message: 'An error occurred', error: error.message });
  }
});

// Periodically clean stale rate limit entries
setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of rateLimitMap) {
    if (now - entry.resetAt > 120_000) rateLimitMap.delete(key);
  }
}, 120_000);

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Supabase URL: ${supabaseUrl ? 'Configured' : 'Not configured'}`);
  console.log(`Environment: ${process.env.NODE_ENV}`);
  console.log(`Socket.IO enabled for ${FRONTEND_URL}`);
});
