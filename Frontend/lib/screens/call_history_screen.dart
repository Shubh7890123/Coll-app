import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../call_service.dart';
import '../colony_theme.dart';

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  final CallService _callService = CallService();
  List<CallHistoryItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final items = await _callService.getCallHistory();
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ColonyColors.of(context);
    return Scaffold(
      backgroundColor: c.scaffold,
      appBar: AppBar(
        backgroundColor: c.scaffold,
        elevation: 0,
        title: Text(
          'Call History',
          style: TextStyle(color: c.primaryText, fontWeight: FontWeight.bold),
        ),
        iconTheme: IconThemeData(color: c.primaryText),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 160),
                        Icon(Icons.call_outlined, size: 72, color: c.secondaryText),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            'No calls yet',
                            style: TextStyle(
                              color: c.primaryText,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemBuilder: (_, index) => _buildItem(_items[index], c),
                      separatorBuilder: (_, __) => Divider(color: c.divider),
                      itemCount: _items.length,
                    ),
            ),
    );
  }

  Widget _buildItem(CallHistoryItem item, ColonyColors c) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final outgoing = item.callerId == currentUserId;
    final peerName = outgoing ? item.receiverName : item.callerName;
    final missed = item.status == 'missed';
    final icon = item.callType == 'video' ? Icons.videocam : Icons.call;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: missed
            ? Colors.red.withValues(alpha: 0.12)
            : c.accent.withValues(alpha: 0.12),
        child: Icon(
          icon,
          color: missed ? Colors.red : c.accent,
        ),
      ),
      title: Text(
        peerName,
        style: TextStyle(
          color: missed ? Colors.red : c.primaryText,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        '${outgoing ? 'Outgoing' : 'Incoming'} ${item.callType} • ${_statusText(item)}',
        style: TextStyle(color: c.secondaryText),
      ),
      trailing: Text(
        _timeAgo(item.createdAt),
        style: TextStyle(color: c.secondaryText, fontSize: 12),
      ),
    );
  }

  String _statusText(CallHistoryItem item) {
    if (item.status == 'ended') return _formatDuration(item.duration);
    return item.status;
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inDays > 0) return '${diff.inDays}d';
    if (diff.inHours > 0) return '${diff.inHours}h';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return 'now';
  }
}
