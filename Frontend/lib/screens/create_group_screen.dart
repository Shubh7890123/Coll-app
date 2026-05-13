import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../colony_theme.dart';
import '../data_service.dart';
import '../location_service.dart';
import '../storage_service.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final DataService _dataService = DataService();
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final List<String> _categories = const [
    'SOCIAL',
    'TECH',
    'FITNESS',
    'LIFESTYLE',
    'ART',
    'MUSIC',
    'BUSINESS',
  ];

  String _selectedCategory = 'SOCIAL';
  bool _isPrivate = false;
  bool _isSaving = false;
  bool _isUploadingCover = false;
  String? _coverImageUrl;
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    final result = await LocationService().fetchAndUpdateLocation();
    if (!mounted) return;
    if (result.success) {
      setState(() {
        _latitude = result.latitude;
        _longitude = result.longitude;
      });
    }
  }

  Future<void> _pickCover() async {
    final xfile = await _picker.pickImage(source: ImageSource.gallery);
    if (xfile == null || !mounted) return;
    setState(() => _isUploadingCover = true);
    try {
      final url = await StorageService().uploadGroupCover(xfile);
      if (!mounted) return;
      setState(() => _coverImageUrl = url);
    } finally {
      if (mounted) setState(() => _isUploadingCover = false);
    }
  }

  Future<void> _createGroup() async {
    if (_isSaving || _nameController.text.trim().isEmpty) return;
    setState(() => _isSaving = true);
    try {
      final success = await _dataService.createGroup(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        category: _selectedCategory,
        latitude: _latitude,
        longitude: _longitude,
        coverImageUrl: _coverImageUrl,
        isPrivate: _isPrivate,
      );
      if (!mounted) return;
      Navigator.pop(context, success);
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
        title: const Text('Create Group'),
        backgroundColor: c.scaffold,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            children: [
              GestureDetector(
                onTap: _isUploadingCover ? null : _pickCover,
                child: Container(
                  height: 150,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: BorderRadius.circular(16),
                    image: _coverImageUrl != null
                        ? DecorationImage(
                            image: NetworkImage(_coverImageUrl!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: _isUploadingCover
                      ? Center(child: CircularProgressIndicator(color: c.accent))
                      : _coverImageUrl == null
                          ? Center(
                              child: Text(
                                'Tap to add cover image',
                                style: TextStyle(color: c.secondaryText),
                              ),
                            )
                          : null,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: _selectedCategory,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: _categories
                    .map(
                      (cat) => DropdownMenuItem(
                        value: cat,
                        child: Text(cat),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _selectedCategory = value);
                },
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _isPrivate,
                onChanged: (v) => setState(() => _isPrivate = v),
                title: const Text('Private Group'),
                subtitle: const Text('Hidden from nearby discovery'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _createGroup,
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create Group'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
