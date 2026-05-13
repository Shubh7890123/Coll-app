import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../device_auth_service.dart';
import '../encryption_service.dart';
import '../notification_service.dart';
import '../supabase_service.dart';
import 'device_login_other_screen.dart';
import 'device_onboarding_screen.dart';
import 'device_unlock_screen.dart';
import 'main_navigation_screen.dart';

class DeviceAuthGate extends StatefulWidget {
  const DeviceAuthGate({super.key});

  @override
  State<DeviceAuthGate> createState() => _DeviceAuthGateState();
}

class _DeviceAuthGateState extends State<DeviceAuthGate> {
  bool _booting = true;
  bool _hasLocal = false;
  String? _error;
  String? _lastNotifiedUserId;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _error = null;
    });

    try {
      _hasLocal = await DeviceAuthService().hasSavedCredentials();

      // If we have local creds but no session, attempt a silent sign-in.
      if (_hasLocal && SupabaseService().client.auth.currentSession == null) {
        await DeviceAuthService().signInWithSavedCredentials();
      }

      if (SupabaseService().client.auth.currentUser != null) {
        await NotificationService().onUserAuthenticated();
      }

      // Ensure encryption keys are uploaded now that we have a session
      try {
        await EncryptionService().initialize();
      } catch (e) {
        print('Encryption init error during boot: $e');
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _booting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: SupabaseService().client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final user =
            snapshot.data?.session?.user ??
            SupabaseService().client.auth.currentUser;

        if (_booting) {
          return const _GateSplash();
        }

        if (user != null) {
          if (_lastNotifiedUserId != user.id) {
            _lastNotifiedUserId = user.id;
            NotificationService().onUserAuthenticated();
          }
          return const MainNavigationScreen();
        }

        // No session:
        // - If local exists => show unlock
        // - Else => first-run onboarding
        return Stack(
          children: [
            _hasLocal
                ? const DeviceUnlockScreen()
                : const DeviceOnboardingScreen(),
            Positioned(
              right: 14,
              top: MediaQuery.of(context).padding.top + 8,
              child: TextButton(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DeviceLoginOtherScreen(),
                    ),
                  );
                  await _boot();
                },
                child: const Text('Login on this phone'),
              ),
            ),
            if (_error != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.red.withOpacity(0.25)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GateSplash extends StatelessWidget {
  const _GateSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF2F7ED),
      body: Center(child: CircularProgressIndicator(color: Color(0xFF1B5A27))),
    );
  }
}
