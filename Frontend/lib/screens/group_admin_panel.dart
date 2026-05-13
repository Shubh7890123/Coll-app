import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import '../supabase_service.dart';
import 'user_profile_screen.dart';

class GroupAdminPanel extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupAdminPanel({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GroupAdminPanel> createState() => _GroupAdminPanelState();
}

class _GroupAdminPanelState extends State<GroupAdminPanel> {
  final DataService _dataService = DataService();
  List<GroupMember> _members = [];
  bool _isLoading = true;
  String? _currentUserRole;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    setState(() => _isLoading = true);
    final members = await _dataService.getGroupMembers(widget.groupId);

    final userId = SupabaseService().client.auth.currentUser?.id;
    String? role;
    for (final m in members) {
      if (m.user.id == userId) {
        role = m.role;
        break;
      }
    }

    if (mounted) {
      setState(() {
        _members = members;
        _currentUserRole = role;
        _isLoading = false;
      });
    }
  }

  bool get _isAdmin => _currentUserRole == 'admin';

  Future<void> _changeRole(String memberId, String newRole) async {
    try {
      await SupabaseService().client
          .from('group_members')
          .update({'role': newRole})
          .eq('id', memberId);
      _loadMembers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeMember(GroupMember member) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Member?'),
        content: Text(
          'Remove ${member.user.displayName ?? member.user.username ?? 'this member'} from the group?',
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

    try {
      await SupabaseService().client
          .from('group_members')
          .delete()
          .eq('id', member.id);
      _loadMembers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: c.scaffold,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: c.accent),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Manage Members',
          style: TextStyle(color: c.accent, fontWeight: FontWeight.bold),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : _members.isEmpty
          ? Center(
              child: Text(
                'No members found',
                style: TextStyle(color: c.secondaryText),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _members.length,
              itemBuilder: (context, index) {
                final member = _members[index];
                return _buildMemberTile(c, member);
              },
            ),
    );
  }

  Widget _buildMemberTile(ColonyColors c, GroupMember member) {
    final roleColor = member.role == 'admin'
        ? Colors.orange
        : member.role == 'moderator'
        ? Colors.blue
        : c.secondaryText;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.divider.withOpacity(0.15)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 24,
          backgroundImage: member.user.avatarUrl != null
              ? NetworkImage(member.user.avatarUrl!)
              : const NetworkImage('https://i.pravatar.cc/150'),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                member.user.displayName ?? member.user.username ?? 'Member',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: c.primaryText,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: roleColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                member.role.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: roleColor,
                ),
              ),
            ),
          ],
        ),
        subtitle: member.user.username != null
            ? Text(
                '@${member.user.username}',
                style: TextStyle(fontSize: 12, color: c.secondaryText),
              )
            : null,
        trailing: _isAdmin && member.role != 'admin'
            ? PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: c.secondaryText),
                onSelected: (action) {
                  if (action == 'moderator') {
                    _changeRole(member.id, 'moderator');
                  } else if (action == 'member') {
                    _changeRole(member.id, 'member');
                  } else if (action == 'remove') {
                    _removeMember(member);
                  }
                },
                itemBuilder: (ctx) => [
                  if (member.role != 'moderator')
                    const PopupMenuItem(
                      value: 'moderator',
                      child: Text('Make Moderator'),
                    ),
                  if (member.role != 'member')
                    const PopupMenuItem(
                      value: 'member',
                      child: Text('Make Member'),
                    ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text(
                      'Remove from Group',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              )
            : null,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => UserProfileScreen(userId: member.user.id),
            ),
          );
        },
      ),
    );
  }
}
