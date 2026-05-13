import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import '../location_service.dart';
import '../storage_service.dart';
import '../supabase_service.dart';
import 'group_chat_screen.dart';
import 'group_admin_panel.dart';
import 'create_group_screen.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final DataService _dataService = DataService();

  List<NearbyGroup> _nearbyGroups = [];
  List<NearbyGroup> _myGroups = [];
  bool _isLoading = true;
  String _searchQuery = '';
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final locationResult = await LocationService().fetchAndUpdateLocation();
    if (locationResult.success) {
      setState(() {
        _latitude = locationResult.latitude;
        _longitude = locationResult.longitude;
      });
    }
    await _fetchGroups();
  }

  Future<void> _fetchGroups() async {
    List<NearbyGroup> nearbyGroups = [];
    if (_latitude != null && _longitude != null) {
      nearbyGroups = await _dataService.getNearbyGroups(
        latitude: _latitude!,
        longitude: _longitude!,
        radiusKm: DataService.maxNearbyRadiusKm,
      );
    }
    final myGroups = await _dataService.getMyJoinedGroups();
    if (!mounted) return;
    setState(() {
      _nearbyGroups = nearbyGroups;
      _myGroups = myGroups;
      _isLoading = false;
    });
  }

  void _openGroupChat(NearbyGroup group) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => GroupChatScreen(
          groupId: group.id,
          groupName: group.name,
          coverImageUrl: group.coverImageUrl,
        ),
      ),
    ).then((_) => _fetchGroups());
  }

  Future<void> _joinGroup(NearbyGroup group) async {
    final success = await _dataService.joinGroup(group.id);
    if (success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Joined ${group.name}!'),
            backgroundColor: Colors.green,
          ),
        );
        _tabController.animateTo(1);
      }
      await _fetchGroups();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to join group'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _leaveGroup(NearbyGroup group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Group?'),
        content: Text('Are you sure you want to leave "${group.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Leave', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final success = await _dataService.leaveGroup(group.id);
    if (success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Left ${group.name}')));
      await _fetchGroups();
    }
  }

  Future<void> _updateGroupCover(NearbyGroup group) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery);
    if (xfile == null) return;
    try {
      final url = await StorageService().uploadGroupCover(xfile);
      final success = await _dataService.updateGroupCover(
        groupId: group.id,
        coverImageUrl: url,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Cover updated!' : 'Failed to update cover'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
      if (success) await _fetchGroups();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _openCreateGroupScreen() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
    );
    if (!mounted || created != true) return;
    _tabController.animateTo(1);
    await _fetchGroups();
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildStickyHeader(c),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadData,
                color: c.accent,
                child: _isLoading
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.5,
                            child: Center(
                              child: CircularProgressIndicator(color: c.accent),
                            ),
                          ),
                        ],
                      )
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildNearbyGroupsList(c),
                          _buildMyGroupsList(c),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreateGroupScreen,
        backgroundColor: c.fabBackground,
        elevation: 4,
        child: Icon(Icons.add, color: c.fabForeground, size: 28),
      ),
    );
  }

  Widget _buildStickyHeader(ColonyColors c) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Discover groups',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w900,
              color: c.primaryText,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 12),
          _buildSearchBar(c),
          const SizedBox(height: 14),
          _buildPremiumTabs(c),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ColonyColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.searchBarFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.divider.withOpacity(0.35)),
      ),
      child: TextField(
        onChanged: (value) =>
            setState(() => _searchQuery = value.trim().toLowerCase()),
        decoration: InputDecoration(
          hintText: 'Search groups...',
          hintStyle: TextStyle(color: c.secondaryText),
          prefixIcon: Icon(Icons.search, color: c.iconMuted),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildPremiumTabs(ColonyColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.segmentedTrack,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.divider.withOpacity(c.isDark ? 0.4 : 0.15)),
      ),
      padding: const EdgeInsets.all(4),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: c.segmentedSelectedBg,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: c.accent.withOpacity(0.18),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: c.segmentedSelectedFg,
        unselectedLabelColor: c.segmentedUnselectedFg,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          letterSpacing: 0.1,
        ),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 13,
        ),
        tabs: [
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.explore_outlined, size: 16),
                const SizedBox(width: 6),
                const Text('Nearby Groups'),
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.group_outlined, size: 16),
                const SizedBox(width: 6),
                Text(
                  'My Groups${_myGroups.isNotEmpty ? ' (${_myGroups.length})' : ''}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNearbyGroupsList(ColonyColors c) {
    final filtered = _nearbyGroups.where((g) {
      if (_searchQuery.isEmpty) return true;
      return g.name.toLowerCase().contains(_searchQuery) ||
          (g.description?.toLowerCase().contains(_searchQuery) ?? false);
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: c.pillBackground,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.explore_off_outlined,
                  size: 48,
                  color: c.iconMuted,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'No nearby groups found',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: c.primaryText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Be the first to create a community in your area!',
                style: TextStyle(fontSize: 13, color: c.secondaryText),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _openCreateGroupScreen,
                icon: const Icon(Icons.add),
                label: const Text('Create Group'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.filledButtonBg,
                  foregroundColor: c.filledButtonFg,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildGroupCard(c, filtered[index]),
    );
  }

  Widget _buildMyGroupsList(ColonyColors c) {
    final filtered = _myGroups.where((g) {
      if (_searchQuery.isEmpty) return true;
      return g.name.toLowerCase().contains(_searchQuery) ||
          (g.description?.toLowerCase().contains(_searchQuery) ?? false);
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: c.pillBackground,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.group_add_outlined,
                  size: 48,
                  color: c.iconMuted,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "You haven't joined any groups",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: c.primaryText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Explore nearby communities and join one!',
                style: TextStyle(fontSize: 13, color: c.secondaryText),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _tabController.animateTo(0),
                icon: const Icon(Icons.explore_outlined),
                label: const Text('Browse Groups'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.filledButtonBg,
                  foregroundColor: c.filledButtonFg,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: filtered.length,
      itemBuilder: (context, index) =>
          _buildGroupCard(c, filtered[index], isMyGroup: true),
    );
  }

  Widget _buildGroupCard(
    ColonyColors c,
    NearbyGroup group, {
    bool isMyGroup = false,
  }) {
    final category = group.category ?? 'SOCIAL';
    final tint = c.categoryTint(category);
    final chipBg = c.isDark ? c.categoryChipBg : tint.withOpacity(0.15);
    final chipFg = c.isDark ? c.categoryChipFg : tint.withOpacity(1.0);

    return GestureDetector(
      onTap: group.isMember
          ? () => _openGroupChat(group)
          : () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Join "${group.name}" to open group chat'),
                ),
              );
            },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: c.divider.withOpacity(c.isDark ? 0.4 : 0.12),
          ),
          boxShadow: [
            if (!c.isDark)
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover image / placeholder
            Stack(
              children: [
                if (group.coverImageUrl != null)
                  Image.network(
                    group.coverImageUrl!,
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        _buildImagePlaceholder(c, tint, 150),
                  )
                else
                  _buildImagePlaceholder(c, tint, 120),
                // Category chip overlay
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: chipBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: chipFg.withOpacity(0.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_categoryIcon(category), size: 10, color: chipFg),
                        const SizedBox(width: 4),
                        Text(
                          category,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: chipFg,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Distance badge
                Positioned(
                  top: 14,
                  right: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.location_on,
                          size: 10,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          group.displayDistance,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + member count
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          group.name,
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            color: c.primaryText,
                            height: 1.2,
                          ),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.pillBackground,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 12,
                              color: c.secondaryText,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${group.memberCount}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: c.primaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (group.description != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      group.description!,
                      style: TextStyle(
                        fontSize: 13,
                        color: c.secondaryText,
                        height: 1.45,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 16),
                  // Action buttons
                  if (group.isMember) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _openGroupChat(group),
                        icon: const Icon(Icons.chat_bubble_outline, size: 18),
                        label: const Text(
                          'Open Group Chat',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: c.filledButtonBg,
                          foregroundColor: c.filledButtonFg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (isMyGroup)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _updateGroupCover(group),
                              icon: Icon(
                                Icons.image_outlined,
                                color: c.outlineButtonFg,
                                size: 16,
                              ),
                              label: Text(
                                'Edit Cover',
                                style: TextStyle(
                                  color: c.outlineButtonFg,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                side: BorderSide(color: c.outlineButtonBorder),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        if (isMyGroup) const SizedBox(width: 10),
                        if (isMyGroup)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => GroupAdminPanel(
                                      groupId: group.id,
                                      groupName: group.name,
                                    ),
                                  ),
                                );
                              },
                              icon: Icon(
                                Icons.manage_accounts_outlined,
                                color: c.outlineButtonFg,
                                size: 16,
                              ),
                              label: Text(
                                'Manage',
                                style: TextStyle(
                                  color: c.outlineButtonFg,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                side: BorderSide(color: c.outlineButtonBorder),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        if (isMyGroup) const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _leaveGroup(group),
                            icon: const Icon(
                              Icons.exit_to_app,
                              color: Colors.red,
                              size: 16,
                            ),
                            label: const Text(
                              'Leave',
                              style: TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: const BorderSide(
                                color: Colors.red,
                                width: 0.8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _joinGroup(group),
                        icon: const Icon(Icons.group_add_outlined, size: 18),
                        label: const Text(
                          'Join Community',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: c.filledButtonBg,
                          foregroundColor: c.filledButtonFg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder(ColonyColors c, Color tint, double height) {
    return Container(
      height: height,
      width: double.infinity,
      color: c.isDark ? c.pillBackground : tint.withOpacity(0.12),
      child: Center(
        child: Icon(
          Icons.group,
          size: 48,
          color: c.isDark ? c.iconMuted : tint.withOpacity(0.6),
        ),
      ),
    );
  }

  IconData _categoryIcon(String category) {
    switch (category.toUpperCase()) {
      case 'TECH':
        return Icons.computer_outlined;
      case 'FITNESS':
        return Icons.fitness_center_outlined;
      case 'ART':
        return Icons.palette_outlined;
      case 'MUSIC':
        return Icons.music_note_outlined;
      case 'BUSINESS':
        return Icons.business_center_outlined;
      case 'LIFESTYLE':
        return Icons.spa_outlined;
      default:
        return Icons.people_outline;
    }
  }
}
