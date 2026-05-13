function createWebrtcSignalingService({ socketGateway }) {
  const relayEvents = ['call_offer', 'call_answer', 'ice_candidate'];

  socketGateway.io.on('connection', (socket) => {
    for (const event of relayEvents) {
      socket.on(event, (payload = {}) => {
        const recipientId = payload.recipientId || payload.receiverId;
        if (!recipientId) {
          socket.emit('call_error', {
            callId: payload.callId,
            error: 'recipientId is required',
          });
          return;
        }

        socketGateway.emitToUser(recipientId, event, {
          ...payload,
          type: event,
          timestamp: payload.timestamp || new Date().toISOString(),
        });
      });
    }
  });
}

module.exports = { createWebrtcSignalingService };
