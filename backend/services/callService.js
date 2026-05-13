const { supabaseAdmin } = require('../config/supabase');

const RING_TIMEOUT_MS = Number(process.env.CALL_RING_TIMEOUT_MS || 30_000);
const activeTimeouts = new Map();

function callTypeToNotificationType(callType) {
  return callType === 'video' ? 'video_call' : 'voice_call';
}

function publicCallPayload(call, callerProfile = null, receiverProfile = null) {
  return {
    callId: call.id,
    callerId: call.caller_id,
    receiverId: call.receiver_id,
    callerName: callerProfile?.display_name || callerProfile?.username || 'Someone',
    callerImage: callerProfile?.avatar_url || null,
    receiverName: receiverProfile?.display_name || receiverProfile?.username || 'Someone',
    receiverImage: receiverProfile?.avatar_url || null,
    callType: call.call_type,
    status: call.status,
    startedAt: call.started_at,
    answeredAt: call.answered_at,
    endedAt: call.ended_at,
    duration: call.duration || 0,
  };
}

async function getProfile(userId) {
  const { data, error } = await supabaseAdmin
    .from('profiles')
    .select('id, username, display_name, avatar_url')
    .eq('id', userId)
    .single();

  if (error) throw error;
  return data;
}

async function findActiveCallForUser(userId) {
  const { data, error } = await supabaseAdmin
    .from('calls')
    .select('*')
    .or(`caller_id.eq.${userId},receiver_id.eq.${userId}`)
    .in('status', ['ringing', 'accepted'])
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  return data;
}

function clearMissedTimer(callId) {
  const timer = activeTimeouts.get(callId);
  if (timer) {
    clearTimeout(timer);
    activeTimeouts.delete(callId);
  }
}

function scheduleMissedCall({ call, callerProfile, socketGateway, notificationService }) {
  clearMissedTimer(call.id);

  const timer = setTimeout(async () => {
    try {
      const { data: latest } = await supabaseAdmin
        .from('calls')
        .select('*')
        .eq('id', call.id)
        .maybeSingle();

      if (!latest || latest.status !== 'ringing') return;

      const now = new Date().toISOString();
      const { data: missed, error } = await supabaseAdmin
        .from('calls')
        .update({
          status: 'missed',
          ended_at: now,
          duration: 0,
        })
        .eq('id', call.id)
        .eq('status', 'ringing')
        .select('*')
        .single();

      if (error) throw error;

      const payload = publicCallPayload(missed, callerProfile);
      socketGateway.emitToUser(missed.caller_id, 'call_missed', payload);
      socketGateway.emitToUser(missed.receiver_id, 'call_missed', payload);

      await notificationService.sendNotification({
        receiverId: missed.receiver_id,
        senderId: missed.caller_id,
        type: 'missed_call',
        title: 'Missed Call',
        body: `Missed call from ${payload.callerName}`,
        data: {
          type: 'missed_call',
          screen: 'call_history',
          callId: missed.id,
          callType: missed.call_type,
          callerId: missed.caller_id,
        },
      });
    } catch (error) {
      console.error('Failed to mark call as missed', error);
    } finally {
      activeTimeouts.delete(call.id);
    }
  }, RING_TIMEOUT_MS);

  activeTimeouts.set(call.id, timer);
}

