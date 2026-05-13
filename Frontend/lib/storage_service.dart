import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final SupabaseClient _client = SupabaseService().client;

  static const String avatarsBucket = 'avatars';
  static const String groupCoversBucket = 'group_covers';

  String _guessContentType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'image/jpeg';
  }

  String _safeExt(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'png';
    if (lower.endsWith('.webp')) return 'webp';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpg';
    return 'jpg';
  }

  Future<String> _uploadToBucket({
    required String bucket,
    required String folder,
    required XFile file,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw Exception('User not logged in');
    }

    final ext = _safeExt(file.path);
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.$ext';
    final storagePath = '$folder/$fileName';

    final contentType = _guessContentType(file.path);
    final bytes = await File(file.path).readAsBytes();

    await _client.storage
        .from(bucket)
        .uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );

    return _client.storage.from(bucket).getPublicUrl(storagePath);
  }

  /// Uploads a new profile picture and returns its public URL.
  Future<String> uploadAvatar(XFile file) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final folder = '${user.id}';
    return _uploadToBucket(bucket: avatarsBucket, folder: folder, file: file);
  }

  /// Uploads a new group cover image and returns its public URL.
  Future<String> uploadGroupCover(XFile file) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final folder = '${user.id}';
    return _uploadToBucket(
      bucket: groupCoversBucket,
      folder: folder,
      file: file,
    );
  }

  /// Uploads an event cover image. Reuses the shared cover bucket with a
  /// dedicated folder prefix so events and groups stay organized.
  Future<String> uploadEventCover(XFile file) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final folder = 'events/${user.id}';
    return _uploadToBucket(
      bucket: groupCoversBucket,
      folder: folder,
      file: file,
    );
  }

  /// Uploads a chat image attachment and returns its public URL.
  /// Images are stored in the 'chat_media' bucket under the sender's user ID.
  Future<String> uploadChatMedia(XFile file) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    return _uploadToBucket(bucket: 'chat_media', folder: user.id, file: file);
  }

  /// Uploads any file from a local path to a specific bucket and path.
  Future<String> uploadFileFromPath({
    required String filePath,
    required String bucket,
    required String storagePath,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('User not logged in');

    final bytes = await File(filePath).readAsBytes();

    await _client.storage
        .from(bucket)
        .uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(upsert: true),
        );

    return _client.storage.from(bucket).getPublicUrl(storagePath);
  }
}
