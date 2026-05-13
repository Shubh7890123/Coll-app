const { Server } = require('socket.io');

function createSocketGateway(httpServer, { corsOrigin }) {
  const io = new Server(httpServer, {
    cors: {
      origin: corsOrigin,
      credentials: true,
    },
  });

  const userSockets = new Map();
  const socketUsers = new Map();

  function addUserSocket(userId, socketId) {
    if (!userSockets.has(userId)) {
      userSockets.set(userId, new Set());
    }
    userSockets.get(userId).add(socketId);
    socketUsers.set(socketId, userId);
  }

  function removeSocket(socketId) {
    const userId = socketUsers.get(socketId);
    if (!userId) return null;

    const sockets = userSockets.get(userId);
    if (sockets) {
      sockets.delete(socketId);
      if (sockets.size === 0) {
        userSockets.delete(userId);
      }
    }

    socketUsers.delete(socketId);
    return userId;
  }

  function emitToUser(userId, event, payload) {
    io.to(`user:${userId}`).emit(event, payload);
  }

  function isUserOnline(userId) {
    return userSockets.has(userId) && userSockets.get(userId).size > 0;
  }

  io.on('connection', (socket) => {
    socket.on('presence:register', ({ userId, rooms = [] } = {}) => {
      if (!userId) {
        socket.emit('presence:error', { message: 'userId is required' });
        return;
      }

      addUserSocket(userId, socket.id);
      socket.join(`user:${userId}`);

      for (const room of rooms) {
        if (typeof room === 'string' && room.trim()) {
          socket.join(room);
        }
      }

      socket.emit('presence:registered', {
        userId,
        socketId: socket.id,
        online: true,
      });
    });

    socket.on('notifications:join', ({ userId } = {}) => {
      if (userId) {
        socket.join(`notifications:${userId}`);
      }
    });

    socket.on('chat:join', ({ roomId } = {}) => {
      if (roomId) {
        socket.join(`chat:${roomId}`);
      }
    });

    socket.on('disconnect', () => {
      const userId = removeSocket(socket.id);
      if (userId && !isUserOnline(userId)) {
        io.emit('presence:update', {
          userId,
          online: false,
          lastSeen: new Date().toISOString(),
        });
      }
    });
  });

  return {
    io,
    emitToUser,
    isUserOnline,
  };
}

module.exports = { createSocketGateway };
