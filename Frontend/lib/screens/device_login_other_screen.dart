import 'package:flutter/material.dart';

import '../device_auth_service.dart';

class DeviceLoginOtherScreen extends StatefulWidget {
  const DeviceLoginOtherScreen({super.key});

  @override
  State<DeviceLoginOtherScreen> createState() => _DeviceLoginOtherScreenState();
}

class _DeviceLoginOtherScreenState extends State<DeviceLoginOtherScreen> {
  final _usernameController = TextEditingController();
  final _pinController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  bool _isValidPin(String v) => RegExp(r'^\d{4}$').hasMatch(v);

  Future<void> _login() async {
    final username = _usernameController.text.trim().toLowerCase();
    final pin = _pinController.text.trim();

    if (username.isEmpty) {
      setState(() => _error = 'Enter your profile name');
      return;
    }
    if (!_isValidPin(pin)) {
      setState(() => _error = 'Enter a 4-digit PIN');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await DeviceAuthService().loginWithUsernamePin(username: username, pin: pin);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F7ED),
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: const Color(0xFFF2F7ED),
        elevation: 0,
        title: const Text('Login on this phone'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your profile name + PIN',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14471E),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'On your first phone, your profile name looks like “ninjasparks”.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 18),
              if (_error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.red.withOpacity(0.25)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.red,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(
                  labelText: 'Profile name',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '4-digit PIN',
                  counterText: '',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B5A27),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Login',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

