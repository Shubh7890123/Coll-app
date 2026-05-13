import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'colony_theme.dart';
import 'supabase_service.dart';
import 'encryption_service.dart';
import 'screens/device_auth_gate.dart';
import 'screens/call_screen.dart';
import 'call_service.dart';
import 'notification_service.dart';
import 'theme_controller.dart';

/// Global navigator key — lets NotificationService push routes without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase FIRST (required before any Firebase operations)
  await Firebase.initializeApp();
  print('Firebase initialized successfully');

  // Initialize Supabase
  await SupabaseService().initialize();

  // Initialize Notification Service
  await NotificationService().initialize();

  // Initialize Call Service with error handling
  try {
    await CallService().initialize(
      onIncomingCall:
          ({
            required callId,
            required callerId,
            required conversationId,
            required isVideo,
            required callerName,
            callerAvatar,
          }) {
            final nav = appNavigatorKey.currentState;
            if (nav != null) {
              nav.push(
                MaterialPageRoute<void>(
                  builder: (context) => CallScreen(
                    conversationId: conversationId,
                    callId: callId,
                    recipientId: callerId,
                    recipientName: callerName,
                    recipientAvatar: callerAvatar,
                    isVideo: isVideo,
                    isIncoming: true,
                  ),
                ),
              );
            }
          },
    );
    print('CallService initialized successfully');
  } catch (e) {
    print('CallService initialization failed: $e');
  }

  // Initialize Encryption (loads keys from secure storage; upload deferred until login)
  try {
    await EncryptionService().initialize();
  } catch (e) {
    print('Encryption init error at startup: $e');
  }

  await ThemeController.instance.load();

  runApp(const ColonyApp());
}

class ColonyApp extends StatelessWidget {
  const ColonyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'Colony Auth',
          debugShowCheckedModeBanner: false,
          theme: ColonyTheme.light,
          darkTheme: ColonyTheme.dark,
          themeMode: ThemeController.instance.useDark
              ? ThemeMode.dark
              : ThemeMode.light,
          home: const DeviceAuthGate(),
          navigatorKey: appNavigatorKey,
        );
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFEEF9E9), Color(0xFFE2F3D9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.location_on, size: 64, color: const Color(0xFF1B5A27)),
              const SizedBox(height: 16),
              const Text(
                'Colony',
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1B5A27),
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(color: Color(0xFF1B5A27)),
            ],
          ),
        ),
      ),
    );
  }
}
