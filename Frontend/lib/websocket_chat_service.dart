import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'encryption_service.dart';
import 'supabase_service.dart';
import 'local_message_cache.dart';

/// Extension to convert CachedMessage to ChatMessage
extension CachedMessageExtension on CachedMessage {
  ChatMessage toChatMessage() {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      content: content,
      encryptedContent: '',
      contentType: contentType,
      replyTo: replyTo,
      timestamp: timestamp,
      isEdited: isEdited,
      isDeleted: isDeleted,
    );
  }
}

/// WebSocket-based chat service with end-to-end encryption
/// Replaces Supabase Realtime for real-time messaging
class WebSocketChatService {
  static final WebSocketChatService _instance =
      WebSocketChatService._internal();
  factory WebSocketChatService() => _instance;
  WebSocketChatService._internal();

  WebSocketChannel? _channel;
  final _encryptionService = EncryptionService();
  final _localCache = LocalMessageCache();

  // Stream controllers
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _typingController = StreamController<TypingEvent>.broadcast();
  final _readReceiptController = StreamController<ReadReceiptEvent>.broadcast();
  final _connectionController = StreamController<ConnectionStatus>.broadcast();
  final _callSignalController = StreamController<CallSignal>.broadcast();

  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<TypingEvent> get typingStream => _typingController.stream;
  Stream<ReadReceiptEvent> get readReceiptStream =>
      _readReceiptController.stream;
  Stream<ConnectionStatus> get connectionStream => _connectionController.stream;
  Stream<CallSignal> get callSignalStream => _callSignalController.stream;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  String? _currentUserId;
  String? _currentConversationId;

  // Reconnect config
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;
  static const _reconnectDelay = Duration(seconds: 3);

