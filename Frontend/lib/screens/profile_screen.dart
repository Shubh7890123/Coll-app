import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../auth_service.dart';
import '../colony_theme.dart';
import '../notification_service.dart';
import '../supabase_service.dart';
import '../data_service.dart';
import '../location_service.dart';
import '../storage_service.dart';
import '../theme_controller.dart';
import 'call_history_screen.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final DataService _dataService = DataService();

  int _friendsCount = 0;
  int _groupsCount = 0;
  int _storiesCount = 0;
  String _locationText = 'Unknown';
  bool _isLoading = true;
  UserProfile? _userProfile;
  bool _isUploadingAvatar = false;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final userId = SupabaseService().client.auth.currentUser?.id;
    if (userId == null) return;

    // Run all fetches in parallel
    final results = await Future.wait([
      _dataService.getUserProfile(userId),
      LocationService().getUserLocation(),
      _dataService.getFriendsCount(userId),
      _dataService.getUserGroupsCount(userId),
      _dataService.getUserStoriesCount(userId),
    ]);

    if (!mounted) return;
    setState(() {
      _userProfile = results[0] as UserProfile?;
      final location = results[1] as UserLocation?;
      _locationText = location?.locationText ?? 'Unknown';
      _friendsCount = results[2] as int;
      _groupsCount = results[3] as int;
      _storiesCount = results[4] as int;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadProfileData,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            children: [
              _buildHeader(context, c),
              const SizedBox(height: 20),
              _buildProfileHeader(c),
              const SizedBox(height: 18),
              _buildActionButtons(context, c),
              const SizedBox(height: 24),
              _buildStatsRow(c),
              const SizedBox(height: 24),
              _buildLogoutButton(context),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColonyColors c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Profile',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w900,
            color: c.primaryText,
          ),
        ),
        IconButton(
          icon: Icon(Icons.settings, color: c.primaryText),
          onPressed: () => _showSettingsBottomSheet(context),
        ),
      ],
    );
  }

  void _showSettingsBottomSheet(BuildContext context) {
    final c = ColonyColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final pad = MediaQuery.of(sheetCtx).padding.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: pad),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.9,
            ),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                  const SizedBox(height: 24),
                  Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSettingsTile(Icons.person_outline, 'Edit Profile', () {
                    Navigator.pop(sheetCtx);
                    _openEditProfileScreen();
                  }, c),
                  _buildSettingsTile(Icons.palette_outlined, 'Theme', () {
                    Navigator.pop(sheetCtx);
                    _showThemeDialog(context);
                  }, c),
                  _buildSettingsTile(
                    Icons.notifications_outlined,
                    'Notifications',
                    () {
                      Navigator.pop(sheetCtx);
                      _showNotificationSettingsDialog(context);
                    },
                    c,
                  ),
                  _buildSettingsTile(Icons.call_outlined, 'Call History', () {
                    Navigator.pop(sheetCtx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CallHistoryScreen(),
                      ),
                    );
                  }, c),
                  _buildSettingsTile(Icons.lock_outline, 'Privacy', () {
                    Navigator.pop(sheetCtx);
                    _showPrivacyDialog(context);
                  }, c),
                  _buildSettingsTile(
                    Icons.location_on_outlined,
                    'Location Precision',
                    () {
                      Navigator.pop(sheetCtx);
                      _showLocationPrecisionDialog(context);
                    },
                    c,
                  ),
                  _buildSettingsTile(Icons.help_outline, 'Help & Support', () {
                    Navigator.pop(sheetCtx);
                    _showHelpDialog(context);
                  }, c),
                  _buildSettingsTile(Icons.info_outline, 'About', () {
                    Navigator.pop(sheetCtx);
                    _showAboutDialog(context);
                  }, c),
                  Divider(height: 32, color: c.divider),
                  _buildLogoutTile(context, sheetCtx, c),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showThemeDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: ThemeController.instance,
        builder: (context, _) {
          final dark = ThemeController.instance.useDark;
          return AlertDialog(
            title: const Text('Theme'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<bool>(
                  title: const Text('Light'),
                  value: false,
                  groupValue: dark,
                  onChanged: (v) async {
                    if (v != null) {
                      await ThemeController.instance.setUseDark(false);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                ),
                RadioListTile<bool>(
                  title: const Text('Dark'),
                  value: true,
                  groupValue: dark,
                  onChanged: (v) async {
                    if (v != null) {
                      await ThemeController.instance.setUseDark(true);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showPrivacyDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Privacy'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Your Privacy on Colony',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                '• Your exact location is never shared publicly. Only users within 5 km can discover you.\n'
                '• All 1:1 messages are end-to-end encrypted — not even Colony can read them.\n'
                '• Your profile is visible only to nearby users within your discovery radius.\n'
                '• You can remove friends at any time from their profile.\n'
                '• You can block users by tapping the ⋮ menu on their profile.',
                style: TextStyle(height: 1.6),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _showNotificationSettingsDialog(BuildContext context) async {
    var settings = await _dataService.getNotificationSettings();
    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Notifications'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  value: settings.dmNotifications,
                  title: const Text('Direct messages'),
                  onChanged: (value) {
                    setDialogState(() {
                      settings = NotificationPreferenceSettings(
                        userId: settings.userId,
                        dmNotifications: value,
                        groupNotifications: settings.groupNotifications,
                        friendRequestNotifications:
                            settings.friendRequestNotifications,
                        mentionNotifications: settings.mentionNotifications,
                        callNotifications: settings.callNotifications,
                      );
                    });
                  },
                ),
                SwitchListTile(
                  value: settings.groupNotifications,
                  title: const Text('Group activity'),
                  onChanged: (value) {
                    setDialogState(() {
                      settings = NotificationPreferenceSettings(
                        userId: settings.userId,
                        dmNotifications: settings.dmNotifications,
                        groupNotifications: value,
                        friendRequestNotifications:
                            settings.friendRequestNotifications,
                        mentionNotifications: settings.mentionNotifications,
                        callNotifications: settings.callNotifications,
                      );
                    });
                  },
                ),
                SwitchListTile(
                  value: settings.friendRequestNotifications,
                  title: const Text('Friend requests'),
                  onChanged: (value) {
                    setDialogState(() {
                      settings = NotificationPreferenceSettings(
                        userId: settings.userId,
                        dmNotifications: settings.dmNotifications,
                        groupNotifications: settings.groupNotifications,
                        friendRequestNotifications: value,
                        mentionNotifications: settings.mentionNotifications,
                        callNotifications: settings.callNotifications,
                      );
                    });
                  },
                ),
                SwitchListTile(
                  value: settings.mentionNotifications,
                  title: const Text('Mentions'),
                  onChanged: (value) {
                    setDialogState(() {
                      settings = NotificationPreferenceSettings(
                        userId: settings.userId,
                        dmNotifications: settings.dmNotifications,
                        groupNotifications: settings.groupNotifications,
                        friendRequestNotifications:
                            settings.friendRequestNotifications,
                        mentionNotifications: value,
                        callNotifications: settings.callNotifications,
                      );
                    });
                  },
                ),
                SwitchListTile(
                  value: settings.callNotifications,
                  title: const Text('Calls'),
                  onChanged: (value) {
                    setDialogState(() {
                      settings = NotificationPreferenceSettings(
                        userId: settings.userId,
                        dmNotifications: settings.dmNotifications,
                        groupNotifications: settings.groupNotifications,
                        friendRequestNotifications:
                            settings.friendRequestNotifications,
                        mentionNotifications: settings.mentionNotifications,
                        callNotifications: value,
                      );
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                await _dataService.updateNotificationSettings(settings);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showLocationPrecisionDialog(BuildContext context) {
    String precision = _userProfile?.locationPrecision ?? 'precise';
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Location Precision'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Control how precisely your location is visible to others.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              RadioListTile<String>(
                title: const Text('Precise'),
                subtitle: const Text(
                  'Show exact location within 5km',
                  style: TextStyle(fontSize: 11),
                ),
                value: 'precise',
                groupValue: precision,
                onChanged: (v) => setDialogState(() => precision = v!),
              ),
              RadioListTile<String>(
                title: const Text('Approximate'),
                subtitle: const Text(
                  'Show approximate area only',
                  style: TextStyle(fontSize: 11),
                ),
                value: 'approximate',
                groupValue: precision,
                onChanged: (v) => setDialogState(() => precision = v!),
              ),
              RadioListTile<String>(
                title: const Text('Hidden'),
                subtitle: const Text(
                  'Don\'t share your location',
                  style: TextStyle(fontSize: 11),
                ),
                value: 'hidden',
                groupValue: precision,
                onChanged: (v) => setDialogState(() => precision = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                await DataService().updateLocationPrecision(precision);
                if (ctx.mounted) Navigator.pop(ctx);
                _loadProfileData();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showHelpDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help & Support'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                'Frequently Asked Questions',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'Q: Why can\'t I see nearby people?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                'A: Make sure location permissions are granted in device settings.\n',
              ),
              Text(
                'Q: Why can\'t I chat with someone?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                'A: Both users need to accept each other\'s wave (friend request) first.\n',
              ),
              Text(
                'Q: How do I delete my account?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text('A: Contact support at support@colony.app\n'),
              Divider(),
              SizedBox(height: 4),
              Text('Contact Us', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('Email: support@colony.app'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('About Colony'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on, size: 48, color: Color(0xFF1B5A27)),
            SizedBox(height: 12),
            Text(
              'Colony',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text('Version 1.0.0', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 12),
            Text(
              'Colony connects you with people nearby. Discover neighbors, join local groups, and chat securely — all within your 5 km community.',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              '© 2026 Colony App',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditProfileScreen() async {
    final didUpdate = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(initialProfile: _userProfile),
      ),
    );
    if (didUpdate == true && mounted) {
      _loadProfileData();
    }
  }

  Widget _buildSettingsTile(
    IconData icon,
    String title,
    VoidCallback onTap,
    ColonyColors c,
  ) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.pillBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: c.accent, size: 24),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: c.primaryText,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: c.secondaryText),
      onTap: onTap,
    );
  }

  Widget _buildLogoutTile(
    BuildContext context,
    BuildContext sheetContext,
    ColonyColors c,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final errBg = dark ? const Color(0xFF3D1515) : Colors.red.shade50;
    final errFg = dark ? const Color(0xFFFF8A8A) : Colors.red.shade700;

    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: errBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.logout, color: errFg, size: 24),
      ),
      title: Text(
        'Logout',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: errFg,
        ),
      ),
      onTap: () async {
        Navigator.pop(sheetContext);
        _handleLogout(context);
      },
    );
  }

  void _handleLogout(BuildContext context) async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B5A27),
              foregroundColor: Colors.white,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout == true && context.mounted) {
      await NotificationService().onUserSignedOut();
      final result = await AuthService().signOut();
      if (context.mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.message),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.message),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Widget _buildProfileHeader(ColonyColors c) {
    return StreamBuilder<AuthState>(
      stream: SupabaseService().client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final user = snapshot.data?.session?.user;
        final displayName =
            _userProfile?.displayName ??
            user?.userMetadata?['display_name'] ??
            user?.userMetadata?['full_name'] ??
            user?.email?.split('@').first ??
            'User';
        final username =
            _userProfile?.username ??
            user?.userMetadata?['username'] ??
            '@${user?.email?.split('@').first ?? 'user'}';
        final avatarUrl =
            _userProfile?.avatarUrl ?? user?.userMetadata?['avatar_url'];
        final bannerUrl = (user?.userMetadata?['banner_url'])?.toString();
        final bio = _userProfile?.bio;

        return Container(
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.divider.withOpacity(0.35)),
          ),
          padding: const EdgeInsets.only(bottom: 20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 140,
                width: double.infinity,
                child: bannerUrl != null
                    ? Image.network(bannerUrl, fit: BoxFit.cover)
                    : Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF2A2A2A), Color(0xFF101010)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
              ),
              Transform.translate(
                offset: const Offset(0, -36),
                child: Center(
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 46,
                        backgroundImage: avatarUrl != null
                            ? NetworkImage(avatarUrl)
                            : const NetworkImage('https://i.pravatar.cc/150'),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: () => _showAvatarPickSheet(context, c),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: c.scaffold,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.edit,
                              color: c.primaryText,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                displayName,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: c.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                username,
                style: TextStyle(
                  fontSize: 16,
                  color: c.secondaryText,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (bio != null && bio.isNotEmpty) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    bio,
                    style: TextStyle(fontSize: 14, color: c.primaryText),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAvatarPickSheet(
    BuildContext context,
    ColonyColors c,
  ) async {
    if (_isUploadingAvatar) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: c.accent),
              title: Text(
                'Choose from gallery',
                style: TextStyle(color: c.primaryText),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _pickAndUploadAvatar(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Icon(Icons.camera_alt_outlined, color: c.accent),
              title: Text(
                'Take a photo',
                style: TextStyle(color: c.primaryText),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _pickAndUploadAvatar(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadAvatar(ImageSource source) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: source);
    if (xfile == null || !mounted) return;

    setState(() => _isUploadingAvatar = true);
    try {
      final url = await StorageService().uploadAvatar(xfile);

      // Update profile avatar_url in `profiles` table.
      await _dataService.updateProfile(avatarUrl: url);

      // Also update auth user metadata so header UIs using userMetadata stay in sync.
      await SupabaseService().updateProfile(avatarUrl: url);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile photo updated'),
          backgroundColor: Color(0xFF1B5A27),
        ),
      );

      await _loadProfileData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update photo: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  Widget _buildActionButtons(BuildContext context, ColonyColors c) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: _openEditProfileScreen,
            style: ElevatedButton.styleFrom(
              backgroundColor: dark
                  ? const Color(0xFF1E1E1E)
                  : const Color(0xFF1A5822),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Edit Profile',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Material(
          color: c.pillBackground,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _showSettingsBottomSheet(context),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(Icons.settings, color: c.iconMuted, size: 24),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow(ColonyColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: c.statBackground,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildStatItem('$_friendsCount', 'FRIENDS', c),
          _buildDivider(c),
          _buildStatItem('$_groupsCount', 'GROUPS', c),
          _buildDivider(c),
          _buildStatItem('$_storiesCount', 'STORIES', c),
        ],
      ),
    );
  }

  Widget _buildStatItem(String val, String label, ColonyColors c) {
    return Column(
      children: [
        Text(
          val,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: c.accent,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: c.secondaryText,
          ),
        ),
      ],
    );
  }

  Widget _buildDivider(ColonyColors c) {
    return Container(height: 30, width: 1, color: c.divider);
  }

  Widget _buildLogoutButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton.icon(
        onPressed: () => _handleLogout(context),
        icon: const Icon(Icons.logout, color: Colors.red),
        label: const Text(
          'Logout',
          style: TextStyle(
            color: Colors.red,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.red),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
      ),
    );
  }
}
