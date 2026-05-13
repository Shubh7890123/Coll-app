import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class Config {
  static String? _supabaseUrl;
  static String? _supabaseAnonKey;
  static String? _backendUrl;
  static String? _androidBackendUrl;
  static String? _twilioTurnUrl;
  static String? _twilioTurnUsername;
  static String? _twilioTurnCredential;
  static bool _isInitialized = false;

  static Future<void> load() async {
    if (_isInitialized) return;

    try {
      // Load environment variables from .env file
      await dotenv.load(fileName: '.env');
      
      _supabaseUrl = dotenv.env['SUPABASE_URL'];
      _supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
      _backendUrl = dotenv.env['BACKEND_URL'] ?? 'http://localhost:3000';
      _androidBackendUrl = dotenv.env['ANDROID_BACKEND_URL'];
      _twilioTurnUrl = dotenv.env['TWILIO_TURN_URL'] ?? dotenv.env['TURN_URL'] ?? '';
      _twilioTurnUsername = dotenv.env['TWILIO_TURN_USERNAME'] ?? dotenv.env['TURN_USERNAME'] ?? '';
      _twilioTurnCredential = dotenv.env['TWILIO_TURN_CREDENTIAL'] ?? dotenv.env['TURN_CREDENTIAL'] ?? '';

      // Validate required environment variables
      if (_supabaseUrl == null || _supabaseUrl!.isEmpty) {
        throw Exception('SUPABASE_URL is not set in .env file');
      }
      if (_supabaseAnonKey == null || _supabaseAnonKey!.isEmpty) {
        throw Exception('SUPABASE_ANON_KEY is not set in .env file');
      }

      _isInitialized = true;
    } catch (e) {
      print('Error loading config: $e');
      rethrow;
    }
  }

  static String get supabaseUrl => _supabaseUrl ?? '';
  static String get supabaseAnonKey => _supabaseAnonKey ?? '';
  
  static String get backendUrl {
    final url = _backendUrl ?? 'http://localhost:3000';
    if (!kIsWeb && Platform.isAndroid && url.contains('localhost')) {
      if (_androidBackendUrl != null && _androidBackendUrl!.isNotEmpty) {
        return _androidBackendUrl!;
      }
      return url.replaceAll('localhost', '10.0.2.2');
    }
    return url;
  }
  
  static String get twilioTurnUrl => _twilioTurnUrl ?? '';
  static String get twilioTurnUsername => _twilioTurnUsername ?? '';
  static String get twilioTurnCredential => _twilioTurnCredential ?? '';
}
