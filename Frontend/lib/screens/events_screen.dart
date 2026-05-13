import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../colony_theme.dart';
import '../data_service.dart';
import '../location_service.dart';
import '../storage_service.dart';

class EventsScreen extends StatefulWidget {
  final int initialTabIndex;

  const EventsScreen({super.key, this.initialTabIndex = 0});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final DataService _dataService = DataService();

  List<NearbyEvent> _nearbyEvents = [];
  List<NearbyEvent> _myEvents = [];
  bool _isLoading = true;
  String _searchQuery = '';
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
    );
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final locationResult = await LocationService().fetchAndUpdateLocation();
    if (locationResult.success && mounted) {
      setState(() {
        _latitude = locationResult.latitude;
        _longitude = locationResult.longitude;
      });
    }
    await _fetchEvents();
  }

  Future<void> _fetchEvents() async {
    List<NearbyEvent> nearby = [];
    if (_latitude != null && _longitude != null) {
      nearby = await _dataService.getNearbyEvents(
        latitude: _latitude!,
        longitude: _longitude!,
      );
    }
    final mine = await _dataService.getMyEvents();
    if (!mounted) return;
    setState(() {
      _nearbyEvents = nearby;
      _myEvents = mine;
      _isLoading = false;
    });
  }

  Future<void> _openCreateEvent({NearbyEvent? existing}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CreateEventScreen(existingEvent: existing),
      ),
    );
    if (changed == true) {
      await _loadData();
    }
  }

  Future<void> _openDetails(NearbyEvent event) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EventDetailScreen(eventId: event.id)),
    );
    if (changed == true) {
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(c),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadData,
                color: c.accent,
                child: _isLoading
                    ? ListView(
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.45,
                            child: Center(
                              child: CircularProgressIndicator(color: c.accent),
                            ),
                          ),
                        ],
                      )
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildEventList(c, _nearbyEvents, emptyTitle: 'No nearby events yet'),
                          _buildEventList(c, _myEvents, emptyTitle: 'Create your first event'),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCreateEvent(),
        backgroundColor: c.fabBackground,
        foregroundColor: c.fabForeground,
        icon: const Icon(Icons.add_circle_outline),
        label: const Text('Create Event'),
      ),
    );
  }

  Widget _buildHeader(ColonyColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Nearby events',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    color: c.primaryText,
                    letterSpacing: -0.8,
                  ),
                ),
              ),
              IconButton(
                onPressed: _loadData,
                icon: Icon(Icons.refresh_rounded, color: c.accent),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: c.searchBarFill,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.divider.withOpacity(0.35)),
            ),
            child: TextField(
              onChanged: (value) =>
                  setState(() => _searchQuery = value.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search by event, place or category',
                prefixIcon: Icon(Icons.search, color: c.iconMuted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: c.segmentedTrack,
              borderRadius: BorderRadius.circular(18),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: c.segmentedSelectedBg,
                borderRadius: BorderRadius.circular(18),
              ),
              labelColor: c.segmentedSelectedFg,
              unselectedLabelColor: c.segmentedUnselectedFg,
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(text: 'Nearby'),
                Tab(text: 'My Events'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList(
    ColonyColors c,
    List<NearbyEvent> source, {
    required String emptyTitle,
  }) {
    final events = source.where((event) {
      if (_searchQuery.isEmpty) return true;
      return event.title.toLowerCase().contains(_searchQuery) ||
          event.locationText.toLowerCase().contains(_searchQuery) ||
          event.category.toLowerCase().contains(_searchQuery);
    }).toList();

    if (events.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 48),
          Icon(Icons.event_busy_outlined, size: 52, color: c.iconMuted),
          const SizedBox(height: 12),
          Center(
            child: Text(
              emptyTitle,
              style: TextStyle(color: c.secondaryText, fontSize: 15),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 120),
      itemBuilder: (_, index) => EventCard(
        event: events[index],
        onTap: () => _openDetails(events[index]),
      ),
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemCount: events.length,
    );
  }
}

class EventCard extends StatelessWidget {
  final NearbyEvent event;
  final VoidCallback? onTap;

  const EventCard({super.key, required this.event, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: c.divider.withOpacity(0.25)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 118,
                height: 118,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  image: event.coverImageUrl != null
                      ? DecorationImage(
                          image: NetworkImage(event.coverImageUrl!),
                          fit: BoxFit.cover,
                        )
                      : null,
                  gradient: event.coverImageUrl == null
                      ? const LinearGradient(
                          colors: [Color(0xFF141E30), Color(0xFF243B55)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                ),
                child: event.coverImageUrl == null
                    ? Center(
                        child: Text(
                          event.category,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: TextStyle(
                        color: c.primaryText,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    _MetaRow(
                      icon: Icons.calendar_today_outlined,
                      text: event.scheduleLabel,
                    ),
                    const SizedBox(height: 4),
                    _MetaRow(
                      icon: Icons.location_on_outlined,
                      text: event.locationText,
                    ),
                    const SizedBox(height: 4),
                    _MetaRow(
                      icon: Icons.near_me_rounded,
                      text: event.displayDistance,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: onTap,
                            icon: Icon(
                              event.isGoing ? Icons.check_circle : Icons.star_border,
                              size: 16,
                            ),
                            label: Text(
                              event.isGoing
                                  ? 'Going'
                                  : event.isInterested
                                  ? 'Interested'
                                  : 'Open',
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: c.outlineButtonFg,
                              side: BorderSide(color: c.outlineButtonBorder),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EventDetailScreen extends StatefulWidget {
  final String eventId;

  const EventDetailScreen({super.key, required this.eventId});

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  final DataService _dataService = DataService();
  NearbyEvent? _event;
  List<EventMember> _members = [];
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final results = await Future.wait([
      _dataService.getEventById(widget.eventId),
      _dataService.getEventMembers(widget.eventId),
    ]);
    if (!mounted) return;
    setState(() {
      _event = results[0] as NearbyEvent?;
      _members = results[1] as List<EventMember>;
      _isLoading = false;
    });
  }

  Future<void> _updateRsvp(String status) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    final ok = await _dataService.setEventRsvp(eventId: widget.eventId, status: status);
    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      await _load();
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _deleteEvent() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete event?'),
        content: const Text('This will permanently remove the event for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final ok = await _dataService.deleteEvent(widget.eventId);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    if (_isLoading) {
      return Scaffold(
        backgroundColor: c.scaffold,
        body: Center(child: CircularProgressIndicator(color: c.accent)),
      );
    }
    final event = _event;
    if (event == null) {
      return Scaffold(
        backgroundColor: c.scaffold,
        appBar: AppBar(backgroundColor: c.scaffold),
        body: Center(
          child: Text('Event not found', style: TextStyle(color: c.secondaryText)),
        ),
      );
    }

    final admins = _members
        .where((m) => m.role == 'organizer' || m.role == 'admin')
        .toList();

    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: c.scaffold,
        title: const Text('Event Details'),
        actions: [
          if (event.isAdmin)
            IconButton(
              onPressed: () async {
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CreateEventScreen(existingEvent: event),
                  ),
                );
                if (changed == true) {
                  await _load();
                }
              },
              icon: const Icon(Icons.edit_outlined),
            ),
          if (event.isOrganizer)
            IconButton(
              onPressed: _deleteEvent,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: c.accent,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Container(
              height: 220,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                image: event.coverImageUrl != null
                    ? DecorationImage(
                        image: NetworkImage(event.coverImageUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
                gradient: event.coverImageUrl == null
                    ? const LinearGradient(
                        colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
              ),
              child: event.coverImageUrl == null
                  ? Center(
                      child: Text(
                        event.category,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 18),
            Text(
              event.title,
              style: TextStyle(
                color: c.primaryText,
                fontSize: 28,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              event.description?.trim().isNotEmpty == true
                  ? event.description!
                  : 'No description added yet.',
              style: TextStyle(color: c.secondaryText, height: 1.45),
            ),
            const SizedBox(height: 18),
            _detailTile(c, Icons.calendar_month_outlined, 'Starts', event.scheduleLabel),
            _detailTile(c, Icons.location_on_outlined, 'Exact location', event.locationText),
            _detailTile(c, Icons.people_alt_outlined, 'Guests', '${event.attendeeCount} interested / going'),
            _detailTile(c, Icons.person_outline, 'Host', event.creatorLabel),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isSaving ? null : () => _updateRsvp('interested'),
                    icon: const Icon(Icons.star_border),
                    label: const Text('Interested'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: event.myRsvpStatus == 'interested'
                          ? c.filledButtonBg
                          : c.secondaryButtonBg,
                      foregroundColor: event.myRsvpStatus == 'interested'
                          ? c.filledButtonFg
                          : c.secondaryButtonFg,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isSaving ? null : () => _updateRsvp('going'),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Going'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: event.myRsvpStatus == 'going'
                          ? c.filledButtonBg
                          : c.secondaryButtonBg,
                      foregroundColor: event.myRsvpStatus == 'going'
                          ? c.filledButtonFg
                          : c.secondaryButtonFg,
                    ),
                  ),
                ),
              ],
            ),
            if (event.isAdmin) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () async {
                  final changed = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EventMembersScreen(
                        event: event,
                        members: _members,
                      ),
                    ),
                  );
                  if (changed == true) {
                    await _load();
                  }
                },
                icon: const Icon(Icons.manage_accounts_outlined),
                label: const Text('Manage Event Team'),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              'Organizers & admins',
              style: TextStyle(
                color: c.primaryText,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            ...admins.map(
              (member) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundImage: member.user.avatarUrl != null
                      ? NetworkImage(member.user.avatarUrl!)
                      : const NetworkImage('https://i.pravatar.cc/150'),
                ),
                title: Text(
                  member.user.displayName ?? member.user.username ?? 'Member',
                  style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  member.role == 'organizer' ? 'Owner' : 'Admin',
                  style: TextStyle(color: c.secondaryText),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailTile(ColonyColors c, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: c.pillBackground,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: c.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: c.secondaryText, fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EventMembersScreen extends StatefulWidget {
  final NearbyEvent event;
  final List<EventMember> members;

  const EventMembersScreen({
    super.key,
    required this.event,
    required this.members,
  });

  @override
  State<EventMembersScreen> createState() => _EventMembersScreenState();
}

class _EventMembersScreenState extends State<EventMembersScreen> {
  final DataService _dataService = DataService();
  late List<EventMember> _members;

  @override
  void initState() {
    super.initState();
    _members = List<EventMember>.from(widget.members);
  }

  Future<void> _reload() async {
    final members = await _dataService.getEventMembers(widget.event.id);
    if (!mounted) return;
    setState(() => _members = members);
  }

  Future<void> _changeRole(EventMember member, String role) async {
    final ok = await _dataService.updateEventMemberRole(memberId: member.id, role: role);
    if (!mounted) return;
    if (ok) {
      await _reload();
      Navigator.pop(context, true);
    }
  }

  Future<void> _remove(EventMember member) async {
    final ok = await _dataService.removeEventMember(member.id);
    if (!mounted) return;
    if (ok) {
      await _reload();
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    final canPromote = widget.event.isOrganizer;
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: c.scaffold,
        title: const Text('Manage Event Team'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemBuilder: (_, index) {
          final member = _members[index];
          final roleColor = member.role == 'organizer'
              ? Colors.orange
              : member.role == 'admin'
              ? Colors.blue
              : c.secondaryText;
          return ListTile(
            tileColor: c.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: CircleAvatar(
              backgroundImage: member.user.avatarUrl != null
                  ? NetworkImage(member.user.avatarUrl!)
                  : const NetworkImage('https://i.pravatar.cc/150'),
            ),
            title: Text(
              member.user.displayName ?? member.user.username ?? 'Member',
              style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              '${member.role.toUpperCase()} • ${member.rsvpStatus.toUpperCase()}',
              style: TextStyle(color: roleColor),
            ),
            trailing: member.role == 'organizer'
                ? null
                : PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'admin' || value == 'attendee') {
                        _changeRole(member, value);
                      } else if (value == 'remove') {
                        _remove(member);
                      }
                    },
                    itemBuilder: (_) => [
                      if (canPromote && member.role != 'admin')
                        const PopupMenuItem(value: 'admin', child: Text('Make Admin')),
                      if (canPromote && member.role != 'attendee')
                        const PopupMenuItem(value: 'attendee', child: Text('Make Attendee')),
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemCount: _members.length,
      ),
    );
  }
}

class CreateEventScreen extends StatefulWidget {
  final NearbyEvent? existingEvent;

  const CreateEventScreen({super.key, this.existingEvent});

  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends State<CreateEventScreen> {
  final DataService _dataService = DataService();
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _capacityController = TextEditingController();
  final List<String> _categories = const [
    'MEETUP',
    'MUSIC',
    'SPORTS',
    'TECH',
    'FOOD',
    'ART',
  ];

  String _selectedCategory = 'MEETUP';
  bool _isSaving = false;
  bool _isUploading = false;
  String? _coverImageUrl;
  String? _locationText;
  double? _latitude;
  double? _longitude;
  DateTime? _startsAt;
  DateTime? _endsAt;

  bool get _isEditing => widget.existingEvent != null;

  @override
  void initState() {
    super.initState();
    final event = widget.existingEvent;
    if (event != null) {
      _titleController.text = event.title;
      _descriptionController.text = event.description ?? '';
      _capacityController.text = event.maxAttendees?.toString() ?? '';
      _selectedCategory = event.category;
      _coverImageUrl = event.coverImageUrl;
      _locationText = event.locationText;
      _latitude = event.latitude;
      _longitude = event.longitude;
      _startsAt = event.startsAt;
      _endsAt = event.endsAt;
    } else {
      _startsAt = DateTime.now().add(const Duration(hours: 2));
    }
    _loadLocationIfNeeded();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _capacityController.dispose();
    super.dispose();
  }

  Future<void> _loadLocationIfNeeded() async {
    if (_latitude != null && _longitude != null && _locationText != null) return;
    final result = await LocationService().fetchAndUpdateLocation();
    if (!mounted) return;
    if (result.success) {
      setState(() {
        _latitude = result.latitude;
        _longitude = result.longitude;
        _locationText = result.locationText;
      });
    }
  }

  Future<void> _pickCover() async {
    final xfile = await _picker.pickImage(source: ImageSource.gallery);
    if (xfile == null || !mounted) return;
    setState(() => _isUploading = true);
    try {
      final url = await StorageService().uploadEventCover(xfile);
      if (!mounted) return;
      setState(() => _coverImageUrl = url);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _pickStartDateTime() async {
    final base = _startsAt ?? DateTime.now().add(const Duration(hours: 2));
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _startsAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      if (_endsAt != null && _endsAt!.isBefore(_startsAt!)) {
        _endsAt = _startsAt!.add(const Duration(hours: 2));
      }
    });
  }

  Future<void> _pickEndDateTime() async {
    final base = _endsAt ?? (_startsAt?.add(const Duration(hours: 2)) ?? DateTime.now().add(const Duration(hours: 4)));
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: _startsAt ?? DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _endsAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    if (_isSaving ||
        _titleController.text.trim().isEmpty ||
        _startsAt == null ||
        _latitude == null ||
        _longitude == null ||
        (_locationText?.trim().isEmpty ?? true)) {
      return;
    }

    setState(() => _isSaving = true);
    final maxAttendees = int.tryParse(_capacityController.text.trim());
    final ok = _isEditing
        ? await _dataService.updateEvent(
            eventId: widget.existingEvent!.id,
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            category: _selectedCategory,
            coverImageUrl: _coverImageUrl,
            startsAt: _startsAt!,
            endsAt: _endsAt,
            locationText: _locationText!.trim(),
            latitude: _latitude!,
            longitude: _longitude!,
            maxAttendees: maxAttendees,
          )
        : await _dataService.createEvent(
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            category: _selectedCategory,
            coverImageUrl: _coverImageUrl,
            startsAt: _startsAt!,
            endsAt: _endsAt,
            locationText: _locationText!.trim(),
            latitude: _latitude!,
            longitude: _longitude!,
            maxAttendees: maxAttendees,
          );
    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: c.scaffold,
        title: Text(_isEditing ? 'Edit Event' : 'Create Event'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            children: [
              GestureDetector(
                onTap: _isUploading ? null : _pickCover,
                child: Container(
                  height: 170,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: c.card,
                    borderRadius: BorderRadius.circular(18),
                    image: _coverImageUrl != null
                        ? DecorationImage(
                            image: NetworkImage(_coverImageUrl!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: _isUploading
                      ? Center(child: CircularProgressIndicator(color: c.accent))
                      : _coverImageUrl == null
                      ? Center(
                          child: Text(
                            'Tap to add event cover',
                            style: TextStyle(color: c.secondaryText),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Event title',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descriptionController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: _selectedCategory,
                items: _categories
                    .map((item) => DropdownMenuItem(value: item, child: Text(item)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedCategory = value);
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _capacityController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max attendees (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              ListTile(
                tileColor: c.card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                leading: Icon(Icons.schedule, color: c.accent),
                title: Text(
                  _startsAt == null ? 'Choose start time' : _formatDateTime(_startsAt!),
                ),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickStartDateTime,
              ),
              const SizedBox(height: 10),
              ListTile(
                tileColor: c.card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                leading: Icon(Icons.timelapse, color: c.accent),
                title: Text(
                  _endsAt == null ? 'Choose end time (optional)' : _formatDateTime(_endsAt!),
                ),
                trailing: const Icon(Icons.update_outlined),
                onTap: _pickEndDateTime,
              ),
              const SizedBox(height: 10),
              ListTile(
                tileColor: c.card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                leading: Icon(Icons.place_outlined, color: c.accent),
                title: Text(_locationText ?? 'Fetching exact location...'),
                subtitle: Text(
                  'This exact location will be shown on the nearby event card.',
                  style: TextStyle(color: c.secondaryText, fontSize: 12),
                ),
                trailing: IconButton(
                  onPressed: _loadLocationIfNeeded,
                  icon: const Icon(Icons.my_location),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _save,
                  child: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isEditing ? 'Save Changes' : 'Create Event'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final year = value.year;
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final period = value.hour >= 12 ? 'PM' : 'AM';
    return '$day/$month/$year  $hour:$minute $period';
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: c.iconMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: c.secondaryText, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
