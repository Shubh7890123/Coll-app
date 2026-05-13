import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'config.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  late final SupabaseClient _client;
  bool _isInitialized = false;

  SupabaseClient get client => _client;
  bool get isInitialized => _isInitialized;

  // Initialize Supabase
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Load config from environment variables
      await Config.load();
      
      await Supabase.initialize(
        url: Config.supabaseUrl,
        anonKey: Config.supabaseAnonKey,
        debug: kDebugMode,
      );
      _client = Supabase.instance.client;
      _isInitialized = true;
      debugPrint('Supabase initialized successfully');
    } catch (e) {
      debugPrint('Error initializing Supabase: $e');
      rethrow;
    }
  }

  // Get current user
  User? get currentUser => _client.auth.currentUser;

  // Get auth state stream
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  // Check if user is logged in
  bool get isLoggedIn => currentUser != null;

  // Sign up with email and password
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: displayName != null ? {'display_name': displayName} : null,
    );
    return response;
  }

  // Sign in with email and password
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    return response;
  }

  // Sign out
  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  // Reset password
  Future<void> resetPassword(String email) async {
    await _client.auth.resetPasswordForEmail(email);
  }

  // Update user profile
  Future<UserResponse> updateProfile({
    String? displayName,
    String? avatarUrl,
    String? username,
    String? bannerUrl,
  }) async {
    final response = await _client.auth.updateUser(
      UserAttributes(
        data: {
          if (displayName != null) 'display_name': displayName,
          if (avatarUrl != null) 'avatar_url': avatarUrl,
          if (username != null) 'username': username,
          if (bannerUrl != null) 'banner_url': bannerUrl,
        },
      ),
    );
    return response;
  }

  // Get user display name
  String? get displayName {
    final user = currentUser;
    if (user == null) return null;
    return user.userMetadata?['display_name'] ?? user.email?.split('@')[0];
  }

  // Get user avatar URL
  String? get avatarUrl {
    final user = currentUser;
    if (user == null) return null;
    return user.userMetadata?['avatar_url'];
  }
}
