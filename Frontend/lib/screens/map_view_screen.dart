import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../colony_theme.dart';
import '../data_service.dart';
import '../location_service.dart';
import 'events_screen.dart';
import 'user_profile_screen.dart';

class MapViewScreen extends StatefulWidget {
  const MapViewScreen({super.key});

  @override
  State<MapViewScreen> createState() => _MapViewScreenState();
}

class _MapViewScreenState extends State<MapViewScreen> {
  final DataService _dataService = DataService();
  UserLocation? _userLocation;
  List<NearbyUser> _users = [];
  List<NearbyEvent> _events = [];
  bool _isLoading = true;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final locationResult = await LocationService().fetchAndUpdateLocation();
    if (!mounted) return;
    if (!locationResult.success ||
        locationResult.latitude == null ||
        locationResult.longitude == null) {
      setState(() => _isLoading = false);
      return;
    }
    final location = UserLocation(
      latitude: locationResult.latitude!,
      longitude: locationResult.longitude!,
      locationText: locationResult.locationText ?? 'Unknown',
    );
    final results = await Future.wait([
      _dataService.getNearbyUsers(
        latitude: location.latitude,
        longitude: location.longitude,
      ),
      _dataService.getNearbyEvents(
        latitude: location.latitude,
        longitude: location.longitude,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _userLocation = location;
      _users = results[0] as List<NearbyUser>;
      _events = results[1] as List<NearbyEvent>;
      _isLoading = false;
    });
  }

  Future<void> _openUser(NearbyUser user) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(userId: user.id),
      ),
    );
  }

  Future<void> _openEvent(NearbyEvent event) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventDetailScreen(eventId: event.id),
      ),
    );
    if (mounted) {
      _load();
    }
  }

  Future<void> _showUserPreview(NearbyUser user) async {
    final c = ColonyColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.displayNameOrHandle,
                style: TextStyle(
                  color: c.primaryText,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${user.displayDistance} • ${user.locationText ?? 'Nearby'}',
                style: TextStyle(color: c.secondaryText),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _openUser(user);
                  },
                  child: const Text('Open Profile'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEventPreview(NearbyEvent event) async {
    final c = ColonyColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.title,
                style: TextStyle(
                  color: c.primaryText,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${event.scheduleLabel} • ${event.locationText}',
                style: TextStyle(color: c.secondaryText),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _openEvent(event);
                  },
                  child: const Text('Open Event'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: c.scaffold,
        title: const Text('Live Map'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : _userLocation == null
          ? Center(
              child: Text(
                'Location required to show nearby people and events.',
                style: TextStyle(color: c.secondaryText),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _filterChip(c, 'all', 'All'),
                          const SizedBox(width: 8),
                          _filterChip(c, 'people', 'People'),
                          const SizedBox(width: 8),
                          _filterChip(c, 'events', 'Events'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Tap any green or orange marker to open details.',
                        style: TextStyle(color: c.secondaryText, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: LatLng(
                        _userLocation!.latitude,
                        _userLocation!.longitude,
                      ),
                      initialZoom: 14,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'colony_login',
                      ),
                      MarkerLayer(markers: _buildMarkers(c)),
                    ],
                  ),
                ),
                Container(
                  height: 166,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  decoration: BoxDecoration(
                    color: c.card,
                    border: Border(top: BorderSide(color: c.divider.withOpacity(0.2))),
                  ),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      if (_filter != 'events') ..._users.take(10).map(
                        (user) => Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _summaryCard(
                            c,
                            title: user.displayNameOrHandle,
                            subtitle: user.displayDistance,
                            color: const Color(0xFF2E8B57),
                            onTap: () => _openUser(user),
                          ),
                        ),
                      ),
                      if (_filter != 'people') ..._events.take(10).map(
                        (event) => Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _summaryCard(
                            c,
                            title: event.title,
                            subtitle: event.locationText,
                            color: const Color(0xFFF17F36),
                            onTap: () => _openEvent(event),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  List<Marker> _buildMarkers(ColonyColors c) {
    final markers = <Marker>[
      Marker(
        point: LatLng(_userLocation!.latitude, _userLocation!.longitude),
        width: 56,
        height: 56,
        child: const Icon(Icons.my_location, color: Colors.blue, size: 34),
      ),
    ];

    if (_filter != 'events') {
      markers.addAll(
        _users.where((user) => user.latitude != null && user.longitude != null).map(
          (user) => Marker(
            point: LatLng(user.latitude!, user.longitude!),
            width: 56,
            height: 56,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showUserPreview(user),
              child: Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E8B57),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.18),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.person_pin_circle, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (_filter != 'people') {
      markers.addAll(
        _events.map(
          (event) => Marker(
            point: LatLng(event.latitude, event.longitude),
            width: 60,
            height: 60,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showEventPreview(event),
              child: Center(
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF17F36),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.18),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.celebration_outlined, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  Widget _filterChip(ColonyColors c, String value, String label) {
    final active = _filter == value;
    return ChoiceChip(
      selected: active,
      label: Text(label),
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: c.filledButtonBg,
      labelStyle: TextStyle(
        color: active ? c.filledButtonFg : c.secondaryText,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _summaryCard(
    ColonyColors c, {
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.scaffold,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.divider.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withOpacity(0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.place, color: color),
            ),
            const Spacer(),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.primaryText,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.secondaryText, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
