import 'package:flutter/material.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import 'chat_detail_screen.dart';
import 'group_chat_screen.dart';
import 'user_profile_screen.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final DataService _dataService = DataService();
  final List<AppNotification> _notifications = [];
  List<Wave> _pendingWaves = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  int _offset = 0;
  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() => _isLoading = true);
    final waves = await _dataService.getPendingWaves();
    final notifications = await _dataService.getNotifications(
      limit: _pageSize,
      offset: 0,
    );

    if (!mounted) return;
    setState(() {
      _pendingWaves = waves;
      _notifications
        ..clear()
        ..addAll(notifications);
      _offset = notifications.length;
      _isLoading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    final notifications = await _dataService.getNotifications(
      limit: _pageSize,
      offset: _offset,
    );
    if (!mounted) return;
    setState(() {
      _notifications.addAll(notifications);
      _offset += notifications.length;
      _isLoadingMore = false;
    });
  }

  Future<void> _acceptWave(Wave wave) async {
    final ok = await _dataService.respondToWave(wave.id, 'accepted');
    if (!mounted || !ok) return;
    await _loadInitial();
  }

  Future<void> _rejectWave(Wave wave) async {
    final ok = await _dataService.respondToWave(wave.id, 'rejected');
    if (!mounted || !ok) return;
    await _loadInitial();
  }

  Future<void> _markAllAsRead() async {
    await _dataService.markAllNotificationsAsRead();
    await _loadInitial();
  }

  Future<void> _clearAll() async {
    await _dataService.clearAllNotifications();
    await _loadInitial();
  }

  Future<void> _openNotification(AppNotification notification) async {
    if (!notification.isRead) {
      await _dataService.markNotificationAsRead(notification.id);
    }

    if (!mounted) return;

    final data = notification.data;
    switch (notification.type) {
      case 'dm_message':
      case 'friend_accept':
        final conversationId =
            data['chatId']?.toString() ??
            data['conversationId']?.toString() ??
            data['conversation_id']?.toString();
        final senderId =
            data['senderId']?.toString() ?? data['sender_id']?.toString();
        if (conversationId != null && senderId != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatDetailScreen(
                conversationId: conversationId,
                otherUserId: senderId,
                otherUserName: notification.title,
                otherUserAvatar: data['sender_avatar']?.toString(),
              ),
            ),
          );
        }
        break;
      case 'group_message':
      case 'group_invite':
      case 'mention':
        final groupId =
            data['groupId']?.toString() ?? data['group_id']?.toString();
        if (groupId != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GroupChatScreen(
                groupId: groupId,
                groupName:
                    data['groupName']?.toString() ??
                    data['group_name']?.toString() ??
                    notification.title,
              ),
            ),
          );
        }
        break;
      default:
        break;
    }

    await _loadInitial();
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: c.accent),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Notifications',
          style: TextStyle(
            color: c.accent,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          if (_notifications.isNotEmpty)
            TextButton(
              onPressed: _markAllAsRead,
              child: const Text('Read all'),
            ),
          if (_notifications.isNotEmpty)
            IconButton(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _isLoading ? _buildLoading(c) : _buildContent(c),
    );
  }

  Widget _buildLoading(ColonyColors c) {
    return Center(
      child: CircularProgressIndicator(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : c.accent,
      ),
    );
  }

  Widget _buildContent(ColonyColors c) {
    if (_pendingWaves.isEmpty && _notifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.notifications_none_outlined,
              size: 72,
              color: c.secondaryText,
            ),
            const SizedBox(height: 16),
            Text(
              'No notifications yet',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: c.primaryText,
              ),
            ),
          ],
        ),
      );
    }

    final unread = _notifications.where((item) => !item.isRead).length;

    return RefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (unread > 0) _buildSummaryCard(c, unread),
          if (_pendingWaves.isNotEmpty) ...[
            _buildSectionTitle('Friend requests', c),
            ..._pendingWaves.map((wave) => _buildWaveCard(wave, c)),
          ],
          if (_notifications.isNotEmpty) ...[
            _buildSectionTitle('Activity', c),
            ..._notifications.map((item) => _buildNotificationTile(item, c)),
            const SizedBox(height: 8),
            if (!_isLoadingMore)
              OutlinedButton(
                onPressed: _loadMore,
                child: const Text('Load more'),
              )
            else
              const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ColonyColors c, int unread) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: c.accent.withValues(alpha: 0.12),
            child: Icon(Icons.notifications_active_outlined, color: c.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$unread unread notifications',
              style: TextStyle(
                color: c.primaryText,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 6),
      child: Text(
        title,
        style: TextStyle(
          color: c.primaryText,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildWaveCard(Wave wave, ColonyColors c) {
    final sender = wave.sender;
    final senderName = sender?.displayName ?? sender?.username ?? 'Unknown User';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserProfileScreen(
                    userId: sender?.id ?? wave.senderId,
                  ),
                ),
              );
            },
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundImage: sender?.avatarUrl != null
                      ? NetworkImage(sender!.avatarUrl!)
                      : null,
                  child: sender?.avatarUrl == null
                      ? const Icon(Icons.person_outline)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        senderName,
                        style: TextStyle(
                          color: c.primaryText,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'sent you a friend request',
                        style: TextStyle(color: c.secondaryText),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _rejectWave(wave),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _acceptWave(wave),
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationTile(AppNotification notification, ColonyColors c) {
    final icon = _iconFor(notification.type);
    return InkWell(
      onTap: () => _openNotification(notification),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: notification.isRead
              ? c.card
              : c.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: notification.isRead
                ? c.divider.withValues(alpha: 0.12)
                : c.accent.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: c.accent.withValues(alpha: 0.12),
              child: Icon(icon, color: c.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          notification.title,
                          style: TextStyle(
                            color: c.primaryText,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (!notification.isRead)
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    notification.body,
                    style: TextStyle(color: c.secondaryText),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatTime(notification.createdAt),
                    style: TextStyle(
                      color: c.secondaryText.withValues(alpha: 0.8),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'dm_message':
        return Icons.chat_bubble_outline;
      case 'group_message':
      case 'mention':
      case 'group_invite':
        return Icons.groups_outlined;
      case 'friend_request':
      case 'friend_accept':
        return Icons.person_add_alt_1_outlined;
      case 'audio_call':
      case 'video_call':
        return Icons.call_outlined;
      default:
        return Icons.notifications_outlined;
    }
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }
}
