import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import '../supabase_service.dart';
import '../encryption_service.dart';
import '../reaction_service.dart';
import '../storage_service.dart';
import 'user_profile_screen.dart';
import 'call_screen.dart';

class ChatDetailScreen extends StatefulWidget {
  final String? conversationId;
  final String? otherUserId;
  final String otherUserName;
  final String? otherUserAvatar;

  const ChatDetailScreen({
    super.key,
    this.conversationId,
    this.otherUserId,
    this.otherUserName = 'User',
    this.otherUserAvatar,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final DataService _dataService = DataService();
  final EncryptionService _encryptionService = EncryptionService();
  final ReactionService _reactionService = ReactionService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Message> _messages = [];
  bool _isLoading = true;
  String? _conversationId;
  bool _isSending = false;
  bool _isSendingMedia = false;
  bool _encryptionReady = false;
  final Set<String> _locallyAddedMessageIds = {};
  Message? _replyingToMessage;
  Map<String, Map<String, ReactionInfo>> _messageReactions = {};

  // Online status tracking
  bool _isOtherUserOnline = false;
  DateTime? _otherUserLastSeen;
  UserProfile? _otherUserProfile;

  /// Resolved peer (may be filled from DB when opening chat with only [conversationId]).
  String? _peerUserId;

  // Realtime subscription for new messages
  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _reactionsChannel;
  StreamSubscription<void>? _pollingSubscription;

  String get _peerDisplayName {
    final p = _otherUserProfile;
    if (p?.displayName != null && p!.displayName!.trim().isNotEmpty) {
      return p.displayName!;
    }
    if (p?.username != null && p!.username!.trim().isNotEmpty) {
      return p.username!;
    }
    return widget.otherUserName;
  }

  String? get _peerAvatarUrl =>
      _otherUserProfile?.avatarUrl ?? widget.otherUserAvatar;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    _peerUserId = widget.otherUserId;
    _initializeEncryption();
  }

  void _openPeerProfile() {
    final id = _peerUserId;
    if (id == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => UserProfileScreen(userId: id),
      ),
    );
  }