  /// Initialize and connect to WebSocket server
  Future<void> connect({required String serverUrl}) async {
    try {
      _updateStatus(ConnectionStatus.connecting);

      final user = SupabaseService().client.auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      _currentUserId = user.id;

      // Connect with auth token
      final wsUrl = Uri.parse('$serverUrl?token=${user.id}');
      _channel = IOWebSocketChannel.connect(
        wsUrl.toString(),
        pingInterval: const Duration(seconds: 30),
      );

      // Listen to messages
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDisconnected,
      );

      _updateStatus(ConnectionStatus.connected);
      _reconnectAttempts = 0;

      // Send auth message
      _sendAuth(user.id);
    } catch (e) {
      print('WebSocket connection error: $e');
      _updateStatus(ConnectionStatus.error);
      _scheduleReconnect(serverUrl);
    }
  }

  /// Send auth message to server
  void _sendAuth(String userId) {
    _send({
      'type': 'auth',
      'userId': userId,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Join a conversation room
  void joinConversation(String conversationId) {
    _currentConversationId = conversationId;
    _send({'type': 'join', 'conversationId': conversationId});
  }

  /// Leave a conversation room
  void leaveConversation(String conversationId) {
    _send({'type': 'leave', 'conversationId': conversationId});
    if (_currentConversationId == conversationId) {
      _currentConversationId = null;
    }
  }

  /// Send encrypted text message
  Future<bool> sendTextMessage({
    required String conversationId,
    required String recipientId,
    required String text,
    String? replyToMessageId,
  }) async {
    try {
      // Generate temporary ID for local cache
      final tempId = DateTime.now().millisecondsSinceEpoch.toString();
      final now = DateTime.now();

      // Save to local cache first (plaintext for sender)
      await _localCache.saveSentMessage(
        conversationId: conversationId,
        messageId: tempId,
        content: text,
        contentType: 'text',
        replyTo: replyToMessageId,
        timestamp: now,
      );

      // Emit to local stream so sender sees it immediately
      _messageController.add(
        ChatMessage(
          id: tempId,
          conversationId: conversationId,
          senderId: _currentUserId!,
          content: text,
          encryptedContent: '',
          contentType: 'text',
          replyTo: replyToMessageId,
          timestamp: now,
        ),
      );

      // Encrypt the message content
      final encryptedContent = await _encryptionService.encrypt(
        text,
        recipientId,
      );

      _send({
        'type': 'message',
        'conversationId': conversationId,
        'recipientId': recipientId,
        'content': encryptedContent,
        'contentType': 'text',
        'replyTo': replyToMessageId,
        'timestamp': now.toIso8601String(),
        'tempId': tempId,
      });

      return true;
    } catch (e) {
      print('Error sending encrypted message: $e');
      return false;
    }
  }

  /// Send encrypted voice message
  Future<bool> sendVoiceMessage({
    required String conversationId,
    required String recipientId,
    required String voiceUrl,
    required int duration,
    String? replyToMessageId,
  }) async {
    try {
      // Generate temporary ID for local cache
      final tempId = DateTime.now().millisecondsSinceEpoch.toString();
      final now = DateTime.now();

      // Save to local cache first
      await _localCache.saveSentMessage(
        conversationId: conversationId,
        messageId: tempId,
        content: '[Voice message]',
        contentType: 'voice',
        replyTo: replyToMessageId,
        timestamp: now,
      );

      // Emit to local stream
      _messageController.add(
        ChatMessage(
          id: tempId,
          conversationId: conversationId,
          senderId: _currentUserId!,
          content: '[Voice message]',
          encryptedContent: '',
          contentType: 'voice',
          voiceUrl: voiceUrl,
          voiceDuration: duration,
          replyTo: replyToMessageId,
          timestamp: now,
        ),
      );

      // Encrypt voice metadata
      final voiceData = jsonEncode({
        'voiceUrl': voiceUrl,
        'duration': duration,
      });
      final encryptedContent = await _encryptionService.encrypt(
        voiceData,
        recipientId,
      );

      _send({
        'type': 'message',
        'conversationId': conversationId,
        'recipientId': recipientId,
        'content': encryptedContent,
        'contentType': 'voice',
        'replyTo': replyToMessageId,
        'timestamp': now.toIso8601String(),
        'tempId': tempId,
      });

      return true;
    } catch (e) {
      print('Error sending voice message: $e');
      return false;
    }
  }

  /// Load cached messages for a conversation
  Future<List<ChatMessage>> loadCachedMessages(String conversationId) async {
    final cachedMessages = await _localCache.getMessages(conversationId);
    return cachedMessages.map((m) => m.toChatMessage()).toList();
  }

  /// Load and emit cached messages for current conversation
  Future<void> loadAndEmitCachedMessages(String conversationId) async {
    final messages = await loadCachedMessages(conversationId);
    for (final message in messages) {
      _messageController.add(message);
    }
  }

  /// Send typing indicator
  void sendTypingStatus(
    String conversationId,
    String recipientId,
    bool isTyping,
  ) {
    _send({
      'type': 'typing',
      'conversationId': conversationId,
      'recipientId': recipientId,
      'isTyping': isTyping,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Send read receipt
  void sendReadReceipt(String conversationId, String messageId) {
    _send({
      'type': 'read',
      'conversationId': conversationId,
      'messageId': messageId,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Edit a message
  Future<bool> editMessage({
    required String messageId,
    required String conversationId,
    required String recipientId,
    required String newText,
  }) async {
    try {
      final encryptedContent = await _encryptionService.encrypt(
        newText,
        recipientId,
      );

      _send({
        'type': 'edit',
        'messageId': messageId,
        'conversationId': conversationId,
        'recipientId': recipientId,
        'content': encryptedContent,
        'timestamp': DateTime.now().toIso8601String(),
      });

      return true;
    } catch (e) {
      print('Error editing message: $e');
      return false;
    }
  }

  /// Delete a message for everyone
  Future<bool> deleteMessage({
    required String messageId,
    required String conversationId,
    required String recipientId,
  }) async {
    try {
      _send({
        'type': 'delete',
        'messageId': messageId,
        'conversationId': conversationId,
        'recipientId': recipientId,
        'timestamp': DateTime.now().toIso8601String(),
      });

      return true;
    } catch (e) {
      print('Error deleting message: $e');
      return false;
    }
  }

  /// Handle incoming WebSocket messages
  void _onMessage(dynamic data) {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      final type = message['type'] as String;

      switch (type) {
        case 'message':
          _handleIncomingMessage(message);
          break;
        case 'typing':
          _handleTypingEvent(message);
          break;
        case 'read':
          _handleReadReceipt(message);
          break;
        case 'edit':
          _handleEditEvent(message);
          break;
        case 'delete':
          _handleDeleteEvent(message);
          break;
        // Call signaling
        case 'call_offer':
        case 'call_answer':
        case 'ice_candidate':
        case 'call_end':
        case 'call_error':
          _callSignalController.add(CallSignal.fromJson(message));
          break;
        case 'error':
          print('Server error: ${message['error']}');
          break;
      }
    } catch (e) {
      print('Error handling message: $e');
    }
  }

  /// Handle incoming encrypted message
  Future<void> _handleIncomingMessage(Map<String, dynamic> message) async {
    try {
      final senderId = message['senderId'] as String;
      final encryptedContent = message['content'] as String;
      final contentType = message['contentType'] as String;

      // Decrypt the message
      String decryptedContent;
      try {
        decryptedContent = await _encryptionService.decrypt(
          encryptedContent,
          senderId,
        );
      } catch (e) {
        print('Failed to decrypt message: $e');
        decryptedContent = '[Encrypted message - unable to decrypt]';
      }

      // Parse voice message data if applicable
      String? voiceUrl;
      int? voiceDuration;
      if (contentType == 'voice') {
        try {
          final voiceData =
              jsonDecode(decryptedContent) as Map<String, dynamic>;
          voiceUrl = voiceData['voiceUrl'] as String?;
          voiceDuration = voiceData['duration'] as int?;
          decryptedContent = '[Voice message]';
        } catch (e) {
          print('Error parsing voice data: $e');
        }
      }

      final chatMessage = ChatMessage(
        id:
            message['messageId'] as String? ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: message['conversationId'] as String,
        senderId: senderId,
        content: decryptedContent,
        encryptedContent: encryptedContent,
        contentType: contentType,
        voiceUrl: voiceUrl,
        voiceDuration: voiceDuration,
        replyTo: message['replyTo'] as String?,
        timestamp: DateTime.parse(message['timestamp'] as String),
        isEdited: message['isEdited'] as bool? ?? false,
      );

      _messageController.add(chatMessage);
    } catch (e) {
      print('Error processing incoming message: $e');
    }
  }

  void _handleTypingEvent(Map<String, dynamic> message) {
    _typingController.add(
      TypingEvent(
        conversationId: message['conversationId'] as String,
        userId: message['senderId'] as String,
        isTyping: message['isTyping'] as bool,
      ),
    );
  }

  void _handleReadReceipt(Map<String, dynamic> message) {
    _readReceiptController.add(
      ReadReceiptEvent(
        conversationId: message['conversationId'] as String,
        messageId: message['messageId'] as String,
        userId: message['senderId'] as String,
        timestamp: DateTime.parse(message['timestamp'] as String),
      ),
    );
  }

  void _handleEditEvent(Map<String, dynamic> message) {
    // Notify listeners about edit
    _messageController.add(
      ChatMessage(
        id: message['messageId'] as String,
        conversationId: message['conversationId'] as String,
        senderId: message['senderId'] as String,
        content: '[Edited message]',
        encryptedContent: message['content'] as String,
        contentType: 'text',
        timestamp: DateTime.parse(message['timestamp'] as String),
        isEdited: true,
      ),
    );
  }

  void _handleDeleteEvent(Map<String, dynamic> message) {
    // Notify listeners about delete
    _messageController.add(
      ChatMessage(
        id: message['messageId'] as String,
        conversationId: message['conversationId'] as String,
        senderId: message['senderId'] as String,
        content: '[Deleted message]',
        encryptedContent: '',
        contentType: 'deleted',
        timestamp: DateTime.now(),
        isDeleted: true,
      ),
    );
  }

  void _onError(error) {
    print('WebSocket error: $error');
    _updateStatus(ConnectionStatus.error);
  }

  void _onDisconnected() {
    print('WebSocket disconnected');
    _updateStatus(ConnectionStatus.disconnected);
    _scheduleReconnect('');
  }

  void _scheduleReconnect(String serverUrl) {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      print('Max reconnection attempts reached');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay * (_reconnectAttempts + 1), () {
      _reconnectAttempts++;
      connect(serverUrl: serverUrl);
    });
  }

  void _updateStatus(ConnectionStatus status) {
    _status = status;
    _connectionController.add(status);
  }

  void _send(Map<String, dynamic> data) {
    if (_channel != null && _status == ConnectionStatus.connected) {
      _channel!.sink.add(jsonEncode(data));
    }
  }

  /// Send raw message directly (for call signaling)
  void sendRawMessage(Map<String, dynamic> data) {
    _send(data);
  }

  /// Disconnect from WebSocket
  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _updateStatus(ConnectionStatus.disconnected);
  }

  /// Dispose resources
  void dispose() {
    disconnect();
    _messageController.close();
    _typingController.close();
    _readReceiptController.close();
    _connectionController.close();
    _callSignalController.close();
  }
}

/// Chat message model
class ChatMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final String encryptedContent;
  final String contentType;
  final String? voiceUrl;
  final int? voiceDuration;
  final String? replyTo;
  final DateTime timestamp;
  final bool isEdited;
  final bool isDeleted;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    required this.encryptedContent,
    required this.contentType,
    this.voiceUrl,
    this.voiceDuration,
    this.replyTo,
    required this.timestamp,
    this.isEdited = false,
    this.isDeleted = false,
  });
}

/// Typing event model
class TypingEvent {
  final String conversationId;
  final String userId;
  final bool isTyping;

  TypingEvent({
    required this.conversationId,
    required this.userId,
    required this.isTyping,
  });
}

/// Read receipt event model
class ReadReceiptEvent {
  final String conversationId;
  final String messageId;
  final String userId;
  final DateTime timestamp;

  ReadReceiptEvent({
    required this.conversationId,
    required this.messageId,
    required this.userId,
    required this.timestamp,
  });
}

/// Call signal model for WebRTC signaling
class CallSignal {
  final String
  type; // call_offer, call_answer, ice_candidate, call_end, call_error
  final String callId;
  final String senderId;
  final String? recipientId;
  final String? conversationId;
  final String? sdp;
  final String? sdpType;
  final bool? isVideo;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final String? reason;
  final int? duration;
  final String? error;
  final DateTime? timestamp;

  CallSignal({
    required this.type,
    required this.callId,
    required this.senderId,
    this.recipientId,
    this.conversationId,
    this.sdp,
    this.sdpType,
    this.isVideo,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.reason,
    this.duration,
    this.error,
    this.timestamp,
  });

  factory CallSignal.fromJson(Map<String, dynamic> json) {
    return CallSignal(
      type: json['type'] as String,
      callId: json['callId'] as String,
      senderId: json['senderId'] as String,
      recipientId: json['recipientId'] as String?,
      conversationId: json['conversationId'] as String?,
      sdp: json['sdp'] as String?,
      sdpType: json['sdpType'] as String?,
      isVideo: json['isVideo'] as bool?,
      candidate: json['candidate'] as String?,
      sdpMid: json['sdpMid'] as String?,
      sdpMLineIndex: json['sdpMLineIndex'] as int?,
      reason: json['reason'] as String?,
      duration: json['duration'] as int?,
      error: json['error'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
    );
  }
}

/// Connection status enum
enum ConnectionStatus { disconnected, connecting, connected, error }
