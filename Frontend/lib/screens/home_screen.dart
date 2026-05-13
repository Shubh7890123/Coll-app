import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../colony_theme.dart';
import '../location_service.dart';
import '../data_service.dart';
import '../storage_service.dart';
import 'user_profile_screen.dart';
import 'chat_detail_screen.dart';
import 'notifications_screen.dart';
import 'story_viewer_screen.dart';
import 'search_screen.dart';
import 'events_screen.dart';
import 'map_view_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DataService _dataService = DataService();
  final LocationService _locationService = LocationService();

  UserLocation? _userLocation;
  List<NearbyUser> _nearbyUsers = [];
  List<NearbyGroup> _nearbyGroups = [];
  List<NearbyEvent> _nearbyEvents = [];
  List<Story> _stories = [];

  bool _isLoadingLocation = true;
  bool _isLoadingUsers = false;
  bool _isLoadingGroups = false;
  bool _isLoadingEvents = false;
  bool _isLoadingStories = false;
  String? _errorMessage;
  String _searchQuery = '';

  // Parsed location parts for better display
  String _locationAreaName = '';
  String _locationCityLine = '';

  // Notification state
  int _notificationCount = 0;
  late final SupabaseClient _supabase;
  RealtimeChannel? _notificationChannel;
  Timer? _nearbyRefreshDebounce;

  @override
  void initState() {
    super.initState();
    _supabase = Supabase.instance.client;
    _initializeData();
    _fetchNotificationCount();
    _subscribeToNotifications();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _notificationChannel?.unsubscribe();
    _nearbyRefreshDebounce?.cancel();
    _locationService.stopActiveLocationTracking();
    super.dispose();
  }

  Future<void> _fetchNotificationCount() async {
    try {
      if (mounted) {
        setState(() {
          _notificationCount = 0;
        });
      }
      final count = await _dataService.getUnreadNotificationCount();
      if (mounted) {
        setState(() => _notificationCount = count);
      }
    } catch (e) {
      debugPrint('Error fetching notification count: $e');
    }
  }

  void _subscribeToNotifications() {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    _notificationChannel = _supabase.channel('home_notifications_$userId');
    _notificationChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (payload) {
            _fetchNotificationCount();
            _fetchNearbyData();
          },
        )
        .subscribe();
  }

  void _navigateToNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const NotificationsScreen()),
    );
    _fetchNotificationCount();
    _fetchNearbyData();
  }

  Future<void> _openEventsScreen({int initialTabIndex = 0}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventsScreen(initialTabIndex: initialTabIndex),
      ),
    );
    _fetchNearbyData();
  }

  Future<void> _openMapScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MapViewScreen()),
    );
    _fetchNearbyData();
  }

  Future<void> _initializeData() async {
    await _fetchLocation();
    if (_userLocation != null) {
      _fetchNearbyData();
    }
    _fetchStories();
  }

  void _parseLocationParts(String locationText) {
    final parts = locationText
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      // Capitalize each word properly
      _locationAreaName = _toTitleCase(parts[0]);
      _locationCityLine = parts.sublist(1).map(_toTitleCase).join(', ');
    } else if (parts.length == 1) {
      _locationAreaName = _toTitleCase(parts[0]);
      _locationCityLine = '';
    } else {
      _locationAreaName = _toTitleCase(locationText);
      _locationCityLine = '';
    }
  }

  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
        })
        .join(' ');
  }

  Future<void> _fetchLocation() async {
    setState(() {
      _isLoadingLocation = true;
      _errorMessage = null;
    });

    try {
      final result = await _locationService.fetchAndUpdateLocation();
      if (result.success &&
          result.latitude != null &&
          result.longitude != null) {
        setState(() {
          _userLocation = UserLocation(
            latitude: result.latitude!,
            longitude: result.longitude!,
            locationText: result.locationText ?? 'Unknown',
          );
          _parseLocationParts(result.locationText ?? 'Unknown');
        });
        await _fetchNearbyData();
      } else {
        final cached = await _locationService.getUserLocation();
        setState(() {
          _userLocation = cached;
          if (cached != null) {
            _parseLocationParts(cached.locationText);
          }
          _errorMessage =
              result.errorMessage ??
              (cached == null
                  ? 'Turn on location permission to see people, groups and events within 5 km.'
                  : null);
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Could not fetch location: $e';
      });
    } finally {
      setState(() {
        _isLoadingLocation = false;
      });
    }
  }

  void _startLocationTracking() {
    _locationService.startActiveLocationTracking(
      onLocationChanged: (location) {
        if (!mounted) return;
        setState(() {
          _userLocation = location;
          _parseLocationParts(location.locationText);
          _errorMessage = null;
          _isLoadingLocation = false;
        });
        _scheduleNearbyRefresh();
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _isLoadingLocation = false;
          _errorMessage = _friendlyLocationError(message);
        });
      },
    );
  }

  void _scheduleNearbyRefresh() {
    _nearbyRefreshDebounce?.cancel();
    _nearbyRefreshDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _fetchNearbyData();
    });
  }

  String _friendlyLocationError(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('disabled')) {
      return 'Location unavailable. Turn on GPS to see people, groups and events within 5 km.';
    }
    if (lower.contains('denied')) {
      return 'Location unavailable. Enable location permission to see nearby discovery.';
    }
    return 'Location unavailable';
  }

  Future<void> _fetchNearbyData() async {
    if (_userLocation == null) return;
    setState(() {
      _isLoadingUsers = true;
      _isLoadingGroups = true;
      _isLoadingEvents = true;
      _isLoadingStories = true;
    });

    final currentLocation = _userLocation!;

    final users = await _dataService.getNearbyUsers(
      latitude: currentLocation.latitude,
      longitude: currentLocation.longitude,
      radiusKm: DataService.maxNearbyRadiusKm,
    );

    final groups = await _dataService.getNearbyGroups(
      latitude: currentLocation.latitude,
      longitude: currentLocation.longitude,
      radiusKm: DataService.maxNearbyRadiusKm,
    );

    final events = await _dataService.getNearbyEvents(
      latitude: currentLocation.latitude,
      longitude: currentLocation.longitude,
      radiusKm: DataService.maxNearbyRadiusKm,
    );

    final stories = await _dataService.getActiveStories(
      latitude: currentLocation.latitude,
      longitude: currentLocation.longitude,
      radiusKm: DataService.maxNearbyRadiusKm,
    );

    setState(() {
      _nearbyUsers = users;
      _nearbyGroups = groups;
      _nearbyEvents = events;
      _stories = stories;
      _isLoadingUsers = false;
      _isLoadingGroups = false;
      _isLoadingEvents = false;
      _isLoadingStories = false;
    });
  }

  Future<void> _fetchStories() async {
    setState(() {
      _isLoadingStories = true;
    });
    final stories = await _dataService.getActiveStories(
      latitude: _userLocation?.latitude,
      longitude: _userLocation?.longitude,
      radiusKm: DataService.maxNearbyRadiusKm,
    );
    setState(() {
      _stories = stories;
      _isLoadingStories = false;
    });
  }

  Future<void> _refreshAll() async {
    await _initializeData();
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverAppBar(
              pinned: true,
              floating: false,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              elevation: innerBoxIsScrolled ? 2 : 0,
              toolbarHeight: 50,
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Colony',
                    style: TextStyle(
                      color: c.accent,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  _buildNotificationIcon(c),
                ],
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: _buildLocationBar(c),
              ),
            ),
          ],
          body: RefreshIndicator(
            color: c.accent,
            onRefresh: _refreshAll,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_errorMessage != null)
                          Container(
                            margin: const EdgeInsets.only(top: 12, bottom: 12),
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.orange.withOpacity(0.35),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.location_off,
                                  color: Colors.orange,
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _errorMessage!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.orange,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          const SizedBox(height: 16),
                        _buildSearchBar(c),
                        const SizedBox(height: 28),
                        _buildSectionHeader(
                          c,
                          'Colony Stories',
                          'VIEW ALL',
                          onActionTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const NotificationsScreen(),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        _buildStoriesList(c),
                        const SizedBox(height: 28),
                        _buildSectionHeader(c, 'Nearby People', null),
                        const SizedBox(height: 14),
                        _buildNearbyPeoplesList(c),
                        const SizedBox(height: 28),
                        _buildSectionHeader(c, 'Nearby Groups', 'JOIN NEW'),
                        const SizedBox(height: 14),
                        _buildNearbyGroupsList(c),
                        const SizedBox(height: 28),
                        _buildSectionHeader(
                          c,
                          'Nearby Events',
                          'PLAN NEW',
                          onActionTap: () => _openEventsScreen(initialTabIndex: 1),
                        ),
                        const SizedBox(height: 14),
                        _buildNearbyEventsList(c),
                        const SizedBox(height: 28),
                        _buildCommunityHighlightCard(c),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationIcon(ColonyColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _openMapScreen,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.searchBarFill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.divider.withOpacity(0.35)),
              ),
              child: Icon(
                Icons.map_rounded,
                color: c.primaryText,
                size: 22,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Stack(
          children: [
            IconButton(
              icon: Icon(
                Icons.notifications_outlined,
                color: c.accent,
                size: 28,
              ),
              tooltip: 'Notifications',
              onPressed: _navigateToNotifications,
            ),
            if (_notificationCount > 0)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 18,
                    minHeight: 18,
                  ),
                  child: Text(
                    _notificationCount > 99 ? '99+' : '$_notificationCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildLocationBar(ColonyColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: _isLoadingLocation
                ? Row(
                    children: [
                      Icon(
                        Icons.location_on_rounded,
                        color: c.accent,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Container(
                        height: 16,
                        width: 100,
                        decoration: BoxDecoration(
                          color: c.divider.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.location_on_rounded,
                            color: Colors.pinkAccent,
                            size: 24,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _locationAreaName.isEmpty
                                  ? (_userLocation?.locationText ??
                                        'Unknown Location')
                                  : _locationAreaName,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: c.primaryText,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: c.primaryText,
                            size: 22,
                          ),
                        ],
                      ),
                      if (_locationCityLine.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 30),
                          child: Text(
                            _locationCityLine,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: c.primaryText.withOpacity(0.8),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
          ),
          IconButton(
            onPressed: _fetchLocation,
            icon: Icon(Icons.refresh_rounded, color: c.iconMuted, size: 22),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ColonyColors c) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SearchScreen()),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: c.searchBarFill,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: c.divider.withOpacity(0.6)),
          boxShadow: [
            if (!c.isDark)
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                spreadRadius: 2,
              ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: Row(
            children: [
              Icon(Icons.search, color: c.iconMuted),
              const SizedBox(width: 12),
              Text(
                'Search neighbors, groups or events...',
                style: TextStyle(color: c.secondaryText, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    ColonyColors c,
    String title,
    String? action, {
    VoidCallback? onActionTap,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: c.primaryText,
          ),
        ),
        if (action != null)
          GestureDetector(
            onTap: onActionTap,
            child: Text(
              action,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: c.accent,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStoriesList(ColonyColors c) {
    if (_isLoadingStories) {
      return SizedBox(
        height: 100,
        child: Center(child: CircularProgressIndicator(color: c.accent)),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildAddStoryBtn(c),
          const SizedBox(width: 15),
          if (_stories.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
              child: Text(
                'No stories yet',
                style: TextStyle(color: c.secondaryText),
              ),
            )
          else
            ..._stories.map(
              (story) => Padding(
                padding: const EdgeInsets.only(right: 15),
                child: _buildStoryItem(c, story),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAddStoryBtn(ColonyColors c) {
    return GestureDetector(
      onTap: _addStory,
      child: Column(
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade400, width: 2),
            ),
            child: Icon(Icons.add, color: c.accent, size: 30),
          ),
          const SizedBox(height: 8),
          Text(
            'Add Story',
            style: TextStyle(fontSize: 12, color: c.secondaryText),
          ),
        ],
      ),
    );
  }

  Future<void> _addStory() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    // Show caption dialog
    String? caption;
    if (mounted) {
      final captionController = TextEditingController();
      caption = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Add Caption'),
          content: TextField(
            controller: captionController,
            decoration: const InputDecoration(
              hintText: 'Write a caption (optional)...',
            ),
            maxLines: 2,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(ctx, captionController.text.trim()),
              child: const Text('Next'),
            ),
          ],
        ),
      );
    }

    if (!mounted) return;

    // Show uploading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 12),
            Text('Uploading story...'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      final url = await StorageService().uploadAvatar(picked);
      final ok = await _dataService.createStory(
        mediaUrl: url,
        mediaType: 'image',
        caption: caption?.isNotEmpty == true ? caption : null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Story posted!'),
            backgroundColor: Color(0xFF2E6B3B),
          ),
        );
        _fetchStories();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to post story'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _buildStoryItem(ColonyColors c, Story story) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final isOwn = story.userId == currentUserId;
    return GestureDetector(
      onTap: () => _viewStory(story, isOwn),
      child: Column(
        children: [
          Container(
            width: 70,
            height: 70,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFF17F36), width: 3),
            ),
            child: CircleAvatar(
              backgroundColor: Colors.grey.shade300,
              backgroundImage: story.user.avatarUrl != null
                  ? NetworkImage(story.user.avatarUrl!)
                  : const NetworkImage('https://i.pravatar.cc/150'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isOwn ? 'My Story' : story.user.displayNameOrHandle,
            style: TextStyle(
              fontSize: 12,
              color: c.primaryText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  void _viewStory(Story story, bool isOwn) {
    final storyIndex = _stories.indexOf(story);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StoryViewerScreen(
          stories: _stories,
          initialIndex: storyIndex >= 0 ? storyIndex : 0,
        ),
      ),
    ).then((_) => _fetchStories());
  }

  String _getTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _buildNearbyPeoplesList(ColonyColors c) {
    if (_isLoadingUsers) {
      return SizedBox(
        height: 150,
        child: Center(child: CircularProgressIndicator(color: c.accent)),
      );
    }

    final filteredUsers = _nearbyUsers.where((u) {
      if (_searchQuery.isEmpty) return true;
      final name = '${u.displayNameOrHandle} ${u.publicHandle}';
      return name.toLowerCase().contains(_searchQuery);
    }).toList();

    if (filteredUsers.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(Icons.people_outline, size: 48, color: c.iconMuted),
            const SizedBox(height: 10),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No people found matching "$_searchQuery"'
                  : (_userLocation == null
                        ? 'Enable location to see nearby people'
                        : 'No people found within 5km'),
              style: TextStyle(color: c.secondaryText),
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filteredUsers.map((user) {
          return Padding(
            padding: const EdgeInsets.only(right: 15),
            child: _PeopleCard(
              user: user,
              dataService: _dataService,
              onRemove: () {
                setState(() {
                  _nearbyUsers.removeWhere((u) => u.id == user.id);
                });
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildNearbyGroupsList(ColonyColors c) {
    if (_isLoadingGroups) {
      return SizedBox(
        height: 100,
        child: Center(child: CircularProgressIndicator(color: c.accent)),
      );
    }

    final filteredGroups = _nearbyGroups.where((g) {
      if (_searchQuery.isEmpty) return true;
      return g.name.toLowerCase().contains(_searchQuery) ||
          (g.description?.toLowerCase().contains(_searchQuery) ?? false);
    }).toList();

    if (filteredGroups.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(Icons.group_outlined, size: 48, color: c.iconMuted),
            const SizedBox(height: 10),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No groups found matching "$_searchQuery"'
                  : (_userLocation == null
                        ? 'Enable location to see nearby groups'
                        : 'No groups found within 5km'),
              style: TextStyle(color: c.secondaryText),
            ),
          ],
        ),
      );
    }
    return Column(
      children: filteredGroups.take(3).map((group) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: _buildGroupCard(c, group),
        );
      }).toList(),
    );
  }

  Widget _buildNearbyEventsList(ColonyColors c) {
    if (_isLoadingEvents) {
      return SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator(color: c.accent)),
      );
    }

    final filteredEvents = _nearbyEvents.where((event) {
      if (_searchQuery.isEmpty) return true;
      return event.title.toLowerCase().contains(_searchQuery) ||
          event.locationText.toLowerCase().contains(_searchQuery) ||
          event.category.toLowerCase().contains(_searchQuery);
    }).toList();

    if (filteredEvents.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(Icons.event_note_outlined, size: 48, color: c.iconMuted),
            const SizedBox(height: 10),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No events found matching "$_searchQuery"'
                  : (_userLocation == null
                        ? 'Enable location to see nearby events'
                        : 'No nearby events within 5km'),
              style: TextStyle(color: c.secondaryText),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: 160,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filteredEvents.take(10).length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, index) {
          final event = filteredEvents[index];
          return SizedBox(
            width: 320,
            child: EventCard(
              event: event,
              onTap: () async {
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EventDetailScreen(eventId: event.id),
                  ),
                );
                if (changed == true) {
                  _fetchNearbyData();
                }
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildGroupCard(ColonyColors c, NearbyGroup group) {
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.divider.withOpacity(c.isDark ? 0.5 : 0.25)),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: c.pillBackground,
            ),
            child: group.coverImageUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      group.coverImageUrl!,
                      fit: BoxFit.cover,
                    ),
                  )
                : Icon(Icons.group, color: c.primaryText, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: c.categoryChipBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        group.category?.toUpperCase() ?? 'GROUP',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: c.categoryChipFg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.location_on, size: 12, color: c.iconMuted),
                    Text(
                      group.displayDistance,
                      style: TextStyle(fontSize: 10, color: c.iconMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  group.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: c.primaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${group.memberCount} members',
                  style: TextStyle(fontSize: 12, color: c.secondaryText),
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final success = await _dataService.joinGroup(group.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success
                          ? 'Joined ${group.name}!'
                          : 'Failed to join group',
                    ),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
                if (success) _fetchNearbyData();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: c.filledButtonBg,
              foregroundColor: c.filledButtonFg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Widget _buildCommunityHighlightCard(ColonyColors c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.communityBannerTop, c.communityBannerBottom],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: c.isDark ? Border.all(color: c.divider) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Welcome to Colony!',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect with ${_nearbyUsers.length} neighbors, ${_nearbyGroups.length} groups and ${_nearbyEvents.length} events nearby.',
            style: TextStyle(fontSize: 14, color: c.communityBodyText),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _refreshAll,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: c.communityCtaFg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: const Text('Explore Community'),
          ),
        ],
      ),
    );
  }
}

// People card widget
class _PeopleCard extends StatefulWidget {
  final NearbyUser user;
  final DataService dataService;
  final VoidCallback? onRemove;

  const _PeopleCard({
    required this.user,
    required this.dataService,
    this.onRemove,
  });

  @override
  State<_PeopleCard> createState() => _PeopleCardState();
}

class _PeopleCardState extends State<_PeopleCard> {
  String? _friendStatus;
  bool _isLoading = true;
  bool _isSending = false;
  RealtimeChannel? _waveChannel;

  @override
  void initState() {
    super.initState();
    _loadStatus();
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
        .channel('wave-status-${widget.user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'waves',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: user.id,
          ),
          callback: (_) => _loadStatus(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'waves',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: user.id,
          ),
          callback: (_) => _loadStatus(),
        )
        .subscribe();
  }

  Future<void> _loadStatus() async {
    final status = await widget.dataService.getFriendRequestStatus(
      widget.user.id,
    );
    if (mounted) {
      setState(() {
        _friendStatus = status;
        _isLoading = false;
      });
    }
  }

  Future<void> _sendFriendRequest() async {
    setState(() => _isSending = true);
    final success = await widget.dataService.sendFriendRequest(widget.user.id);
    if (!mounted) return;
    if (success) {
      await _loadStatus();
      if (!mounted) return;
    }
    setState(() => _isSending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Friend request sent!' : 'Could not send request.',
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _acceptRequest() async {
    setState(() => _isSending = true);
    final success = await widget.dataService.acceptReceivedWave(widget.user.id);
    if (!mounted) return;
    if (success) {
      await _loadStatus();
      if (!mounted) return;
    }
    setState(() => _isSending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? 'Friend request accepted!' : 'Error'),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _declineRequest() async {
    setState(() => _isSending = true);
    final success = await widget.dataService.rejectReceivedWave(widget.user.id);
    if (mounted) {
      if (success) await _loadStatus();
      setState(() => _isSending = false);
    }
  }

  Future<void> _openChat() async {
    final conv = await widget.dataService.getOrCreateConversation(
      widget.user.id,
    );
    if (!mounted) return;
    if (conv == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open chat right now')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          conversationId: conv.id,
          otherUserId: widget.user.id,
          otherUserName: widget.user.displayNameOrHandle,
          otherUserAvatar: widget.user.avatarUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    final isFriend =
        _friendStatus == 'accepted' || _friendStatus == 'received_accepted';
    final isRequested = _friendStatus == 'pending';
    final hasReceived = _friendStatus == 'received';

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => UserProfileScreen(userId: widget.user.id),
          ),
        ).then((_) => _loadStatus());
      },
      child: Container(
        width: 170, // Slightly wider for the buttons
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.rowCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: c.divider.withOpacity(c.isDark ? 0.4 : 0.2),
          ),
          boxShadow: [
            if (!c.isDark)
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top large image
            SizedBox(
              height: 170,
              width: double.infinity,
              child: widget.user.avatarUrl != null
                  ? Image.network(widget.user.avatarUrl!, fit: BoxFit.cover)
                  : Image.network(
                      'https://ui-avatars.com/api/?name=${Uri.encodeComponent(widget.user.displayNameOrHandle)}&size=300&background=random',
                      fit: BoxFit.cover,
                    ),
            ),
            // Content below image
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.user.displayNameOrHandle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: c.primaryText,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.user.publicHandle,
                    style: TextStyle(
                      fontSize: 12,
                      color: c.secondaryText,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (widget.user.demographicsText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.user.demographicsText,
                      style: TextStyle(fontSize: 12, color: c.secondaryText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.location_on, size: 12, color: c.secondaryText),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.user.displayDistance,
                          style: TextStyle(
                            fontSize: 12,
                            color: c.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Action buttons
                  if (_isLoading)
                    const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (isFriend)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _openChat,
                        icon: const Icon(Icons.chat_bubble_outline, size: 16),
                        label: const Text(
                          'Message',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B5A27),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                      ),
                    )
                  else if (hasReceived)
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _isSending ? null : _acceptRequest,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1B5A27),
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              elevation: 0,
                            ),
                            child: _isSending
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.check, size: 14),
                                      SizedBox(width: 4),
                                      Text(
                                        'Accept',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _isSending ? null : _declineRequest,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: c.isDark
                                  ? const Color(0xFF333333)
                                  : const Color(0xFFE4E6EB),
                              foregroundColor: c.isDark
                                  ? Colors.white
                                  : Colors.black87,
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              elevation: 0,
                            ),
                            child: const Text(
                              'Decline',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: (_isSending || isRequested)
                            ? null
                            : _sendFriendRequest,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isRequested
                              ? Colors.grey
                              : const Color(0xFF1877F2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        child: _isSending
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    isRequested
                                        ? Icons.check
                                        : Icons.person_add,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isRequested ? 'Request Sent' : 'Add Friend',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
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
}
