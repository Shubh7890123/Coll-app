import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../colony_theme.dart';
import '../data_service.dart';
import 'home_screen.dart';
import 'groups_screen.dart';
import 'chat_list_screen.dart';
import 'profile_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  int _unreadCount = 0;
  RealtimeChannel? _unreadChannel;

  final List<Widget> _screens = [
    const HomeScreen(),
    const GroupsScreen(),
    const ChatListScreen(),
    const ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _fetchUnreadCount();
    _subscribeToUnreadChanges();
  }

  @override
  void dispose() {
    _unreadChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _fetchUnreadCount() async {
    final count = await DataService().getTotalUnreadCount();
    if (!mounted) return;
    setState(() => _unreadCount = count);
  }

  void _subscribeToUnreadChanges() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    _unreadChannel?.unsubscribe();
    _unreadChannel = Supabase.instance.client.channel('unread_nav_$userId');

    _unreadChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          callback: (_) => _fetchUnreadCount(),
        )
        .subscribe();
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: c.scaffold,
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: Container(
        color: c.scaffold,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(0, Icons.home_outlined, Icons.home, dark),
              _buildNavItem(1, Icons.people_outline, Icons.people, dark),
              _buildNavItem(
                2,
                Icons.chat_bubble_outline,
                Icons.chat_bubble,
                dark,
              ),
              _buildNavItem(3, Icons.person_outline, Icons.person, dark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    IconData iconOutline,
    IconData iconFilled,
    bool dark,
  ) {
    final isActive = _currentIndex == index;
    final c = ColonyColors.of(context);
    final activeColor = dark ? Colors.white : c.accent;
    final inactiveColor = dark ? const Color(0xFF777777) : c.iconMuted;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _currentIndex = index),
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SizedBox(
              height: 26,
              width: 26,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(
                    child: Icon(
                      isActive ? iconFilled : iconOutline,
                      color: isActive ? activeColor : inactiveColor,
                      size: 26,
                    ),
                  ),
                  if (index == 2 && _unreadCount > 0)
                    Positioned(
                      top: -4,
                      right: -8,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          _unreadCount > 9 ? '9+' : '$_unreadCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
