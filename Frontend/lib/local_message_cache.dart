import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Local cache for storing sent messages in plaintext
/// This allows the sender to see their own messages without needing to decrypt them
class LocalMessageCache {
  static final LocalMessageCache _instance = LocalMessageCache._internal();
  factory LocalMessageCache() => _instance;
  LocalMessageCache._internal();

  SharedPreferences? _prefs;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  /// Get cache key for a conversation
  String _getCacheKey(String conversationId) {
    return 'messages_$conversationId';
  }

  /// Save a sent message to local cache
  Future<void> saveSentMessage({
    required String conversationId,
    required String messageId,
    required String content,
    required String contentType,
    String? replyTo,
    DateTime? timestamp,
  }) async {
    await initialize();

    final key = _getCacheKey(conversationId);
    final existingJson = _prefs!.getString(key);

    List<Map<String, dynamic>> messages = [];
    if (existingJson != null) {
      final List<dynamic> decoded = jsonDecode(existingJson);
      messages = decoded.cast<Map<String, dynamic>>();
    }

    // Add new message
    messages.add({
      'id': messageId,
      'conversationId': conversationId,
      'senderId': 'me', // Local identifier
      'content': content,
      'contentType': contentType,
      'replyTo': replyTo,
      'timestamp': (timestamp ?? DateTime.now()).toIso8601String(),
      'isSentByMe': true,
      'isEdited': false,
      'isDeleted': false,
    });

    // Keep only last 500 messages per conversation
    if (messages.length > 500) {
      messages = messages.sublist(messages.length - 500);
    }

    await _prefs!.setString(key, jsonEncode(messages));
  }

  /// Get all cached messages for a conversation
  Future<List<CachedMessage>> getMessages(String conversationId) async {
    await initialize();

    final key = _getCacheKey(conversationId);
    final json = _prefs!.getString(key);

    if (json == null) return [];

    try {
      final List<dynamic> decoded = jsonDecode(json);
      return decoded.map((m) => CachedMessage.fromJson(m)).toList();
    } catch (e) {
      print('Error parsing cached messages: $e');
      return [];
    }
  }

  /// Update a message (for edit/delete)
  Future<void> updateMessage({
    required String conversationId,
    required String messageId,
    String? newContent,
    bool? isDeleted,
    bool? isEdited,
  }) async {
    await initialize();

    final key = _getCacheKey(conversationId);
    final existingJson = _prefs!.getString(key);

    if (existingJson == null) return;

    List<Map<String, dynamic>> messages = [];
    final List<dynamic> decoded = jsonDecode(existingJson);
    messages = decoded.cast<Map<String, dynamic>>();

    // Find and update message
    for (int i = 0; i < messages.length; i++) {
      if (messages[i]['id'] == messageId) {
        if (newContent != null) {
          messages[i]['content'] = newContent;
          messages[i]['isEdited'] = true;
        }
        if (isDeleted != null) {
          messages[i]['isDeleted'] = true;
          messages[i]['content'] = '[Deleted message]';
        }
        if (isEdited != null) {
          messages[i]['isEdited'] = isEdited;
        }
        break;
      }
    }

    await _prefs!.setString(key, jsonEncode(messages));
  }

  /// Mark message as delivered/read
  Future<void> markAsDelivered(String conversationId, String messageId) async {
    await initialize();

    final key = _getCacheKey(conversationId);
    final existingJson = _prefs!.getString(key);

    if (existingJson == null) return;

    List<Map<String, dynamic>> messages = [];
    final List<dynamic> decoded = jsonDecode(existingJson);
    messages = decoded.cast<Map<String, dynamic>>();

    for (int i = 0; i < messages.length; i++) {
      if (messages[i]['id'] == messageId) {
        messages[i]['isDelivered'] = true;
        break;
      }
    }

    await _prefs!.setString(key, jsonEncode(messages));
  }

  Future<void> markAsRead(String conversationId, String messageId) async {
    await initialize();

    final key = _getCacheKey(conversationId);
    final existingJson = _prefs!.getString(key);

    if (existingJson == null) return;

    List<Map<String, dynamic>> messages = [];
    final List<dynamic> decoded = jsonDecode(existingJson);
    messages = decoded.cast<Map<String, dynamic>>();

    for (int i = 0; i < messages.length; i++) {
      if (messages[i]['id'] == messageId) {
        messages[i]['isRead'] = true;
        break;
      }
    }

    await _prefs!.setString(key, jsonEncode(messages));
  }

  /// Clear all messages for a conversation
  Future<void> clearMessages(String conversationId) async {
    await initialize();
    await _prefs!.remove(_getCacheKey(conversationId));
  }

  /// Clear all cached messages
  Future<void> clearAllMessages() async {
    await initialize();
    final keys = _prefs!.getKeys().where((k) => k.startsWith('messages_'));
    for (final key in keys) {
      await _prefs!.remove(key);
    }
  }

  /// Get conversation list with last message
  Future<List<Map<String, dynamic>>> getConversationList() async {
    await initialize();

    final keys = _prefs!.getKeys().where((k) => k.startsWith('messages_'));
    final List<Map<String, dynamic>> conversations = [];

    for (final key in keys) {
      final conversationId = key.replaceFirst('messages_', '');
      final messages = await getMessages(conversationId);

      if (messages.isNotEmpty) {
        final lastMessage = messages.last;
        conversations.add({
          'conversationId': conversationId,
          'lastMessage': lastMessage.content,
          'lastMessageTime': lastMessage.timestamp,
          'unreadCount': messages
              .where((m) => !m.isSentByMe && !m.isRead)
              .length,
        });
      }
    }

    return conversations;
  }
}

/// Cached message model
class CachedMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final String contentType;
  final String? replyTo;
  final DateTime timestamp;
  final bool isSentByMe;
  final bool isEdited;
  final bool isDeleted;
  final bool isDelivered;
  final bool isRead;

  CachedMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    required this.contentType,
    this.replyTo,
    required this.timestamp,
    required this.isSentByMe,
    this.isEdited = false,
    this.isDeleted = false,
    this.isDelivered = false,
    this.isRead = false,
  });

  factory CachedMessage.fromJson(Map<String, dynamic> json) {
    return CachedMessage(
      id: json['id'] ?? '',
      conversationId: json['conversationId'] ?? '',
      senderId: json['senderId'] ?? '',
      content: json['content'] ?? '',
      contentType: json['contentType'] ?? 'text',
      replyTo: json['replyTo'],
      timestamp: DateTime.parse(
        json['timestamp'] ?? DateTime.now().toIso8601String(),
      ),
      isSentByMe: json['isSentByMe'] ?? false,
      isEdited: json['isEdited'] ?? false,
      isDeleted: json['isDeleted'] ?? false,
      isDelivered: json['isDelivered'] ?? false,
      isRead: json['isRead'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'senderId': senderId,
      'content': content,
      'contentType': contentType,
      'replyTo': replyTo,
      'timestamp': timestamp.toIso8601String(),
      'isSentByMe': isSentByMe,
      'isEdited': isEdited,
      'isDeleted': isDeleted,
      'isDelivered': isDelivered,
      'isRead': isRead,
    };
  }
}
