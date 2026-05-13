const WebSocket = require('ws');
const http = require('http');
const { createClient } = require('@supabase/supabase-js');
require('dotenv').config();

// Supabase client for database operations
const supabase = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_KEY
);

// Create HTTP server
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'WebSocket server running' }));
});

// WebSocket server
const wss = new WebSocket.Server({ server });

// Store connected clients
const clients = new Map(); // userId -> WebSocket
const rooms = new Map(); // conversationId -> Set of userIds

console.log('WebSocket server starting...');

wss.on('connection', async (ws, req) => {
    console.log('New WebSocket connection');

    let userId = null;
    let isAuthenticated = false;

    // Parse token from query string
    const url = new URL(req.url, `http://${req.headers.host}`);
    const token = url.searchParams.get('token');

    // Send message helper
    const send = (data) => {
        if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify(data));
        }
    };

    // Handle messages
    ws.on('message', async (data) => {
        try {
            const message = JSON.parse(data);
            const { type } = message;

            switch (type) {
                case 'auth':
                    await handleAuth(message);
                    break;
                case 'join':
                    await handleJoin(message);
                    break;
                case 'leave':
                    handleLeave(message);
                    break;
                case 'message':
                    await handleMessage(message);
                    break;
                case 'typing':
                    await handleTyping(message);
                    break;
                case 'read':
                    await handleReadReceipt(message);
                    break;
                case 'edit':
                    await handleEdit(message);
                    break;
                case 'delete':
                    await handleDelete(message);
                    break;
                // Call signaling handlers
                case 'call_offer':
                    await handleCallOffer(message);
                    break;
                case 'call_answer':
                    await handleCallAnswer(message);
                    break;
                case 'ice_candidate':
                    await handleIceCandidate(message);
                    break;
                case 'call_end':
                    await handleCallEnd(message);
                    break;
                default:
                    send({ type: 'error', error: 'Unknown message type' });
            }
        } catch (error) {
            console.error('Error handling message:', error);
            send({ type: 'error', error: 'Invalid message format' });
        }
    });

    // Handle authentication
    async function handleAuth(message) {
        const { userId: authUserId } = message;

        // Verify user exists in Supabase
        const { data: user, error } = await supabase
            .from('profiles')
            .select('id')
            .eq('id', authUserId)
            .single();

        if (error || !user) {
            send({ type: 'error', error: 'Authentication failed' });
            ws.close();
            return;
        }

        userId = authUserId;
        isAuthenticated = true;
        clients.set(userId, ws);

        console.log(`User ${userId} authenticated`);
        send({ type: 'auth', status: 'success' });
    }

    // Handle join conversation
    async function handleJoin(message) {
        if (!isAuthenticated) {
            send({ type: 'error', error: 'Not authenticated' });
            return;
        }

        const { conversationId } = message;

        // Verify user is part of this conversation
        const { data: conversation, error } = await supabase
            .from('conversations')
            .select('user1_id, user2_id')
            .eq('id', conversationId)
            .or(`user1_id.eq.${userId},user2_id.eq.${userId}`)
            .single();

        if (error || !conversation) {
            send({ type: 'error', error: 'Access denied to conversation' });
            return;
        }

        // Add to room
        if (!rooms.has(conversationId)) {
            rooms.set(conversationId, new Set());
        }
        rooms.get(conversationId).add(userId);

        console.log(`User ${userId} joined conversation ${conversationId}`);
        send({ type: 'joined', conversationId });
    }

    // Handle leave conversation
    function handleLeave(message) {
        if (!isAuthenticated) return;

        const { conversationId } = message;

        if (rooms.has(conversationId)) {
            rooms.get(conversationId).delete(userId);
            if (rooms.get(conversationId).size === 0) {
                rooms.delete(conversationId);
            }
        }

        console.log(`User ${userId} left conversation ${conversationId}`);
        send({ type: 'left', conversationId });
    }

    // Handle message
    async function handleMessage(message) {
        if (!isAuthenticated) {
            send({ type: 'error', error: 'Not authenticated' });
            return;
        }

        const { conversationId, recipientId, content, contentType, replyTo } = message;

        // Verify user is in the conversation room
        if (!rooms.has(conversationId) || !rooms.get(conversationId).has(userId)) {
            send({ type: 'error', error: 'Not in conversation' });
            return;
        }

        // Save message to database
        const { data: savedMessage, error } = await supabase
          .from('messages')
          .insert({
            conversation_id: conversationId,
            sender_id: userId,
            content: content, // Encrypted content
            content_type: contentType || 'text',
            reply_to: replyTo || null,
          })
          .select()
          .single();
      
        if (error) {
          console.error('Error saving message:', error);
          send({ type: 'error', error: 'Failed to save message' });
          return;
        }
      
        // Update conversation's last_message_at for proper sorting
        await supabase
          .from('conversations')
          .update({ last_message_at: savedMessage.created_at })
          .eq('id', conversationId);
      
        // Broadcast to all users in the conversation
        const messageData = {
            type: 'message',
            messageId: savedMessage.id,
            conversationId,
            senderId: userId,
            content,
            contentType: contentType || 'text',
            replyTo: replyTo || null,
            timestamp: savedMessage.created_at,
            isEdited: false,
        };

        broadcastToConversation(conversationId, messageData, userId);

        // Confirm to sender
        send({ type: 'message_sent', messageId: savedMessage.id });
    }

    // Handle typing indicator
    async function handleTyping(message) {
        if (!isAuthenticated) return;

        const { conversationId, recipientId, isTyping } = message;

        // Broadcast typing status to recipient
        const typingData = {
            type: 'typing',
            conversationId,
            senderId: userId,
            isTyping,
            timestamp: new Date().toISOString(),
        };

        // Send to recipient if online
        if (clients.has(recipientId)) {
            clients.get(recipientId).send(JSON.stringify(typingData));
        }
    }

    // Handle read receipt
    async function handleReadReceipt(message) {
        if (!isAuthenticated) return;

        const { conversationId, messageId } = message;

        // Update message in database
        await supabase
            .from('messages')
            .update({ read_at: new Date().toISOString() })
            .eq('id', messageId);

        // Broadcast to conversation
        const readData = {
            type: 'read',
            conversationId,
            messageId,
            senderId: userId,
            timestamp: new Date().toISOString(),
        };

        broadcastToConversation(conversationId, readData, userId);
    }

    // Handle edit message
    async function handleEdit(message) {
        if (!isAuthenticated) return;

        const { messageId, conversationId, content } = message;

        // Verify user is the sender
        const { data: existingMessage } = await supabase
            .from('messages')
            .select('sender_id')
            .eq('id', messageId)
            .single();

        if (!existingMessage || existingMessage.sender_id !== userId) {
            send({ type: 'error', error: 'Can only edit own messages' });
            return;
        }

        // Update message
        await supabase
            .from('messages')
            .update({
                content,
                is_edited: true,
                edited_at: new Date().toISOString(),
            })
            .eq('id', messageId);

        // Broadcast edit
        const editData = {
            type: 'edit',
            messageId,
            conversationId,
            senderId: userId,
            content,
            timestamp: new Date().toISOString(),
        };

        broadcastToConversation(conversationId, editData, userId);
    }

    // Handle delete message
    async function handleDelete(message) {
        if (!isAuthenticated) return;

        const { messageId, conversationId } = message;

        // Verify user is the sender
        const { data: existingMessage } = await supabase
            .from('messages')
            .select('sender_id')
            .eq('id', messageId)
            .single();

        if (!existingMessage || existingMessage.sender_id !== userId) {
            send({ type: 'error', error: 'Can only delete own messages' });
            return;
        }

        // Soft delete
        await supabase
            .from('messages')
            .update({
                is_deleted: true,
                deleted_at: new Date().toISOString(),
            })
            .eq('id', messageId);

        // Broadcast delete
        const deleteData = {
            type: 'delete',
            messageId,
            conversationId,
            senderId: userId,
            timestamp: new Date().toISOString(),
        };

        broadcastToConversation(conversationId, deleteData, userId);
    }

    // ========== CALL SIGNALING HANDLERS ==========

    // Handle incoming call offer
    async function handleCallOffer(message) {
        if (!isAuthenticated) {
            send({ type: 'error', error: 'Not authenticated' });
            return;
        }

        const { recipientId, callId, sdp, sdpType, isVideo, conversationId } = message;

        // Forward offer to recipient
        const offerData = {
            type: 'call_offer',
            callId,
            conversationId,
            senderId: userId,
            recipientId,
            sdp,
            sdpType,
            isVideo,
            timestamp: new Date().toISOString(),
        };

        if (clients.has(recipientId)) {
            clients.get(recipientId).send(JSON.stringify(offerData));
            console.log(`Call offer forwarded from ${userId} to ${recipientId}`);
        } else {
            // Recipient offline
            send({ type: 'call_error', callId, error: 'User is offline' });
        }
    }

    // Handle call answer
    async function handleCallAnswer(message) {
        if (!isAuthenticated) return;

        const { recipientId, callId, sdp, sdpType } = message;

        const answerData = {
            type: 'call_answer',
            callId,
            senderId: userId,
            recipientId,
            sdp,
            sdpType,
            timestamp: new Date().toISOString(),
        };

        if (clients.has(recipientId)) {
            clients.get(recipientId).send(JSON.stringify(answerData));
            console.log(`Call answer forwarded from ${userId} to ${recipientId}`);
        }
    }

    // Handle ICE candidate
    async function handleIceCandidate(message) {
        if (!isAuthenticated) return;

        const { recipientId, callId, candidate, sdpMid, sdpMLineIndex } = message;

        const candidateData = {
            type: 'ice_candidate',
            callId,
            senderId: userId,
            recipientId,
            candidate,
            sdpMid,
            sdpMLineIndex,
            timestamp: new Date().toISOString(),
        };

        if (clients.has(recipientId)) {
            clients.get(recipientId).send(JSON.stringify(candidateData));
        }
    }

    // Handle call end
    async function handleCallEnd(message) {
        if (!isAuthenticated) return;

        const { recipientId, callId, reason, duration } = message;

        const endData = {
            type: 'call_end',
            callId,
            senderId: userId,
            recipientId,
            reason,
            duration,
            timestamp: new Date().toISOString(),
        };

        if (clients.has(recipientId)) {
            clients.get(recipientId).send(JSON.stringify(endData));
        }
    }

    // Broadcast to all users in a conversation
    function broadcastToConversation(conversationId, data, excludeUserId = null) {
        if (!rooms.has(conversationId)) return;

        const roomUsers = rooms.get(conversationId);
        for (const roomUserId of roomUsers) {
            if (roomUserId !== excludeUserId && clients.has(roomUserId)) {
                const client = clients.get(roomUserId);
                if (client.readyState === WebSocket.OPEN) {
                    client.send(JSON.stringify(data));
                }
            }
        }
    }

    // Handle disconnect
    ws.on('close', () => {
        console.log(`Client disconnected: ${userId}`);

        if (userId) {
            // Remove from all rooms
            for (const [conversationId, users] of rooms) {
                users.delete(userId);
                if (users.size === 0) {
                    rooms.delete(conversationId);
                }
            }

            // Remove from clients
            clients.delete(userId);
        }
    });

    // Handle errors
    ws.on('error', (error) => {
        console.error('WebSocket error:', error);
    });
});

// Start server
const PORT = process.env.WS_PORT || 3001;
server.listen(PORT, () => {
    console.log(`WebSocket server running on port ${PORT}`);
    console.log(`WebSocket URL: ws://localhost:${PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('SIGTERM received, closing server...');
    server.close(() => {
        console.log('Server closed');
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    console.log('SIGINT received, closing server...');
    server.close(() => {
        console.log('Server closed');
        process.exit(0);
    });
});
