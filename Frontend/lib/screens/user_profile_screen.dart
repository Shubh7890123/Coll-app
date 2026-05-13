import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import 'chat_detail_screen.dart';

class UserProfileScreen extends StatefulWidget {
  final String userId;
  const UserProfileScreen({super.key, required this.userId});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final DataService _dataService = DataService();

  UserProfile? _userProfile;
  bool _isLoading = true;
  bool _isActing = false;
  String? _friendStatus;
  int _friendsCount = 0;
  int _groupsCount = 0;
  bool _isBlocked = false;
  List<MutualFriend> _mutualFriends = [];
  RealtimeChannel? _waveChannel;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _setupWaveListener();
  }

  @override
  void dispose() {
    _waveChannel?.unsubscribe();
    super.dispose();
  }

  void _setupWaveListener() {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    _waveChannel = Supabase.instance.client
        .channel('profile-wave-${widget.userId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'waves',
          callback: (payload) {
            final senderId = payload.newRecord['sender_id'] as String?;
            final receiverId = payload.newRecord['receiver_id'] as String?;
            if (senderId == widget.userId || receiverId == widget.userId) {
              _loadAll();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'waves',
          callback: (payload) {
            final senderId = payload.newRecord['sender_id'] as String?;
            final receiverId = payload.newRecord['receiver_id'] as String?;
            if (senderId == widget.userId || receiverId == widget.userId) {
              _loadAll();
            }
          },
        )
        .subscribe();
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    final results = await Future.wait([
      _dataService.getUserProfile(widget.userId),
      _dataService.getFriendRequestStatus(widget.userId),
      _dataService.getFriendsCount(widget.userId),
      _dataService.getUserGroupsCount(widget.userId),
      _dataService.isUserBlocked(widget.userId),
      _dataService.getMutualFriends(widget.userId),
    ]);

    if (!mounted) return;
    setState(() {
      _userProfile = results[0] as UserProfile?;
      _friendStatus = results[1] as String?;
      _friendsCount = results[2] as int;
      _groupsCount = results[3] as int;
      _isBlocked = results[4] as bool;
      _mutualFriends = results[5] as List<MutualFriend>;
      _isLoading = false;
    });
  }

  bool get _isFriend =>
      _friendStatus == 'accepted' || _friendStatus == 'received_accepted';
  bool get _isRequestSent => _friendStatus == 'pending';
  bool get _hasReceivedRequest => _friendStatus == 'received';

  Future<void> _sendFriendRequest() async {
    setState(() => _isActing = true);
    final success = await _dataService.sendFriendRequest(widget.userId);
    if (!mounted) return;
    if (success) await _loadAll();
    setState(() => _isActing = false);
    _showSnack(
      success ? 'Friend request sent!' : 'Could not send request.',
      success,
    );
  }

  Future<void> _removeFriend() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Friend?'),
        content: Text(
          'Remove ${_userProfile?.displayName ?? 'this user'} from friends?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _isActing = true);
    final success = await _dataService.removeFriend(widget.userId);
    if (!mounted) return;
    if (success) await _loadAll();
    setState(() => _isActing = false);
    _showSnack(
      success ? 'Friend removed.' : 'Could not remove friend.',
      success,
    );
  }

  Future<void> _openChat() async {
    final conv = await _dataService.getOrCreateConversation(widget.userId);
    if (!mounted) return;
    if (conv == null) {
      _showSnack('Unable to open chat right now', false);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conv.id,
          otherUserId: widget.userId,
          otherUserName:
              _userProfile?.displayName ?? _userProfile?.username ?? 'User',
          otherUserAvatar: _userProfile?.avatarUrl,
        ),
      ),
    );
  }

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final c = ColonyColors.of(context);
        return Container(
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(
                    _isBlocked ? Icons.lock_open_rounded : Icons.block,
                    color: Colors.red,
                  ),
                  title: Text(
                    _isBlocked ? 'Unblock User' : 'Block User',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _isBlocked ? _unblockUser() : _blockUser();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.flag_rounded, color: Colors.orange),
                  title: const Text(
                    'Report User',
                    style: TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showReportDialog();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _blockUser() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block User?'),
        content: Text(
          'Block ${_userProfile?.displayName ?? 'this user'}? You won\'t see their content and they won\'t be able to contact you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Block', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _isActing = true);
    final success = await _dataService.blockUser(widget.userId);
    if (!mounted) return;
    if (success) {
      setState(() => _isBlocked = true);
    }
    setState(() => _isActing = false);
    _showSnack(success ? 'User blocked.' : 'Could not block user.', success);
  }

  Future<void> _unblockUser() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unblock User?'),
        content: Text(
          'Unblock ${_userProfile?.displayName ?? 'this user'}? They will be able to see your profile and contact you again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Unblock', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _isActing = true);
    final success = await _dataService.unblockUser(widget.userId);
    if (!mounted) return;
    if (success) {
      setState(() => _isBlocked = false);
    }
    setState(() => _isActing = false);
    _showSnack(
      success ? 'User unblocked.' : 'Could not unblock user.',
      success,
    );
  }

  void _showReportDialog() {
    final controller = TextEditingController();
    String? selectedReason;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Report User'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Why are you reporting this user?',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ...[
                    'Spam',
                    'Harassment',
                    'Fake Profile',
                    'Inappropriate Content',
                    'Other',
                  ].map(
                    (reason) => RadioListTile<String>(
                      title: Text(reason),
                      value: reason,
                      groupValue: selectedReason,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      onChanged: (val) {
                        setDialogState(() => selectedReason = val);
                      },
                    ),
                  ),
                  if (selectedReason == 'Other') ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'Please describe the issue...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selectedReason == null
                      ? null
                      : () async {
                          final reason = selectedReason == 'Other'
                              ? controller.text.trim().isNotEmpty
                                    ? controller.text.trim()
                                    : 'Other'
                              : selectedReason!;
                          Navigator.pop(ctx);
                          await _submitReport(reason);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text(
                    'Submit Report',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submitReport(String reason) async {
    setState(() => _isActing = true);
    final success = await _dataService.reportUser(widget.userId, reason);
    if (!mounted) return;
    setState(() => _isActing = false);
    _showSnack(
      success ? 'Report submitted. Thank you.' : 'Could not submit report.',
      success,
    );
  }

  void _showSnack(String msg, bool ok) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: ok ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: c.scaffold,
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : _userProfile == null
          ? Center(
              child: Text(
                'User not found',
                style: TextStyle(color: c.primaryText),
              ),
            )
          : _buildBody(c, dark),
    );
  }

  Widget _buildBody(ColonyColors c, bool dark) {
    final profile = _userProfile!;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          toolbarHeight: 50,
          backgroundColor: c.scaffold,
          elevation: 0,
          leading: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: c.pillBackground,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.arrow_back, color: c.primaryText, size: 20),
            ),
          ),
          actions: [
            GestureDetector(
              onTap: _showMoreMenu,
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: c.pillBackground,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.more_vert, color: c.primaryText, size: 20),
              ),
            ),
          ],
        ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 110,
                  height: 110,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: dark
                          ? [const Color(0xFF555555), const Color(0xFF999999)]
                          : [const Color(0xFFF17F36), const Color(0xFF2E6B3B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 52,
                    backgroundColor: c.scaffold,
                    backgroundImage: profile.avatarUrl != null
                        ? NetworkImage(profile.avatarUrl!)
                        : const NetworkImage('https://i.pravatar.cc/200'),
                  ),
                ),
                const SizedBox(height: 14),

                Text(
                  profile.displayName ?? profile.username ?? 'User',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: c.primaryText,
                    letterSpacing: -0.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),

                if (profile.username != null)
                  Text(
                    '@${profile.username}',
                    style: TextStyle(
                      fontSize: 14,
                      color: c.secondaryText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                const SizedBox(height: 6),

                if (profile.locationText != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.location_on_rounded,
                        color: c.accent,
                        size: 15,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          profile.locationText!,
                          style: TextStyle(
                            fontSize: 12,
                            color: c.secondaryText,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),

                const SizedBox(height: 18),

                _buildActionButtons(c),

                const SizedBox(height: 22),

                _buildStatsRow(c),

                if (_mutualFriends.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _buildMutualFriendsSection(c, dark),
                ],

                if (profile.bio != null && profile.bio!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: c.divider.withOpacity(c.isDark ? 0.4 : 0.15),
                      ),
                    ),
                    child: Text(
                      profile.bio!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: c.primaryText,
                        height: 1.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons(ColonyColors c) {
    if (_isActing) {
      return const SizedBox(
        height: 44,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_isBlocked) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _unblockUser,
          icon: const Icon(Icons.lock_open_rounded, size: 18),
          label: const Text(
            'Unblock',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            elevation: 0,
          ),
        ),
      );
    }

    if (_isFriend) {
      return Row(
        children: [
          Expanded(
            flex: 3,
            child: ElevatedButton.icon(
              onPressed: _openChat,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              label: const Text(
                'Message',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B5A27),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: OutlinedButton.icon(
              onPressed: _removeFriend,
              icon: const Icon(
                Icons.person_remove_outlined,
                color: Colors.red,
                size: 16,
              ),
              label: const Text(
                'Remove',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: const BorderSide(color: Colors.red, width: 0.8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (_isRequestSent) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.check_circle_outline, size: 18),
          label: const Text(
            'Request Sent',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      );
    }

    if (_hasReceivedRequest) {
      return Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () async {
                setState(() => _isActing = true);
                final success = await _dataService.acceptReceivedWave(
                  widget.userId,
                );
                if (!mounted) return;
                if (success) await _loadAll();
                setState(() => _isActing = false);
                _showSnack(
                  success ? 'Friend request accepted!' : 'Error',
                  success,
                );
              },
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text(
                'Accept',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B5A27),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                setState(() => _isActing = true);
                final success = await _dataService.rejectReceivedWave(
                  widget.userId,
                );
                if (!mounted) return;
                if (success) await _loadAll();
                setState(() => _isActing = false);
                _showSnack(success ? 'Request declined.' : 'Error', success);
              },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: BorderSide(color: c.divider),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                'Decline',
                style: TextStyle(
                  color: c.secondaryText,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _sendFriendRequest,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
        label: const Text(
          'Add Friend',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1877F2),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildStatsRow(ColonyColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.divider.withOpacity(c.isDark ? 0.4 : 0.12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _statItem(
            c,
            '$_friendsCount',
            'Friends',
            Icons.people_outline_rounded,
          ),
          Container(height: 36, width: 1, color: c.divider),
          _statItem(c, '$_groupsCount', 'Groups', Icons.group_outlined),
          Container(height: 36, width: 1, color: c.divider),
          _statItem(c, _isFriend ? '✓' : '–', 'Connected', Icons.link_rounded),
        ],
      ),
    );
  }

  Widget _buildMutualFriendsSection(ColonyColors c, bool dark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.divider.withOpacity(c.isDark ? 0.4 : 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.people_outline_rounded, color: c.accent, size: 18),
              const SizedBox(width: 6),
              Text(
                '${_mutualFriends.length} mutual friend${_mutualFriends.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: c.primaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _mutualFriends.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final mf = _mutualFriends[index];
                return Column(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: c.pillBackground,
                      backgroundImage: mf.avatarUrl != null
                          ? NetworkImage(mf.avatarUrl!)
                          : null,
                      child: mf.avatarUrl == null
                          ? Text(
                              (mf.displayName ?? mf.username ?? '?')
                                  .substring(0, 1)
                                  .toUpperCase(),
                              style: TextStyle(
                                color: c.primaryText,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 56,
                      child: Text(
                        mf.displayName ?? mf.username ?? 'User',
                        style: TextStyle(
                          fontSize: 11,
                          color: c.secondaryText,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statItem(ColonyColors c, String value, String label, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: c.accent, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: c.primaryText,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 11, color: c.secondaryText)),
      ],
    );
  }
}
