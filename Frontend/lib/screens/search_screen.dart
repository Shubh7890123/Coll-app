import 'dart:async';
import 'package:flutter/material.dart';
import '../colony_theme.dart';
import '../search_service.dart';
import '../data_service.dart';
import '../models/search_result.dart';
import 'user_profile_screen.dart';
import 'chat_detail_screen.dart';
import 'package:shimmer/shimmer.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin {
  final SearchService _searchService = SearchService();
  final DataService _dataService = DataService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  
  late TabController _tabController;
  
  GlobalSearchResult _result = GlobalSearchResult.empty();
  List<String> _recentSearches = [];
  bool _isLoading = false;
  bool _isSearching = false;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadRecentSearches();
    
    _searchController.addListener(_onSearchChanged);
    _searchFocusNode.addListener(() {
      setState(() {});
    });
  }
  
  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _tabController.dispose();
    _searchService.dispose();
    super.dispose();
  }
  
  Future<void> _loadRecentSearches() async {
    final searches = await _searchService.getRecentSearches();
    setState(() {
      _recentSearches = searches;
    });
  }
  
  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _isSearching = false;
        _result = GlobalSearchResult.empty();
      });
      return;
    }
    
    setState(() {
      _isSearching = true;
    });
    
    _searchService.searchWithDebounce(
      query,
      onLoading: () => setState(() => _isLoading = true),
      onResult: (result) {
        if (mounted) {
          setState(() {
            _result = result;
            _isLoading = false;
          });
        }
      },
    );
  }
  
  void _clearSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _isSearching = false;
      _result = GlobalSearchResult.empty();
    });
  }
  
  void _onSearchSubmitted(String query) {
    if (query.trim().isNotEmpty) {
      _searchService.saveRecentSearch(query).then((_) => _loadRecentSearches());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: c.scaffold,
        elevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: _buildSearchBar(c),
        bottom: _isSearching ? _buildTabBar(c) : null,
      ),
      body: _isSearching 
          ? _buildSearchResults(c)
          : _buildSearchHistory(c),
    );
  }
  
  Widget _buildSearchBar(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: c.searchBarFill,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: _searchFocusNode.hasFocus ? c.accent : c.divider.withOpacity(0.5),
            width: 1.5,
          ),
        ),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          onSubmitted: _onSearchSubmitted,
          style: TextStyle(color: c.primaryText, fontSize: 16),
          decoration: InputDecoration(
            hintText: 'Search neighbors, groups or events...',
            hintStyle: TextStyle(color: c.secondaryText, fontSize: 14),
            prefixIcon: Icon(Icons.search, color: _searchFocusNode.hasFocus ? c.accent : c.iconMuted),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close, color: c.iconMuted, size: 20),
                    onPressed: _clearSearch,
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }
  
  PreferredSizeWidget _buildTabBar(ColonyColors c) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.divider.withOpacity(0.5))),
        ),
        child: TabBar(
          controller: _tabController,
          indicatorColor: c.accent,
          indicatorWeight: 3,
          labelColor: c.accent,
          unselectedLabelColor: c.secondaryText,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          tabs: const [
            Tab(text: 'Top'),
            Tab(text: 'People'),
            Tab(text: 'Groups'),
          ],
        ),
      ),
    );
  }
  
  Widget _buildSearchResults(ColonyColors c) {
    if (_isLoading && _result.isEmpty) {
      return _buildSkeletonList(c);
    }
    
    return TabBarView(
      controller: _tabController,
      children: [
        _buildTopResults(c),
        _buildPeopleResults(c),
        _buildGroupsResults(c),
      ],
    );
  }
  
  Widget _buildTopResults(ColonyColors c) {
    if (_result.top.isEmpty && !_isLoading) {
      return _buildEmptyState(c, 'No results found for "${_searchController.text}"');
    }
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: _result.top.length,
      itemBuilder: (context, index) {
        final item = _result.top[index];
        if (item is UserSearchItemModel) {
          return _buildUserTile(c, item.user);
        } else if (item is GroupSearchItemModel) {
          return _buildGroupTile(c, item.group);
        }
        return const SizedBox.shrink();
      },
    );
  }
  
  Widget _buildPeopleResults(ColonyColors c) {
    if (_result.users.isEmpty && !_isLoading) {
      return _buildEmptyState(c, 'No people found matching "${_searchController.text}"');
    }
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: _result.users.length,
      itemBuilder: (context, index) => _buildUserTile(c, _result.users[index]),
    );
  }
  
  Widget _buildGroupsResults(ColonyColors c) {
    if (_result.groups.isEmpty && !_isLoading) {
      return _buildEmptyState(c, 'No groups found matching "${_searchController.text}"');
    }
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: _result.groups.length,
      itemBuilder: (context, index) => _buildGroupTile(c, _result.groups[index]),
    );
  }
  
  Widget _buildUserTile(ColonyColors c, UserSearchResult user) {
    return ListTile(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserProfileScreen(userId: user.id)),
      ),
      leading: CircleAvatar(
        radius: 24,
        backgroundImage: user.avatarUrl != null 
          ? NetworkImage(user.avatarUrl!) 
          : const NetworkImage('https://i.pravatar.cc/150'),
      ),
      title: Row(
        children: [
          Text(
            user.username,
            style: TextStyle(color: c.primaryText, fontWeight: FontWeight.bold),
          ),
          if (user.isVerified) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified, color: Colors.blue, size: 14),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            user.displayName ?? '',
            style: TextStyle(color: c.secondaryText, fontSize: 13),
          ),
          if (user.mutualFriendsCount > 0)
            Text(
              '${user.mutualFriendsCount} mutual friends',
              style: TextStyle(color: c.accent.withOpacity(0.8), fontSize: 11),
            ),
        ],
      ),
      trailing: _buildUserActionBtn(c, user),
    );
  }
  
  Widget _buildUserActionBtn(ColonyColors c, UserSearchResult user) {
    if (user.isMe) return const SizedBox.shrink();

    switch (user.friendshipStatus) {
      case FriendshipStatus.friends:
        return ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChatDetailScreen(
                  otherUserId: user.id,
                  otherUserName: user.displayNameOrUsername,
                  otherUserAvatar: user.avatarUrl,
                ),
              ),
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: const Text(
            'Message',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
        );
      case FriendshipStatus.pendingSent:
        return OutlinedButton(
          onPressed: null,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: c.divider),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: const Text('Requested', style: TextStyle(fontSize: 12, color: Colors.grey)),
        );
      case FriendshipStatus.pendingReceived:
        return ElevatedButton(
          onPressed: () => _acceptWave(user),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF17F36),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: const Text('Accept', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        );
      default:
        return OutlinedButton(
          onPressed: () => _sendWave(user),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: c.accent),
            foregroundColor: c.accent,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: const Text('Add Friend', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        );
    }
  }

  Widget _buildGroupTile(ColonyColors c, GroupSearchResult group) {
    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(12),
          image: group.coverImageUrl != null
            ? DecorationImage(image: NetworkImage(group.coverImageUrl!), fit: BoxFit.cover)
            : null,
        ),
        child: group.coverImageUrl == null 
          ? Icon(Icons.group, color: c.accent) 
          : null,
      ),
      title: Text(
        group.name,
        style: TextStyle(color: c.primaryText, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        '${group.memberCount} members • ${group.isPrivate ? "Private" : "Public"}',
        style: TextStyle(color: c.secondaryText, fontSize: 12),
      ),
      trailing: _buildGroupActionBtn(c, group),
    );
  }
  
  Widget _buildGroupActionBtn(ColonyColors c, GroupSearchResult group) {
    if (group.isMember) {
      return Text(
        'Joined',
        style: TextStyle(color: c.iconMuted, fontWeight: FontWeight.w600, fontSize: 13),
      );
    }
    
    return ElevatedButton(
      onPressed: () => _joinGroup(group),
      style: ElevatedButton.styleFrom(
        backgroundColor: group.isPrivate ? Colors.grey.shade200 : c.accent.withOpacity(0.1),
        foregroundColor: group.isPrivate ? Colors.black87 : c.accent,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Text(
        group.isPrivate ? 'Request' : 'Join',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
  
  Widget _buildSearchHistory(ColonyColors c) {
    if (_recentSearches.isEmpty) {
      return _buildTrendingSection(c);
    }
    
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Searches',
                style: TextStyle(color: c.primaryText, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              TextButton(
                onPressed: () {
                  _searchService.clearRecentSearches().then((_) => _loadRecentSearches());
                },
                child: Text('Clear All', style: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        ..._recentSearches.map((query) => ListTile(
          onTap: () {
            _searchController.text = query;
            _onSearchSubmitted(query);
          },
          leading: Icon(Icons.history, color: c.iconMuted, size: 20),
          title: Text(query, style: TextStyle(color: c.primaryText)),
          trailing: IconButton(
            icon: Icon(Icons.close, color: c.iconMuted, size: 18),
            onPressed: () {
              _searchService.removeRecentSearch(query).then((_) => _loadRecentSearches());
            },
          ),
        )),
        const SizedBox(height: 24),
        _buildTrendingSection(c),
      ],
    );
  }
  
  Widget _buildTrendingSection(ColonyColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Trending in Colony',
            style: TextStyle(color: c.primaryText, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              '#LocalMeetup',
              'Green Gardeners',
              'Neighbors Helper',
              'Tech Community',
              'Daily Runners'
            ].map((tag) => ActionChip(
              label: Text(tag, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              onPressed: () {
                _searchController.text = tag;
                _onSearchSubmitted(tag);
              },
              backgroundColor: c.card,
              labelStyle: TextStyle(color: c.accent),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              side: BorderSide.none,
            )).toList(),
          ),
        ),
      ],
    );
  }
  
  Widget _buildEmptyState(ColonyColors c, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: c.iconMuted.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(color: c.secondaryText, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
  
  Widget _buildSkeletonList(ColonyColors c) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: 8,
      itemBuilder: (context, index) => Shimmer.fromColors(
        baseColor: c.divider.withOpacity(0.1),
        highlightColor: c.divider.withOpacity(0.05),
        child: ListTile(
          leading: CircleAvatar(backgroundColor: Colors.white, radius: 24),
          title: Container(height: 14, width: 100, color: Colors.white),
          subtitle: Container(height: 10, width: 150, color: Colors.white, margin: const EdgeInsets.only(top: 4)),
        ),
      ),
    );
  }
  
  // Logic actions
  
  Future<void> _sendWave(UserSearchResult user) async {
    final success = await _dataService.sendWave(user.id);
    if (success && mounted) {
      _onSearchChanged(); // Refresh to show "Requested"
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wave sent to ${user.username}!')),
      );
    }
  }
  
  Future<void> _acceptWave(UserSearchResult user) async {
    final success = await _dataService.acceptReceivedWave(user.id);
    if (success && mounted) {
      _onSearchChanged(); // Refresh to show "Message"
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You are now friends with ${user.username}!')),
      );
    }
  }
  
  Future<void> _joinGroup(GroupSearchResult group) async {
    final success = await _dataService.joinGroup(group.id);
    if (success && mounted) {
      _onSearchChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Joined ${group.name}!')),
      );
    }
  }
}