  void _startCall({required bool isVideo}) {
    if (_peerUserId == null || _conversationId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => CallScreen(
          conversationId: _conversationId!,
          recipientId: _peerUserId!,
          recipientName: _peerDisplayName,
          recipientAvatar: _peerAvatarUrl,
          isVideo: isVideo,
        ),
      ),
    );
  }

  void _showChatOptions() {
    final c = ColonyColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.person_outline, color: c.accent),
              title: Text(
                'View profile',
                style: TextStyle(color: c.primaryText),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _openPeerProfile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _initializeEncryption() async {
    try {
      await _encryptionService.initialize();
      setState(() {
        _encryptionReady = _encryptionService.isReady;
      });
    } catch (e) {
      print('Error initializing encryption: $e');
    }
    await _loadMessages();
    await _loadOtherUserProfile();
    _setupRealtimeSubscription();
    _updateLastSeen();
  }

  Future<void> _loadOtherUserProfile() async {
    if (_peerUserId == null) return;

    try {
      final profile = await _dataService.getUserProfile(_peerUserId!);
      if (mounted && profile != null) {
        setState(() {
          _otherUserProfile = profile;
          _isOtherUserOnline = profile.isOnline;
          _otherUserLastSeen = profile.lastSeen;
        });
      }
    } catch (e) {
      print('Error loading other user profile: $e');
    }
  }

  void _setupRealtimeSubscription() {
    if (_conversationId == null) return;

    // Use Supabase Realtime for instant message updates
    _messagesChannel?.unsubscribe();
    _messagesChannel = Supabase.instance.client
        .channel('chat_${_conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: _conversationId!,
          ),
          callback: (payload) => _onNewRealtimeMessage(payload),
        )
        .subscribe();

    _reactionsChannel?.unsubscribe();
    _reactionsChannel = Supabase.instance.client
        .channel('chat_reactions_${_conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'message_reactions',
          callback: (_) => _loadReactions(),
        )
        .subscribe();

    // Poll online status every 30 seconds (less aggressive)
    _pollingSubscription = Stream.periodic(
      const Duration(seconds: 30),
      (_) => _checkOnlineStatus(),
    ).listen((_) {});
  }

  void _onNewRealtimeMessage(PostgresChangePayload payload) async {
    if (!mounted) return;
    final newRow = payload.newRecord;
    if (newRow.isEmpty) return;
    final msgId = newRow['id']?.toString();
    if (msgId == null) return;
    final existingIndex = _messages.indexWhere((m) => m.id == msgId);
    if (payload.eventType != PostgresChangeEvent.insert &&
        existingIndex != -1) {
      final updated = Message.fromJson(newRow);
      setState(() {
        _messages[existingIndex] = updated;
      });
      return;
    }
    if (existingIndex != -1) return;
    if (_locallyAddedMessageIds.contains(msgId)) return;

    final currentUserId = SupabaseService().client.auth.currentUser?.id;
    final senderId = newRow['sender_id'] as String? ?? '';
    final rawContent = newRow['content'] as String? ?? '';

    String displayContent = rawContent;
    if (_encryptionReady && EncryptionService.isEncryptedPayload(rawContent)) {
      final isMe = senderId == currentUserId;
      final peerId = isMe ? _peerUserId : senderId;
      if (peerId != null) {
        final decrypted = await _encryptionService.tryDecrypt(
          rawContent,
          peerId,
          isOutgoing: isMe,
        );
        displayContent = decrypted ?? '[Encrypted message - unable to decrypt]';
      } else {
        displayContent = '[Encrypted message - unable to decrypt]';
      }
    }

    if (!mounted) return;

    final newMsg = Message.fromJson(newRow);
    setState(() {
      // Final deduplication check inside setState
      if (_messages.any((m) => m.id == msgId)) return;
      
      _messages.add(
        Message(
          id: newMsg.id,
          senderId: newMsg.senderId,
          content: displayContent,
          isRead: newMsg.isRead,
          createdAt: newMsg.createdAt,
          deliveredAt: newMsg.deliveredAt,
          seenAt: newMsg.seenAt,
          mediaUrl: newMsg.mediaUrl,
          mediaType: newMsg.mediaType,
          replyToId: newMsg.replyToId,
          deletedForEveryone: newMsg.deletedForEveryone,
        ),
      );
    });
    _loadReactions();
    _scrollToBottom();
    if (_conversationId != null) {
      await _dataService.markMessagesAsSeen(_conversationId!);
    }
  }

  Future<void> _checkOnlineStatus() async {
    if (_peerUserId == null || !mounted) return;

    try {
      final profile = await _dataService.getUserOnlineStatus(_peerUserId!);
      if (mounted && profile != null) {
        setState(() {
          _isOtherUserOnline = profile.isOnline;
          _otherUserLastSeen = profile.lastSeen;
        });
      }
    } catch (e) {
      print('Error checking online status: $e');
    }
  }

  Future<void> _updateLastSeen() async {
    await _dataService.updateLastSeen();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _messagesChannel?.unsubscribe();
    _reactionsChannel?.unsubscribe();
    _pollingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
    });

    // If no conversation ID, try to get or create one
    if (_conversationId == null && _peerUserId != null) {
      final conv = await _dataService.getOrCreateConversation(_peerUserId!);
      if (conv != null) {
        _conversationId = conv.id;
      }
    }

    if (_conversationId != null && _peerUserId == null) {
      final peerId = await _dataService.getOtherParticipantUserId(
        _conversationId!,
      );
      if (mounted && peerId != null) {
        setState(() {
          _peerUserId = peerId;
        });
      }
    }

    if (_conversationId != null) {
      final messages = await _dataService.getMessages(_conversationId!);

      // Decrypt messages
      if (_encryptionReady && _peerUserId != null) {
        final decryptedMessages = <Message>[];
        for (final msg in messages) {
          try {
            if (_encryptionReady &&
                _peerUserId != null &&
                EncryptionService.isEncryptedPayload(msg.content)) {
              final currentUserId =
                  SupabaseService().client.auth.currentUser?.id;
              final isMe = msg.senderId == currentUserId;
              final peerId = isMe ? _peerUserId! : msg.senderId;

              final decrypted = await _encryptionService.tryDecrypt(
                msg.content,
                peerId,
                isOutgoing: isMe,
              );
              decryptedMessages.add(
                Message(
                  id: msg.id,
                  senderId: msg.senderId,
                  content: decrypted ?? '[Encrypted message - unable to decrypt]',
                  isRead: msg.isRead,
                  createdAt: msg.createdAt,
                  deliveredAt: msg.deliveredAt,
                  seenAt: msg.seenAt,
                  mediaUrl: msg.mediaUrl,
                  mediaType: msg.mediaType,
                  replyToId: msg.replyToId,
                  deletedForEveryone: msg.deletedForEveryone,
                  sharedLatitude: msg.sharedLatitude,
                  sharedLongitude: msg.sharedLongitude,
                ),
              );
            } else {
              decryptedMessages.add(msg);
            }
          } catch (e) {
            decryptedMessages.add(msg);
          }
        }

        setState(() {
          _messages = decryptedMessages;
          _isLoading = false;
        });
      } else {
        setState(() {
          _messages = messages;
          _isLoading = false;
        });
      }
      await _loadReactions();
      _scrollToBottom();
      // Mark messages as delivered and seen when opening chat
      if (_conversationId != null) {
        await _dataService.markMessagesAsDelivered(_conversationId!);
        await _dataService.markMessagesAsSeen(_conversationId!);
      }
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadReactions() async {
    if (!mounted || _messages.isEmpty) return;
    final ids = _messages.map((m) => m.id).toList();
    final reactions = await _reactionService.getReactionsForMessages(ids);
    if (!mounted) return;
    setState(() => _messageReactions = reactions);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _conversationId == null) return;

    setState(() {
      _isSending = true;
    });

    _messageController.clear();
    final replyTo = _replyingToMessage;
    setState(() => _replyingToMessage = null);

    try {
      String messageContent = content;

      // Encrypt message if encryption is ready
      if (_encryptionReady && _peerUserId != null) {
        try {
          messageContent = await _encryptionService.encrypt(
            content,
            _peerUserId!,
          );
        } catch (e) {
          print('Could not encrypt message, sending unencrypted: $e');
        }
      }

      final message = await _dataService.sendMessage(
        conversationId: _conversationId!,
        content: messageContent,
        targetUserId: _peerUserId, // For push notification
        replyToId: replyTo?.id,
      );

      if (message != null) {
        _locallyAddedMessageIds.add(message.id);

        // Prevent duplicate if realtime event arrived faster than HTTP response
        if (!_messages.any((m) => m.id == message.id)) {
          setState(() {
            if (!_messages.any((m) => m.id == message.id)) {
              _messages.add(
              Message(
                id: message.id,
                senderId: message.senderId,
                content: content,
                isRead: message.isRead,
                createdAt: message.createdAt,
                deliveredAt: message.deliveredAt,
                seenAt: message.seenAt,
                replyToId: replyTo?.id,
              ),
            );
            }
            _isSending = false;
          });
          _scrollToBottom();
        } else {
          setState(() {
            _isSending = false;
          });
        }
      } else {
        setState(() {
          _isSending = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to send message'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      print('Error sending message: $e');
      setState(() {
        _isSending = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _sendImageMessage() async {
    if (_conversationId == null || _isSendingMedia) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;

    setState(() => _isSendingMedia = true);
    try {
      final url = await StorageService().uploadChatMedia(picked);
      await _dataService.sendMessage(
        conversationId: _conversationId!,
        content: '',
        mediaUrl: url,
        mediaType: 'image',
        targetUserId: _peerUserId,
      );
      // Real-time subscription will append the message automatically;
      // nothing extra needed here.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send image: \$e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSendingMedia = false);
    }
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour;
    final ampm = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '${hour == 0 ? 12 : hour}:${dateTime.minute.toString().padLeft(2, '0')} $ampm';
  }

  String _formatDate(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    if (messageDate == today) {
      return 'TODAY';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      return 'YESTERDAY';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }

  Message? _findMessage(String? messageId) {
    if (messageId == null) return null;
    for (final message in _messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  String _messagePreview(Message message) {
    if (message.deletedForEveryone) return 'Deleted message';
    if (message.mediaType == 'image') return 'Photo';
    final text = message.content.trim();
    if (text.isEmpty) return 'Message';
    return text.length > 80 ? '${text.substring(0, 80)}...' : text;
  }

  Future<void> _showMessageActions(Message message, bool isMe) async {
    if (message.deletedForEveryone) return;
    final c = ColonyColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final emoji in _quickReactions)
                    IconButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _reactionService.toggleReaction(
                          messageId: message.id,
                          emoji: emoji,
                        );
                        await _loadReactions();
                      },
                      icon: Text(emoji, style: const TextStyle(fontSize: 24)),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.reply_rounded, color: c.accent),
              title: Text('Reply', style: TextStyle(color: c.primaryText)),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyingToMessage = message);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: c.accent),
              title: Text(
                'Delete for me',
                style: TextStyle(color: c.primaryText),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await _dataService.deleteMessageForMe(message.id);
                if (!mounted) return;
                if (ok) {
                  setState(() {
                    _messages.removeWhere((m) => m.id == message.id);
                  });
                }
              },
            ),
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text(
                  'Delete for everyone',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await _dataService.deleteMessageForEveryone(
                    message.id,
                  );
                  if (!mounted) return;
                  if (ok) {
                    setState(() {
                      final index = _messages.indexWhere(
                        (m) => m.id == message.id,
                      );
                      if (index != -1) {
                        final current = _messages[index];
                        _messages[index] = Message(
                          id: current.id,
                          content: '',
                          isRead: current.isRead,
                          createdAt: current.createdAt,
                          senderId: current.senderId,
                          deliveredAt: current.deliveredAt,
                          seenAt: current.seenAt,
                          replyToId: current.replyToId,
                          deletedForEveryone: true,
                        );
                      }
                    });
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  static const List<String> _quickReactions = [
    '\u2764\uFE0F',
    '\uD83D\uDC4D',
    '\uD83D\uDE02',
    '\uD83D\uDE2E',
    '\uD83D\uDE22',
    '\uD83D\uDD25',
  ];

  static const List<String> _quickStickers = [
    '\uD83D\uDE04',
    '\uD83D\uDE0D',
    '\uD83E\uDD73',
    '\uD83D\uDE4F',
    '\uD83D\uDC4F',
    '\uD83D\uDD25',
    '\uD83C\uDF89',
    '\u2728',
  ];

  Future<void> _showStickerPicker() async {
    final c = ColonyColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              for (final sticker in _quickStickers)
                InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    _messageController.text = sticker;
                    _sendMessage();
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.scaffold,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(sticker, style: const TextStyle(fontSize: 30)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(72),
        child: _buildAppBar(),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF2E6B3B)),
                  )
                : _messages.isEmpty
                ? _buildEmptyState()
                : _buildMessagesList(),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    final c = ColonyColors.of(context);
    final username = _otherUserProfile?.username;

    // Format last seen time
    String lastSeenText = '';
    if (!_isOtherUserOnline && _otherUserLastSeen != null) {
      final now = DateTime.now();
      final diff = now.difference(_otherUserLastSeen!);
      if (diff.inMinutes < 1) {
        lastSeenText = 'last seen just now';
      } else if (diff.inMinutes < 60) {
        lastSeenText = 'last seen ${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        lastSeenText = 'last seen ${diff.inHours}h ago';
      } else {
        lastSeenText = 'last seen ${diff.inDays}d ago';
      }
    }

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFF1E5631)),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _peerUserId != null ? _openPeerProfile : null,
                  borderRadius: BorderRadius.circular(28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4,
                      horizontal: 2,
                    ),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            CircleAvatar(
                              radius: 20,
                              backgroundImage: _peerAvatarUrl != null
                                  ? NetworkImage(_peerAvatarUrl!)
                                  : const NetworkImage(
                                      'https://i.pravatar.cc/150',
                                    ),
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: _isOtherUserOnline
                                      ? const Color(0xFF25D366)
                                      : Colors.grey.shade400,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: c.scaffold,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _peerDisplayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF2C3E30),
                                ),
                              ),
                              if (username != null &&
                                  username.trim().isNotEmpty &&
                                  username.trim().toLowerCase() !=
                                      _peerDisplayName
                                          .trim()
                                          .toLowerCase()) ...[
                                Text(
                                  '@$username',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  if (_isOtherUserOnline) ...[
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF25D366),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'online',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ] else if (lastSeenText.isNotEmpty) ...[
                                    Expanded(
                                      child: Text(
                                        lastSeenText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Icon(
                                    Icons.lock,
                                    size: 10,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'E2E',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.phone, color: Color(0xFF2C3E30)),
              onPressed: _peerUserId != null
                  ? () => _startCall(isVideo: false)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.videocam, color: Color(0xFF2C3E30)),
              onPressed: _peerUserId != null
                  ? () => _startCall(isVideo: true)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: Color(0xFF2C3E30)),
              onPressed: _peerUserId != null ? _showChatOptions : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock, size: 48, color: Color(0xFF1E5631)),
          const SizedBox(height: 16),
          const Text(
            'End-to-end encrypted',
            style: TextStyle(
              fontSize: 18,
              color: Color(0xFF1E5631),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Messages to $_peerDisplayName are end-to-end encrypted.',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Say hello to $_peerDisplayName! 👋',
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagesList() {
    final currentUserId = SupabaseService().client.auth.currentUser?.id;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isMe = message.senderId == currentUserId;

        // Show date chip if date changed
        final showDateChip =
            index == 0 ||
            !_isSameDay(_messages[index - 1].createdAt, message.createdAt);

        return Column(
          children: [
            if (showDateChip) ...[
              _buildDateChip(_formatDate(message.createdAt)),
              const SizedBox(height: 20),
            ],
            if (isMe)
              _buildOutgoingMsg(message)
            else
              _buildIncomingMsg(message, _peerAvatarUrl),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Widget _buildDateChip(String date) {
    final c = ColonyColors.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          date,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: c.secondaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildIncomingMsg(Message message, String? avatarUrl) {
    final c = ColonyColors.of(context);
    final msg = message.deletedForEveryone
        ? 'This message was deleted'
        : message.content;
    final time = _formatTime(message.createdAt);
    final mediaUrl = message.deletedForEveryone ? null : message.mediaUrl;
    final mediaType = message.deletedForEveryone ? null : message.mediaType;
    final hasImage = mediaType == 'image' && mediaUrl != null;
    final reply = _findMessage(message.replyToId);
    final reactions = _messageReactions[message.id] ?? const {};
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundImage: avatarUrl != null
              ? NetworkImage(avatarUrl)
              : const NetworkImage('https://i.pravatar.cc/150'),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: GestureDetector(
            onLongPress: () => _showMessageActions(message, false),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: hasImage && msg.isEmpty
                      ? const EdgeInsets.all(6)
                      : const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                      bottomLeft: Radius.circular(4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (reply != null) ...[
                        _buildReplyQuote(reply, outgoing: false),
                        const SizedBox(height: 8),
                      ],
                      if (hasImage)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            mediaUrl,
                            width: 220,
                            fit: BoxFit.cover,
                            loadingBuilder: (_, child, progress) =>
                                progress == null
                                ? child
                                : const SizedBox(
                                    width: 220,
                                    height: 160,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.broken_image, size: 48),
                          ),
                        ),
                      if (msg.isNotEmpty) ...[
                        if (hasImage) const SizedBox(height: 6),
                        Text(
                          msg,
                          style: TextStyle(
                            fontSize: 14,
                            color: message.deletedForEveryone
                                ? c.secondaryText
                                : c.primaryText,
                            height: 1.4,
                            fontStyle: message.deletedForEveryone
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade500,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.lock,
                            size: 10,
                            color: Colors.grey.shade500,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (reactions.isNotEmpty)
                  _buildReactionChips(reactions, outgoing: false),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReplyQuote(Message reply, {required bool outgoing}) {
    final c = ColonyColors.of(context);
    final bg = outgoing
        ? Colors.white.withOpacity(0.14)
        : c.scaffold.withOpacity(0.55);
    final textColor = outgoing ? Colors.white : c.primaryText;
    final labelColor = outgoing ? Colors.white70 : c.accent;

    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: outgoing ? Colors.white70 : c.accent,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reply.senderId == SupabaseService().client.auth.currentUser?.id
                ? 'You'
                : _peerDisplayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: labelColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _messagePreview(reply),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: textColor),
          ),
        ],
      ),
    );
  }

  Widget _buildReactionChips(
    Map<String, ReactionInfo> reactions, {
    required bool outgoing,
  }) {
    final c = ColonyColors.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: 4,
        left: outgoing ? 0 : 4,
        right: outgoing ? 4 : 0,
      ),
      child: Wrap(
        spacing: 4,
        children: reactions.values.map((reaction) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.divider.withOpacity(0.45)),
            ),
            child: Text(
              '${reaction.emoji} ${reaction.count}',
              style: TextStyle(fontSize: 12, color: c.primaryText),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildOutgoingMsg(Message message) {
    final msg = message.deletedForEveryone
        ? 'This message was deleted'
        : message.content;
    final time = _formatTime(message.createdAt);
    final status = message.status;
    final mediaUrl = message.deletedForEveryone ? null : message.mediaUrl;
    final mediaType = message.deletedForEveryone ? null : message.mediaType;
    final hasImage = mediaType == 'image' && mediaUrl != null;
    final reply = _findMessage(message.replyToId);
    final reactions = _messageReactions[message.id] ?? const {};
    IconData tickIcon;
    Color tickColor;

    switch (status) {
      case MessageStatus.seen:
        tickIcon = Icons.done_all;
        tickColor = Colors.lightBlueAccent; // Blue ticks for seen
        break;
      case MessageStatus.delivered:
        tickIcon = Icons.done_all;
        tickColor = Colors.white.withOpacity(
          0.7,
        ); // Grey double tick for delivered
        break;
      case MessageStatus.sent:
        tickIcon = Icons.done; // Single tick for sent (not yet delivered)
        tickColor = Colors.white.withOpacity(0.7);
        break;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: GestureDetector(
            onLongPress: () => _showMessageActions(message, true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: hasImage && msg.isEmpty
                      ? const EdgeInsets.all(6)
                      : const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E5631),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (reply != null) ...[
                        _buildReplyQuote(reply, outgoing: true),
                        const SizedBox(height: 8),
                      ],
                      if (hasImage)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            mediaUrl,
                            width: 220,
                            fit: BoxFit.cover,
                            loadingBuilder: (_, child, progress) =>
                                progress == null
                                ? child
                                : const SizedBox(
                                    width: 220,
                                    height: 160,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.broken_image,
                              size: 48,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      if (msg.isNotEmpty) ...[
                        if (hasImage) const SizedBox(height: 6),
                        Text(
                          msg,
                          style: TextStyle(
                            fontSize: 14,
                            color: message.deletedForEveryone
                                ? Colors.white70
                                : Colors.white,
                            height: 1.4,
                            fontStyle: message.deletedForEveryone
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white.withOpacity(0.7),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(tickIcon, size: 14, color: tickColor),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.lock,
                            size: 10,
                            color: Colors.white.withOpacity(0.7),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (reactions.isNotEmpty)
                  _buildReactionChips(reactions, outgoing: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageInput() {
    final c = ColonyColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final barBg = dark ? c.card : Colors.white;
    final fieldBg = dark ? const Color(0xFF1E1E1E) : const Color(0xFFF2F7ED);
    final iconAccent = dark ? Colors.white : const Color(0xFF1E5631);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        decoration: BoxDecoration(
          color: barBg,
          boxShadow: [
            BoxShadow(
              color: dark ? Colors.black54 : const Color(0x0A000000),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingToMessage != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: fieldBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border(left: BorderSide(color: c.accent, width: 3)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Replying',
                            style: TextStyle(
                              fontSize: 11,
                              color: c.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _messagePreview(_replyingToMessage!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _replyingToMessage = null;
                      }),
                      icon: Icon(Icons.close, color: c.secondaryText),
                    ),
                  ],
                ),
              ),
            ],
            Row(
              children: [
                GestureDetector(
                  onTap: _isSendingMedia ? null : _sendImageMessage,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: fieldBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _isSendingMedia
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: iconAccent,
                            ),
                          )
                        : Icon(
                            Icons.image_outlined,
                            color: iconAccent,
                            size: 24,
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _showStickerPicker,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: fieldBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.emoji_emotions_outlined,
                      color: iconAccent,
                      size: 24,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: fieldBg,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.transparent),
                    ),
                    child: TextField(
                      controller: _messageController,
                      maxLines: null,
                      style: TextStyle(color: c.primaryText),
                      cursorColor: c.primaryText,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        hintStyle: TextStyle(color: c.secondaryText),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _isSending ? null : _sendMessage,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E5631),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: _isSending
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.send, color: Colors.white, size: 24),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
