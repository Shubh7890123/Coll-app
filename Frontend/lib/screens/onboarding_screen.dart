import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import '../storage_service.dart';
import '../supabase_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  final _displayNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  String? _avatarUrl;
  bool _isUploading = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _pageController.dispose();
    _displayNameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _pickAvatar() async {
    if (_isUploading) return;
    final picker = ImagePicker();
    final xfile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (xfile == null || !mounted) return;

    setState(() => _isUploading = true);
    try {
      final url = await StorageService().uploadAvatar(xfile);
      if (mounted) setState(() => _avatarUrl = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to upload avatar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _isUploading = false);
  }

  Future<void> _complete() async {
    setState(() => _isSaving = true);
    try {
      final updates = <String, dynamic>{};
      final dn = _displayNameController.text.trim();
      final un = _usernameController.text.trim();
      final bio = _bioController.text.trim();

      if (dn.isNotEmpty) updates['display_name'] = dn;
      if (un.isNotEmpty) updates['username'] = un;
      if (bio.isNotEmpty) updates['bio'] = bio;
      if (_avatarUrl != null) updates['avatar_url'] = _avatarUrl;

      if (updates.isNotEmpty) {
        await DataService().updateProfile(
          displayName: dn.isNotEmpty ? dn : null,
          username: un.isNotEmpty ? un : null,
          bio: bio.isNotEmpty ? bio : null,
          avatarUrl: _avatarUrl,
        );
      }

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _isSaving = false);
  }

  void _skip() {
    Navigator.pushReplacementNamed(context, '/home');
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _buildWelcomePage(c),
                  _buildProfilePage(c),
                  _buildReadyPage(c),
                ],
              ),
            ),
            _buildBottomControls(c),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomePage(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.location_on, size: 80, color: c.accent),
          const SizedBox(height: 24),
          Text(
            'Welcome to Colony!',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: c.primaryText,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'Connect with people nearby, discover local groups, and chat securely — all within your 5 km community.',
            style: TextStyle(fontSize: 16, color: c.secondaryText, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _buildFeatureTile(
            c,
            Icons.people_outline,
            'Discover Neighbors',
            'Find people within 5km of you',
          ),
          const SizedBox(height: 12),
          _buildFeatureTile(
            c,
            Icons.group_outlined,
            'Join Local Groups',
            'Connect with communities around you',
          ),
          const SizedBox(height: 12),
          _buildFeatureTile(
            c,
            Icons.lock_outline,
            'Secure Chat',
            'End-to-end encrypted messaging',
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureTile(
    ColonyColors c,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.divider.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.pillBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: c.accent, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: c.primaryText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: c.secondaryText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfilePage(ColonyColors c) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Set up your profile',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: c.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Let people know who you are',
            style: TextStyle(fontSize: 14, color: c.secondaryText),
          ),
          const SizedBox(height: 28),
          GestureDetector(
            onTap: _pickAvatar,
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundImage: _avatarUrl != null
                      ? NetworkImage(_avatarUrl!)
                      : const NetworkImage('https://i.pravatar.cc/200'),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: c.accent,
                      shape: BoxShape.circle,
                    ),
                    child: _isUploading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 16,
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _displayNameController,
            decoration: InputDecoration(
              labelText: 'Display Name',
              labelStyle: TextStyle(color: c.secondaryText),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameController,
            decoration: InputDecoration(
              labelText: 'Username',
              prefixText: '@ ',
              labelStyle: TextStyle(color: c.secondaryText),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _bioController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Bio (optional)',
              labelStyle: TextStyle(color: c.secondaryText),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadyPage(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, size: 80, color: c.accent),
          const SizedBox(height: 24),
          Text(
            'You\'re all set!',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: c.primaryText,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Start discovering people and groups in your neighborhood. Your location is never shared publicly.',
            style: TextStyle(fontSize: 16, color: c.secondaryText, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: _skip,
            child: Text('Skip', style: TextStyle(color: c.secondaryText)),
          ),
          Row(
            children: [
              for (int i = 0; i < 3; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage == i ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentPage == i ? c.accent : c.divider,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
          _currentPage < 2
              ? ElevatedButton(
                  onPressed: _nextPage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text('Next'),
                )
              : ElevatedButton(
                  onPressed: _isSaving ? null : _complete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Get Started'),
                ),
        ],
      ),
    );
  }
}
