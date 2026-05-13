# WebSocket Chat with End-to-End Encryption Setup Guide

## Overview
This implementation replaces Supabase Realtime with a custom WebSocket server for real-time chat, with full end-to-end encryption using ECDH + AES-256-GCM.

## Architecture

```
┌─────────────┐         WebSocket (ws://)         ┌──────────────┐
│   Flutter   │◄─────────────────────────────────►│ Node.js      │
│   Client    │  Encrypted messages (E2E)         │ WebSocket    │
│             │                                    │ Server       │
└──────┬──────┘                                    └──────┬───────┘
       │                                                  │
       │  1. ECDH Key Exchange                             │  Store encrypted
       │  2. AES-256-GCM Encryption                      │  messages in DB
       ▼                                                  ▼
┌─────────────┐                                    ┌──────────────┐
│ Encryption  │                                    │   Supabase   │
│ Service     │                                    │   Database   │
│ (ECDH+HKDF) │                                    │              │
└─────────────┘                                    └──────────────┘
```

## Files Created

### Frontend (Flutter)
1. `lib/websocket_chat_service.dart` - WebSocket client with E2E encryption
2. `lib/encryption_service.dart` - ECDH key exchange + AES-256-GCM encryption (already exists)

### Backend (Node.js)
1. `backend/websocket-server.js` - WebSocket server for message routing

### Database
1. `backend/supabase/migrations/TELEGRAM_FEATURES_MIGRATION.sql` - Updated schema with E2E support

## Setup Instructions

### 1. Install Dependencies

**Backend:**
```bash
cd backend
npm install
```

**Frontend:**
```bash
cd Frontend
flutter pub get
```

### 2. Environment Variables

Add to `backend/.env`:
```env
WS_PORT=3001
SUPABASE_URL=your_supabase_url
SUPABASE_SERVICE_KEY=your_service_key
```

Add to `Frontend/.env`:
```env
WS_SERVER_URL=ws://your-server:3001
```

### 3. Run WebSocket Server

```bash
# Development with auto-reload
cd backend
npm run ws:dev

# Production
cd backend
npm run ws
```

### 4. Run Database Migration

Execute the SQL in `backend/supabase/migrations/TELEGRAM_FEATURES_MIGRATION.sql` in your Supabase SQL Editor.

## Usage Example

```dart
import 'package:flutter/material.dart';
import 'websocket_chat_service.dart';
import 'encryption_service.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String recipientId;

  const ChatScreen({
    required this.conversationId,
    required this.recipientId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final WebSocketChatService _chatService = WebSocketChatService();
  final TextEditingController _messageController = TextEditingController();
  final List<ChatMessage> _messages = [];
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    _initializeChat();
  }

  Future<void> _initializeChat() async {
    // Initialize encryption
    await EncryptionService().initialize();
    
    // Connect to WebSocket
    await _chatService.connect(
      serverUrl: 'ws://your-server:3001',
    );
    
    // Join conversation room
    _chatService.joinConversation(widget.conversationId);
    
    // Listen for messages
    _chatService.messageStream.listen((message) {
      setState(() {
        _messages.add(message);
      });
    });
    
    // Listen for typing indicators
    _chatService.typingStream.listen((event) {
      if (event.userId == widget.recipientId) {
        setState(() {
          _isTyping = event.isTyping;
        });
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    
    // Send encrypted message
    await _chatService.sendTextMessage(
      conversationId: widget.conversationId,
      recipientId: widget.recipientId,
      text: text,
    );
    
    _messageController.clear();
  }

  Future<void> _sendVoiceMessage(String voiceUrl, int duration) async {
    await _chatService.sendVoiceMessage(
      conversationId: widget.conversationId,
      recipientId: widget.recipientId,
      voiceUrl: voiceUrl,
      duration: duration,
    );
  }

  void _onTypingChanged(bool isTyping) {
    _chatService.sendTypingStatus(
      widget.conversationId,
      widget.recipientId,
      isTyping,
    );
  }

  @override
  void dispose() {
    _chatService.leaveConversation(widget.conversationId);
    _chatService.disconnect();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Chat'),
        subtitle: _isTyping ? Text('typing...') : null,
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return ListTile(
                  title: Text(msg.content),
                  subtitle: Text(msg.senderId == widget.recipientId ? 'Friend' : 'You'),
                );
              },
            ),
          ),
          // Input field
          Padding(
            padding: EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    onChanged: (text) => _onTypingChanged(text.isNotEmpty),
                    decoration: InputDecoration(hintText: 'Type a message...'),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

## Encryption Details

### Key Exchange (ECDH)
- Uses NIST P-256 (secp256r1) elliptic curve
- Each user generates a key pair on first app launch
- Public keys are stored in `user_keys` table
- Private keys are stored securely using `flutter_secure_storage`

### Message Encryption (AES-256-GCM)
1. Sender fetches recipient's public key from Supabase
2. ECDH generates shared secret between sender's private key + recipient's public key
3. HKDF derives AES-256 key from shared secret with directional info
4. Message is encrypted with AES-256-GCM (12-byte nonce, 16-byte tag)
5. Encrypted payload is sent via WebSocket

### Security Features
- **Forward secrecy**: Each conversation uses unique derived keys
- **Directional encryption**: A→B and B→A use different keys (prevents reflection attacks)
- **Authenticated encryption**: GCM provides both confidentiality and integrity
- **Key rotation**: Keys can be regenerated if needed

## WebSocket Events

### Client → Server
- `auth` - Authenticate with user ID
- `join` - Join a conversation room
- `leave` - Leave a conversation room
- `message` - Send encrypted message
- `typing` - Send typing indicator
- `read` - Mark message as read
- `edit` - Edit a message
- `delete` - Delete a message

### Server → Client
- `auth` - Authentication confirmation
- `joined` - Successfully joined room
- `left` - Successfully left room
- `message` - New encrypted message
- `typing` - Typing indicator from other user
- `read` - Read receipt
- `edit` - Message edited
- `delete` - Message deleted
- `error` - Error message

## Features Implemented

✅ End-to-end encryption (ECDH + AES-256-GCM)
✅ WebSocket real-time messaging
✅ Typing indicators
✅ Read receipts
✅ Message editing
✅ Message deletion
✅ Voice messages (encrypted)
✅ Reply to messages
✅ Connection status monitoring
✅ Auto-reconnect with exponential backoff

## Next Steps

1. Deploy WebSocket server to production (e.g., Railway, Render, AWS)
2. Use wss:// (WebSocket Secure) in production
3. Add message persistence and offline support
4. Implement group chat encryption (using group keys)
5. Add file sharing with encrypted uploads

## Testing

```bash
# Start WebSocket server
cd backend && npm run ws:dev

# In another terminal, test with wscat
npm install -g wscat
wscat -c ws://localhost:3001?token=your_user_id

# Send a test message
> {"type":"auth","userId":"your_user_id"}
> {"type":"join","conversationId":"test-conv-id"}
> {"type":"message","conversationId":"test-conv-id","recipientId":"other-user-id","content":"encrypted-content-here","contentType":"text"}
```
