import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../colony_theme.dart';
import '../data_service.dart';
import '../storage_service.dart';
import '../supabase_service.dart';

class EditProfileScreen extends StatefulWidget {
  final UserProfile? initialProfile;

  const EditProfileScreen({super.key, this.initialProfile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final DataService _dataService = DataService();
  final ImagePicker _picker = ImagePicker();

  late final TextEditingController _nameController;
  late final TextEditingController _usernameController;
  late final TextEditingController _bioController;

  String? _avatarUrl;
  String? _bannerUrl;
  bool _isSaving = false;
  bool _isUploadingAvatar = false;
  bool _isUploadingBanner = false;

  @override
  void initState() {
    super.initState();
    final user = SupabaseService().currentUser;
    final profile = widget.initialProfile;
    _nameController = TextEditingController(text: profile?.displayName ?? '');
    _usernameController = TextEditingController(
      text: (profile?.username ?? user?.userMetadata?['username'] ?? '')
          .toString(),
    );
    _bioController = TextEditingController(text: profile?.bio ?? '');
    _avatarUrl = profile?.avatarUrl ?? user?.userMetadata?['avatar_url'];
    _bannerUrl = (user?.userMetadata?['banner_url'])?.toString();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    setState(() => _isUploadingAvatar = true);
    try {
      final url = await StorageService().uploadAvatar(file);
      if (!mounted) return;
      setState(() => _avatarUrl = url);
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  Future<void> _pickBanner() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    setState(() => _isUploadingBanner = true);
    try {
      final url = await StorageService().uploadGroupCover(file);
      if (!mounted) return;
      setState(() => _bannerUrl = url);
    } finally {
      if (mounted) setState(() => _isUploadingBanner = false);
    }
  }

  Future<void> _saveProfile() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final result = await _dataService.updateProfile(
        displayName: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        username: _usernameController.text.trim().isEmpty
            ? null
            : _usernameController.text.trim(),
        bio: _bioController.text.trim().isEmpty
            ? null
            : _bioController.text.trim(),
        avatarUrl: _avatarUrl,
      );

      if (!mounted) return;

      if (result == 'username_taken') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Username is already taken'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (result != true) return;

      await SupabaseService().updateProfile(
        displayName: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        avatarUrl: _avatarUrl,
        username: _usernameController.text.trim().isEmpty
            ? null
            : _usernameController.text.trim(),
        bannerUrl: _bannerUrl,
      );

      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        title: const Text('Edit Profile'),
        backgroundColor: c.scaffold,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: _isUploadingBanner ? null : _pickBanner,
                child: Container(
                  height: 140,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: c.card,
                    image: _bannerUrl != null
                        ? DecorationImage(
                            image: NetworkImage(_bannerUrl!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: _isUploadingBanner
                      ? Center(
                          child: CircularProgressIndicator(color: c.accent),
                        )
                      : _bannerUrl == null
                      ? Center(
                          child: Text(
                            'Tap to add banner image',
                            style: TextStyle(color: c.secondaryText),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 46,
                      backgroundImage: _avatarUrl != null
                          ? NetworkImage(_avatarUrl!)
                          : const NetworkImage('https://i.pravatar.cc/150'),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: IconButton(
                        style: IconButton.styleFrom(backgroundColor: c.card),
                        onPressed: _isUploadingAvatar ? null : _pickAvatar,
                        icon: _isUploadingAvatar
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: c.accent,
                                ),
                              )
                            : const Icon(Icons.edit),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _bioController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveProfile,
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save Changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
