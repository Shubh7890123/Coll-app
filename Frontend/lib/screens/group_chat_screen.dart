import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../colony_theme.dart';
import '../data_service.dart';
import '../supabase_service.dart';

/// Group chat (uses `group_messages` in Supabase).
class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String? coverImageUrl;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    this.coverImageUrl,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final DataService _dataService = DataService();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<GroupMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  String? _myUsername;
  final Set<String> _seenMentionMessageIds = {};
  final Map<String, GlobalKey> _messageKeys = {};
  RealtimeChannel? _messagesChannel;

  @override
  void initState() {
    super.initState();
    _loadCurrentUserProfile();
    _load();
    _setupRealtimeSubscription();
  }

  @override
  void dispose() {
    _messagesChannel?.unsubscribe();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupRealtimeSubscription() {
    _messagesChannel?.unsubscribe();
    _messagesChannel = Supabase.instance.client
        .channel('group_chat_${widget.groupId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'group_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: widget.groupId,
          ),
          callback: (payload) => _onNewRealtimeMessage(payload),
        )
        .subscribe();
  }

  void _onNewRealtimeMessage(PostgresChangePayload payload) {
    if (!mounted) return;
    final newRow = payload.newRecord;
    if (newRow.isEmpty) return;
    final msgId = newRow['id']?.toString();
    if (msgId == null) return;
    // Avoid duplicates
    if (_messages.any((m) => m.id == msgId)) return;

    final newMsg = GroupMessage.fromJson(newRow);
    setState(() {
      _messages = [..._messages, newMsg];
    });
    if (!_isMentionForMe(newMsg)) {
      _scrollToEnd();
    }
  }

  Future<void> _loadCurrentUserProfile() async {
    final userId = SupabaseService().client.auth.currentUser?.id;
    if (userId == null) return;
    final profile = await _dataService.getUserProfile(userId);
    if (!mounted) return;
    setState(() {
      _myUsername = profile?.username?.trim().toLowerCase();
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataService.getGroupMessages(widget.groupId);
    if (!mounted) return;
    setState(() {
      _messages = list;
      _loading = false;
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  bool _isMentionForMe(GroupMessage message) {
    final username = _myUsername;
    if (username == null || username.isEmpty) return false;
    final currentUserId = SupabaseService().client.auth.currentUser?.id;
    if (message.senderId == currentUserId) return false;
    final escapedUsername = RegExp.escape(username);
    return RegExp(
      '(^|\\s)@$escapedUsername\\b',
    ).hasMatch(message.content.toLowerCase());
  }

  List<GroupMessage> get _unseenMentionMessages => _messages
      .where(
        (m) => _isMentionForMe(m) && !_seenMentionMessageIds.contains(m.id),
      )
      .toList();

  void _jumpToNextMention() {
    final mentions = _unseenMentionMessages;
    if (mentions.isEmpty) return;
    final message = mentions.first;
    final key = _messageKeys[message.id];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.28,
      );
    }
    setState(() => _seenMentionMessageIds.add(message.id));
  }

  String _formatTime(DateTime t) {
    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
    final am = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $am';
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _textController.clear();

    final msg = await _dataService.sendGroupMessage(
      groupId: widget.groupId,
      content: text,
      groupName: widget.groupName,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (msg != null) {
      setState(() => _messages = [..._messages, msg]);
      _scrollToEnd();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not send message'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

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
                    _textController.text = sticker;
                    _send();
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
    final myId = SupabaseService().client.auth.currentUser?.id;
    final c = ColonyColors.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: c.accent),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: widget.coverImageUrl != null
                  ? NetworkImage(widget.coverImageUrl!)
                  : null,
              child: widget.coverImageUrl == null
                  ? Icon(Icons.group, color: c.accent, size: 22)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.groupName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: c.primaryText,
                    ),
                  ),
                  Text(
                    'Group chat',
                    style: TextStyle(fontSize: 11, color: c.secondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _loading
                    ? Center(
                        child: CircularProgressIndicator(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : const Color(0xFF2E6B3B),
                        ),
                      )
                    : _messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'No messages yet.\nSay hi to the group!',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: c.secondaryText,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) {
                          final m = _messages[i];
                          _messageKeys.putIfAbsent(m.id, GlobalKey.new);
                          final isMe = m.senderId == myId;
                          return Padding(
                            key: _messageKeys[m.id],
                            padding: const EdgeInsets.only(bottom: 12),
                            child: isMe
                                ? _bubbleOutgoing(
                                    m.content,
                                    _formatTime(m.createdAt),
                                  )
                                : _bubbleIncoming(m),
                          );
                        },
                      ),
                if (_unseenMentionMessages.isNotEmpty)
                  Positioned(
                    right: 16,
                    bottom: 18,
                    child: _buildMentionJumpButton(c),
                  ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: MediaQuery.of(context).padding.bottom + 8,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? c.card
                  : Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF1E1E1E)
                        : const Color(0xFFF2F7ED),
                    foregroundColor: c.accent,
                  ),
                  onPressed: _showStickerPicker,
                  icon: const Icon(Icons.emoji_emotions_outlined),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    minLines: 1,
                    maxLines: 4,
                    style: TextStyle(color: c.primaryText),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Message',
                      hintStyle: TextStyle(color: c.secondaryText),
                      filled: true,
                      fillColor: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF1E1E1E)
                          : const Color(0xFFF2F7ED),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF1E5631),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubbleIncoming(GroupMessage m) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundImage: m.senderAvatarUrl != null
              ? NetworkImage(m.senderAvatarUrl!)
              : null,
          child: m.senderAvatarUrl == null
              ? Text(
                  m.senderLabel.isNotEmpty
                      ? m.senderLabel[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E5631),
                  ),
                )
              : null,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.senderLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1E5631),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  m.content,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF2C3E30),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(m.createdAt),
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMentionJumpButton(ColonyColors c) {
    final count = _unseenMentionMessages.length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _jumpToNextMention,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: c.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              const Text(
                '@',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Positioned(
                right: -2,
                top: -3,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 18,
                    minHeight: 18,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bubbleOutgoing(String text, String time) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: Color(0xFF1E5631),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