function createCallService({ socketGateway, notificationService }) {
  async function startCall({ callerId, receiverId, callType }) {
    if (!['voice', 'video'].includes(callType)) {
      throw new Error('callType must be voice or video');
    }
    if (callerId === receiverId) {
      throw new Error('Cannot call yourself');
    }

    const [callerProfile, receiverProfile, callerBusy, receiverBusy] = await Promise.all([
      getProfile(callerId),
      getProfile(receiverId),
      findActiveCallForUser(callerId),
      findActiveCallForUser(receiverId),
    ]);

    if (callerBusy || receiverBusy) {
      const busyUserId = callerBusy ? callerId : receiverId;
      socketGateway.emitToUser(callerId, 'call_busy', { receiverId: busyUserId });
      throw new Error('User is busy on another call');
    }

    const now = new Date().toISOString();
    const { data: call, error } = await supabaseAdmin
      .from('calls')
      .insert({
        caller_id: callerId,
        receiver_id: receiverId,
        call_type: callType,
        status: 'ringing',
        started_at: now,
      })
      .select('*')
      .single();

    if (error) throw error;

    const payload = publicCallPayload(call, callerProfile, receiverProfile);
    const receiverOnline = socketGateway.isUserOnline(receiverId);

    if (receiverOnline) {
      socketGateway.emitToUser(receiverId, 'incoming_call', payload);
    } else {
      await notificationService.sendNotification({
        receiverId,
        senderId: callerId,
        type: callTypeToNotificationType(callType),
        title: `Incoming ${callType === 'video' ? 'Video' : 'Voice'} Call`,
        body: `${payload.callerName} is calling you`,
        data: {
          type: callTypeToNotificationType(callType),
          screen: 'incoming_call',
          callId: call.id,
          callType,
          callerId,
          callerName: payload.callerName,
          callerImage: payload.callerImage,
        },
      });
    }

    socketGateway.emitToUser(callerId, 'call_ringing', payload);
    scheduleMissedCall({ call, callerProfile, socketGateway, notificationService });
    return payload;
  }

  async function acceptCall({ callId, userId }) {
    const now = new Date().toISOString();
    const { data: call, error } = await supabaseAdmin
      .from('calls')
      .update({
        status: 'accepted',
        answered_at: now,
      })
      .eq('id', callId)
      .eq('receiver_id', userId)
      .eq('status', 'ringing')
      .select('*')
      .single();

    if (error) throw error;
    clearMissedTimer(callId);

    const [caller, receiver] = await Promise.all([
      getProfile(call.caller_id),
      getProfile(call.receiver_id),
    ]);
    const payload = publicCallPayload(call, caller, receiver);
    socketGateway.emitToUser(call.caller_id, 'call_accepted', payload);
    socketGateway.emitToUser(call.receiver_id, 'call_accepted', payload);
    return payload;
  }

  async function rejectCall({ callId, userId }) {
    const now = new Date().toISOString();
    const { data: call, error } = await supabaseAdmin
      .from('calls')
      .update({
        status: 'rejected',
        ended_at: now,
        duration: 0,
      })
      .eq('id', callId)
      .eq('receiver_id', userId)
      .eq('status', 'ringing')
      .select('*')
      .single();

    if (error) throw error;
    clearMissedTimer(callId);

    const [caller, receiver] = await Promise.all([
      getProfile(call.caller_id),
      getProfile(call.receiver_id),
    ]);
    const payload = publicCallPayload(call, caller, receiver);
    socketGateway.emitToUser(call.caller_id, 'call_rejected', payload);
    socketGateway.emitToUser(call.receiver_id, 'call_rejected', payload);
    return payload;
  }

  async function cancelCall({ callId, userId }) {
    const now = new Date().toISOString();
    const { data: call, error } = await supabaseAdmin
      .from('calls')
      .update({
        status: 'cancelled',
        ended_at: now,
        duration: 0,
      })
      .eq('id', callId)
      .eq('caller_id', userId)
      .eq('status', 'ringing')
      .select('*')
      .single();

    if (error) throw error;
    clearMissedTimer(callId);

    const [caller, receiver] = await Promise.all([
      getProfile(call.caller_id),
      getProfile(call.receiver_id),
    ]);
    const payload = publicCallPayload(call, caller, receiver);
    socketGateway.emitToUser(call.caller_id, 'call_cancelled', payload);
    socketGateway.emitToUser(call.receiver_id, 'call_cancelled', payload);
    return payload;
  }

  async function endCall({ callId, userId }) {
    const { data: existing, error: findError } = await supabaseAdmin
      .from('calls')
      .select('*')
      .eq('id', callId)
      .or(`caller_id.eq.${userId},receiver_id.eq.${userId}`)
      .in('status', ['accepted', 'ringing'])
      .single();

    if (findError) throw findError;

    const now = new Date();
    const answeredAt = existing.answered_at ? new Date(existing.answered_at) : now;
    const duration = existing.status === 'accepted'
      ? Math.max(0, Math.floor((now.getTime() - answeredAt.getTime()) / 1000))
      : 0;

    const { data: call, error } = await supabaseAdmin
      .from('calls')
      .update({
        status: existing.status === 'ringing' ? 'cancelled' : 'ended',
        ended_at: now.toISOString(),
        duration,
      })
      .eq('id', callId)
      .select('*')
      .single();

    if (error) throw error;
    clearMissedTimer(callId);

    const [caller, receiver] = await Promise.all([
      getProfile(call.caller_id),
      getProfile(call.receiver_id),
    ]);
    const payload = publicCallPayload(call, caller, receiver);
    socketGateway.emitToUser(call.caller_id, 'call_ended', payload);
    socketGateway.emitToUser(call.receiver_id, 'call_ended', payload);
    return payload;
  }

  async function getHistory(userId, { limit = 50, offset = 0 } = {}) {
    const { data, error } = await supabaseAdmin
      .from('calls')
      .select(`
        *,
        caller:profiles!calls_caller_id_fkey(id, username, display_name, avatar_url),
        receiver:profiles!calls_receiver_id_fkey(id, username, display_name, avatar_url)
      `)
      .or(`caller_id.eq.${userId},receiver_id.eq.${userId}`)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;
    return data || [];
  }

  async function getCall(callId, userId) {
    const { data, error } = await supabaseAdmin
      .from('calls')
      .select(`
        *,
        caller:profiles!calls_caller_id_fkey(id, username, display_name, avatar_url),
        receiver:profiles!calls_receiver_id_fkey(id, username, display_name, avatar_url)
      `)
      .eq('id', callId)
      .or(`caller_id.eq.${userId},receiver_id.eq.${userId}`)
      .single();

    if (error) throw error;
    return data;
  }

  return {
    startCall,
    acceptCall,
    rejectCall,
    cancelCall,
    endCall,
    getHistory,
    getCall,
  };
}

module.exports = { createCallService };
