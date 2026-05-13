import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import '../socket_service.dart';
import '../supabase_service.dart';
import 'chat_detail_screen.dart';
import 'notifications_screen.dart';
import 'user_profile_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final DataService _dataService = DataService();

  List<Conversation> _conversations = [];
  List<Wave> _pendingWaves = [];
  bool _isLoading = true;
  bool _isLoadingWaves = false;
  String _searchQuery = '';
  RealtimeChannel? _chatListChannel;
  Timer? _refreshDebounce;
  StreamSubscription<SocketEvent>? _socketSubscription;
  Map<String, UserProfile> _onlineProfiles = {};

  @override
  void initState() {
    super.initState();
    _loadConversations();
    _loadPendingWaves();
    _subscribeToChatListRealtime();
    _subscribeToSocketUpdates();
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _socketSubscription?.cancel();
    _chatListChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _subscribeToSocketUpdates() async {
    await SocketService().connect();
    _socketSubscription?.cancel();
    _socketSubscription = SocketService().events.listen((event) {
      if (!mounted) return;
      if (event.name == 'chat_list_updated' ||
          event.name == 'message' ||
          event.name == 'message_sent') {
        _scheduleChatListRefresh();
      }
    });
  }

  void _subscribeToChatListRealtime() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    _chatListChannel?.unsubscribe();
    _chatListChannel = Supabase.instance.client.channel('chat_list_$userId');

    void onDbChange(_) {
      _scheduleChatListRefresh();
    }

    _chatListChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversations',
          callback: onDbChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          callback: onDbChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'waves',
          callback: onDbChange,
        )
        .subscribe();
  }

  void _scheduleChatListRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      await Future.wait([
        _loadConversations(showSpinner: false),
        _loadPendingWaves(showSpinner: false),
      ]);
    });
  }

  Future<void> _loadConversations({bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() {
        _isLoading = true;
      });
    }

    final conversations = await _dataService.getConversations();

    final profileFutures = <Future<void>>[];
    final profiles = <String, UserProfile>{};
    for (final conv in conversations) {
      final otherId = conv.otherUser?.id;
      if (otherId != null && !_onlineProfiles.containsKey(otherId)) {
        profileFutures.add(
          _dataService.getUserProfile(otherId).then((p) {
            if (p != null) profiles[otherId] = p;
          }).catchError((e) {
            print('Error loading profile for $otherId: $e');
          }),
        );
      }
    }
    try {
      await Future.wait(profileFutures).timeout(const Duration(seconds: 5));
    } catch (e) {
      print('Timeout or error waiting for profiles: $e');
    }

    if (!mounted) return;
    setState(() {
      _conversations = conversations;
      _onlineProfiles.addAll(profiles);
      if (showSpinner) _isLoading = false;
    });
  }

  Future<void> _loadPendingWaves({bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() {
        _isLoadingWaves = true;
      });
    }

    final waves = await _dataService.getPendingWaves();

    if (!mounted) return;
    setState(() {
      _pendingWaves = waves;
      if (showSpinner) _isLoadingWaves = false;
    });
  }

  Future<void> _openNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const NotificationsScreen()),
    );
    if (!mounted) return;
    await Future.wait([
      _loadPendingWaves(showSpinner: false),
      _loadConversations(showSpinner: false),
    ]);
  }

  List<Conversation> get _filteredConversations {
    if (_searchQuery.isEmpty) return _conversations;
    return _conversations.where((conv) {
      final name =
          conv.otherUser?.displayName ?? conv.otherUser?.username ?? 'Unknown';
      return name.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      final hour = dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour;
      final ampm = dateTime.hour >= 12 ? 'PM' : 'AM';
      return '${hour == 0 ? 12 : hour}:${dateTime.minute.toString().padLeft(2, '0')} $ampm';
    } else if (difference.inDays == 1) {
      return 'YESTERDAY';
    } else if (difference.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[dateTime.weekday - 1].toUpperCase();
    } else {
      return '${dateTime.day}/${dateTime.month}';
    }
  }

  void _navigateToChat(Conversation conversation) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conversation.id,
          otherUserId: conversation.otherUser?.id,
          otherUserName:
              conversation.otherUser?.displayName ??
              conversation.otherUser?.username ??
              'User',
          otherUserAvatar: conversation.otherUser?.avatarUrl,
        ),
      ),
    ).then((_) => _loadConversations());
  }

  void _navigateToUserProfile(String userId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserProfileScreen(userId: userId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.wait([
              _loadConversations(showSpinner: false),
              _loadPendingWaves(showSpinner: false),
            ]);
          },
          color: c.accent,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _buildHeader(c),
              const SizedBox(height: 20),
              _buildSearchBar(c),
              const SizedBox(height: 12),
              if (_isLoading)
                SizedBox(
                  height: 240,
                  child: Center(
                    child: CircularProgressIndicator(color: c.accent),
                  ),
                )
              else ...[
                _buildPendingWavesSection(c),
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.56,
                  child: _buildConversationsList(c),
                ),
              ],
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewMessageSheet,
        backgroundColor: c.fabBackground,
        elevation: 2,
        child: Icon(Icons.edit_square, color: c.fabForeground, size: 28),
      ),
    );
  }

  void _showNewMessageSheet() {
    final c = ColonyColors.of(context);
    final searchController = TextEditingController();
    List<Map<String, dynamic>> results = [];
    bool isSearching = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> search(String query) async {
              if (query.trim().isEmpty) {
                setSheetState(() => results = []);
                return;
              }
              setSheetState(() => isSearching = true);
              try {
                final client = SupabaseService().client;
                final currentUserId = client.auth.currentUser?.id;
                final response = await client
                    .from('profiles')
                    .select('id, username, display_name, avatar_url')
                    .or(
                      'username.ilike.%${query.trim()}%,display_name.ilike.%${query.trim()}%',
                    )
                    .neq('id', currentUserId ?? '')
                    .limit(20);
                setSheetState(() {
                  results = List<Map<String, dynamic>>.from(response as List);
                  isSearching = false;
                });
              } catch (e) {
                setSheetState(() => isSearching = false);
              }
            }

            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              minChildSize: 0.5,
              builder: (_, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: c.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          'New Message',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: c.primaryText,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          decoration: BoxDecoration(
                            color: c.searchBarFill,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: c.divider.withOpacity(0.4),
                            ),
                          ),
                          child: TextField(
                            controller: searchController,
                            autofocus: true,
                            style: TextStyle(
                              color: c.primaryText,
                              fontSize: 14,
                            ),
                            onChanged: (v) => search(v),
                            decoration: InputDecoration(
                              hintText: 'Search by name or username...',
                              hintStyle: TextStyle(
                                color: c.secondaryText,
                                fontSize: 14,
                              ),
                              prefixIcon: Icon(
                                Icons.search,
                                color: c.iconMuted,
                              ),
                              suffixIcon: isSearching
                                  ? Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: c.accent,
                                        ),
                                      ),
                                    )
                                  : null,
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: results.isEmpty
                            ? Center(
                                child: Text(
                                  searchController.text.isEmpty
                                      ? 'Search for someone to message'
                                      : 'No users found',
                                  style: TextStyle(
                                    color: c.secondaryText,
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 4,
                                ),
                                itemCount: results.length,
                                itemBuilder: (context, index) {
                                  final user = results[index];
                                  final name =
                                      user['display_name'] ??
                                      user['username'] ??
                                      'User';
                                  final username = user['username'];
                                  final avatar = user['avatar_url'];
                                  return ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    leading: CircleAvatar(
                                      radius: 22,
                                      backgroundImage: avatar != null
                                          ? NetworkImage(avatar)
                                          : const NetworkImage(
                                              'https://i.pravatar.cc/150',
                                            ),
                                    ),
                                    title: Text(
                                      name,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: c.primaryText,
                                      ),
                                    ),
                                    subtitle: username != null
                                        ? Text(
                                            '@$username',
                                            style: TextStyle(
                                              color: c.secondaryText,
                                              fontSize: 12,
                                            ),
                                          )
                                        : null,
                                    onTap: () async {
                                      Navigator.pop(sheetContext);
                                      final conv = await _dataService
                                          .getOrCreateConversation(user['id']);
                                      if (!mounted) return;
                                      if (conv == null) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Accept each other\'s friend request first to chat',
                                            ),
                                            backgroundColor: Colors.orange,
                                          ),
                                        );
                                        return;
                                      }
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => ChatDetailScreen(
                                            conversationId: conv.id,
                                            otherUserId: user['id'],
                                            otherUserName: name,
                                            otherUserAvatar: avatar,
                                          ),
                                        ),
                                      ).then((_) => _loadConversations());
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPendingWavesSection(ColonyColors c) {
    if (_isLoadingWaves) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: LinearProgressIndicator(color: c.accent),
      );
    }

    if (_pendingWaves.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: c.divider.withOpacity(c.isDark ? 0.45 : 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pending waves',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: c.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            ..._pendingWaves.map((wave) {
              final sender = wave.sender;
              final senderName =
                  sender?.displayName ?? sender?.username ?? 'User';

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundImage: sender?.avatarUrl != null
                          ? NetworkImage(sender!.avatarUrl!)
                          : const NetworkImage('https://i.pravatar.cc/150'),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        senderName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: c.primaryText,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Accept',
                          onPressed: () async {
                            final ok = await _dataService.respondToWave(
                              wave.id,
                              'accepted',
                            );
                            if (!mounted) return;
                            if (ok) {
                              await _loadPendingWaves();
                              await _loadConversations();
                            }
                          },
                          icon: Icon(Icons.check, color: c.accent),
                        ),
                        IconButton(
                          tooltip: 'Reject',
                          onPressed: () async {
                            final ok = await _dataService.respondToWave(
                              wave.id,
                              'rejected',
                            );
                            if (!mounted) return;
                            if (ok) {
                              await _loadPendingWaves();
                              await _loadConversations();
                            }
                          },
                          icon: const Icon(
                            Icons.close,
                            color: Color(0xFFB00020),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Friends',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: c.primaryText,
            ),
          ),
          IconButton(
            icon: Icon(Icons.search, color: c.primaryText, size: 26),
            onPressed: _showNewMessageSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        decoration: BoxDecoration(
          color: c.searchBarFill,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: c.divider.withOpacity(c.isDark ? 0.5 : 0.2),
          ),
        ),
        child: TextField(
          style: TextStyle(color: c.primaryText, fontSize: 14),
          onChanged: (value) {
            setState(() {
              _searchQuery = value;
            });
          },
          decoration: InputDecoration(
            hintText: 'Search conversations...',
            hintStyle: TextStyle(color: c.secondaryText, fontSize: 14),
            prefixIcon: Icon(Icons.search, color: c.iconMuted),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 15,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversationsList(ColonyColors c) {
    final conversations = _filteredConversations;

    if (conversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: c.iconMuted),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty
                  ? 'No conversations yet'
                  : 'No conversations found',
              style: TextStyle(
                fontSize: 18,
                color: c.secondaryText,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            if (_searchQuery.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Wave at nearby people to start chatting!',
                  style: TextStyle(fontSize: 14, color: c.secondaryText),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadConversations,
      color: c.accent,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        itemCount: conversations.length,
        itemBuilder: (context, index) {
          final conversation = conversations[index];
          return _buildConversationTile(c, conversation);
        },
      ),
    );
  }

  Widget _buildConversationTile(ColonyColors c, Conversation conversation) {
    final otherUser = conversation.otherUser;
    final lastMessage = conversation.lastMessage;
    final displayName =
        otherUser?.displayName ?? otherUser?.username ?? 'Unknown User';
    final avatarUrl = otherUser?.avatarUrl;
    final time = conversation.lastMessageAt != null
        ? _formatTime(conversation.lastMessageAt!)
        : '';

    final profile = otherUser != null ? _onlineProfiles[otherUser.id] : null;
    final isOnline = profile?.isOnline ?? false;

    return GestureDetector(
      onTap: () => _navigateToChat(conversation),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: conversation.unreadCount > 0
              ? c.unreadRowTint
              : Colors.transparent,
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: () {
                if (otherUser != null) {
                  _navigateToUserProfile(otherUser.id);
                }
              },
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundImage: avatarUrl != null
                        ? NetworkImage(avatarUrl)
                        : const NetworkImage('https://i.pravatar.cc/150'),
                  ),
                  if (otherUser != null)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: isOnline
                              ? const Color(0xFF4CAF50)
                              : Colors.grey.shade400,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: conversation.unreadCount > 0
                                ? c.unreadRowTint
                                : c.scaffold,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: c.primaryText,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: 11,
                          color: c.secondaryText,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          lastMessage?.content ?? 'Start a conversation',
                          style: TextStyle(
                            fontSize: 14,
                            color: c.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (conversation.unreadCount > 0)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: c.unreadBadgeBg,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            conversation.unreadCount > 9
                                ? '9+'
                                : conversation.unreadCount.toString(),
                            style: TextStyle(
                              color: c.unreadBadgeFg,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
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
    );
  }
}
