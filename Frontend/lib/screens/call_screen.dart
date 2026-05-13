import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../call_service.dart';

/// Full-screen call UI for voice/video calls (WhatsApp/Telegram style)
class CallScreen extends StatefulWidget {
  final String conversationId;
  final String? callId;
  final String recipientId;
  final String recipientName;
  final String? recipientAvatar;
  final bool isVideo;
  final bool isIncoming;

  const CallScreen({
    super.key,
    required this.conversationId,
    this.callId,
    required this.recipientId,
    required this.recipientName,
    this.recipientAvatar,
    required this.isVideo,
    this.isIncoming = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final CallService _callService = CallService();

  CallState _callState = CallState.idle;
  Duration _duration = Duration.zero;
  bool _isMuted = false;
  bool _isCameraOff = false;

  StreamSubscription<CallState>? _callStateSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _cameraStateSub;
  StreamSubscription<bool>? _muteStateSub;

  @override
  void initState() {
    super.initState();
    _initListeners();
  }

  void _initListeners() {
    // Listen to call state
    _callStateSub = _callService.callState.listen((state) {
      if (mounted) {
        setState(() {
          _callState = state;
        });
        if (state == CallState.ended ||
            state == CallState.rejected ||
            state == CallState.error) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) Navigator.of(context).pop();
          });
        }
      }
    });

    // Listen to duration
    _durationSub = _callService.callDuration.listen((dur) {
      if (mounted) {
        setState(() {
          _duration = dur;
        });
      }
    });

    // Listen to camera state
    _cameraStateSub = _callService.cameraState.listen((enabled) {
      if (mounted) {
        setState(() {
          _isCameraOff = !enabled;
        });
      }
    });

    // Listen to mute state
    _muteStateSub = _callService.muteState.listen((muted) {
      if (mounted) {
        setState(() {
          _isMuted = muted;
        });
      }
    });

    if (widget.isIncoming) {
      setState(() {
        _callState = CallState.ringing;
      });
      if (widget.callId != null) {
        _callService.loadIncomingCall(widget.callId!);
      }
    } else {
      _startCall();
    }
  }

  Future<void> _startCall() async {
    final success = await _callService.startCall(
      conversationId: widget.conversationId,
      recipientId: widget.recipientId,
      isVideo: widget.isVideo,
      callerName: widget.recipientName,
    );
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to start call')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _acceptCall() async {
    final success = await _callService.acceptCall();
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to accept call')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _rejectCall() async {
    await _callService.rejectCall();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _endCall() async {
    if (_callState == CallState.dialing) {
      await _callService.cancelCall();
    } else {
      await _callService.endCall();
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _toggleMute() {
    _callService.toggleMute();
  }

  void _toggleCamera() {
    _callService.toggleCamera();
  }

  String get _statusText {
    switch (_callState) {
      case CallState.dialing:
        return 'Calling...';
      case CallState.ringing:
        return 'Incoming call';
      case CallState.connecting:
        return 'Connecting...';
      case CallState.connected:
        return _formatDuration(_duration);
      case CallState.ended:
        return 'Call ended';
      case CallState.rejected:
        return 'Call rejected';
      case CallState.cancelled:
        return 'Call cancelled';
      case CallState.missed:
        return 'Missed call';
      case CallState.busy:
        return 'User is busy';
      case CallState.permissionDenied:
        return 'Permission denied';
      case CallState.error:
        return 'Call failed';
      default:
        return '';
    }
  }

  String _formatDuration(Duration dur) {
    final m = dur.inMinutes.toString().padLeft(2, '0');
    final s = (dur.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _callStateSub?.cancel();
    _durationSub?.cancel();
    _cameraStateSub?.cancel();
    _muteStateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video or background layer
            if (widget.isVideo && _callState == CallState.connected)
              _buildVideoCallView()
            else
              _buildBackground(),

            // Overlay content
            _buildOverlayContent(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCallView() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Remote video (main view)
        Container(
          color: Colors.black,
          child: _isCameraOff && _callService.currentState == CallState.dialing
              ? _buildLocalVideo()
              : RTCVideoView(
                  _callService.remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
        ),

        // Local video (picture-in-picture)
        Positioned(
          right: 20,
          top: 100,
          child: Container(
            width: 120,
            height: 160,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _buildLocalVideo(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocalVideo() {
    return Container(
      color: Colors.grey[900],
      child: RTCVideoView(
        _callService.localRenderer,
        mirror: true,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      ),
    );
  }

  Widget _buildBackground() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF1B5A27).withOpacity(0.8),
            Colors.black.withOpacity(0.9),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlayContent() {
    return Column(
      children: [
        const SizedBox(height: 60),

        // Avatar (only if not in video call with connected state)
        if (!widget.isVideo || _callState != CallState.connected)
          CircleAvatar(
            radius: 60,
            backgroundImage: widget.recipientAvatar != null
                ? NetworkImage(widget.recipientAvatar!)
                : const NetworkImage('https://i.pravatar.cc/150'),
          ),

        // Small spacer if no avatar
        if (widget.isVideo && _callState == CallState.connected)
          const SizedBox(height: 20),

        const SizedBox(height: 24),

        // Name
        Text(
          widget.recipientName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 12),

        // Status
        Text(
          _statusText,
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),

        const Spacer(),

        // Controls
        _buildControls(),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildControls() {
    // Incoming call state
    if (_callState == CallState.ringing && widget.isIncoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Decline button
          _callButton(
            icon: Icons.call_end,
            color: Colors.red,
            onPressed: _rejectCall,
            label: 'Decline',
          ),
          const SizedBox(width: 40),
          // Accept button
          _callButton(
            icon: widget.isVideo ? Icons.videocam : Icons.call,
            color: const Color(0xFF25D366),
            onPressed: _acceptCall,
            label: 'Accept',
          ),
        ],
      );
    }

    // Active call controls
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _callButton(
              icon: _isMuted ? Icons.mic_off : Icons.mic,
              color: _isMuted ? Colors.orange : Colors.white.withOpacity(0.3),
              onPressed: _toggleMute,
              label: 'Mute',
            ),
            const SizedBox(width: 24),
            if (widget.isVideo)
              _callButton(
                icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
                color: _isCameraOff
                    ? Colors.orange
                    : Colors.white.withOpacity(0.3),
                onPressed: _toggleCamera,
                label: 'Camera',
              ),
            if (widget.isVideo) const SizedBox(width: 24),
            if (widget.isVideo)
              _callButton(
                icon: Icons.switch_camera,
                color: Colors.white.withOpacity(0.3),
                onPressed: () => _callService.switchCamera(),
                label: 'Switch',
              ),
            if (widget.isVideo) const SizedBox(width: 24),
            _callButton(
              icon: Icons.volume_up,
              color: Colors.white.withOpacity(0.3),
              onPressed: () => _callService.toggleSpeaker(),
              label: 'Speaker',
            ),
          ],
        ),
        const SizedBox(height: 24),
        // End call button
        _callButton(
          icon: Icons.call_end,
          color: Colors.red,
          onPressed: _endCall,
          label: 'End',
          size: 70,
        ),
      ],
    );
  }

  Widget _callButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required String label,
    double size = 60,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12),
        ),
      ],
    );
  }
}
