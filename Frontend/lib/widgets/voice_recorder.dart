import 'package:flutter/material.dart';
import '../voice_service.dart';

/// Widget for recording voice messages
class VoiceRecorderWidget extends StatefulWidget {
  final Function(VoiceRecordingResult) onRecordingComplete;
  final VoidCallback onCancel;

  const VoiceRecorderWidget({
    super.key,
    required this.onRecordingComplete,
    required this.onCancel,
  });

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget>
    with SingleTickerProviderStateMixin {
  final VoiceService _voiceService = VoiceService();
  bool _isRecording = false;
  bool _isLocked = false;
  Duration _duration = Duration.zero;
  double _dragOffset = 0;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _voiceService.initialize();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RecordingState>(
      stream: _voiceService.recordingState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? RecordingState.idle;
        _isRecording = state == RecordingState.recording;

        return StreamBuilder<Duration>(
          stream: _voiceService.recordingDuration,
          builder: (context, durationSnapshot) {
            if (durationSnapshot.hasData) {
              _duration = durationSnapshot.data!;
            }

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isRecording
                    ? Colors.red.withOpacity(0.1)
                    : Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  // Recording indicator or mic button
                  _buildRecordingIndicator(),
                  const SizedBox(width: 12),
                  // Duration text
                  Expanded(
                    child: _isRecording
                        ? Text(
                            _formatDuration(_duration),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                        : const Text(
                            'Hold to record',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                  ),
                  // Cancel or send buttons
                  if (_isRecording) ...[
                    _buildCancelButton(),
                    const SizedBox(width: 8),
                    _buildSendButton(),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRecordingIndicator() {
    if (!_isRecording) {
      return GestureDetector(
        onLongPressStart: (_) => _startRecording(),
        onLongPressEnd: (_) => _stopRecording(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mic, color: Colors.white, size: 24),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.red.withOpacity(0.3 * _pulseController.value),
                blurRadius: 20 * _pulseController.value,
                spreadRadius: 5 * _pulseController.value,
              ),
            ],
          ),
          child: const Icon(Icons.mic, color: Colors.white, size: 24),
        );
      },
    );
  }

  Widget _buildCancelButton() {
    return GestureDetector(
      onTap: _cancelRecording,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
      ),
    );
  }

  Widget _buildSendButton() {
    return GestureDetector(
      onTap: _stopRecording,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.send, color: Colors.white, size: 20),
      ),
    );
  }

  Future<void> _startRecording() async {
    final success = await _voiceService.startRecording();
    if (success) {
      setState(() {});
    }
  }

  Future<void> _stopRecording() async {
    final result = await _voiceService.stopRecording();
    if (result != null) {
      widget.onRecordingComplete(result);
    }
  }

  Future<void> _cancelRecording() async {
    await _voiceService.cancelRecording();
    widget.onCancel();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Widget for displaying and playing voice messages
class VoiceMessagePlayer extends StatefulWidget {
  final String voiceUrl;
  final int? duration;
  final bool isMe;

  const VoiceMessagePlayer({
    super.key,
    required this.voiceUrl,
    this.duration,
    required this.isMe,
  });

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  final VoiceService _voiceService = VoiceService();
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _totalDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _voiceService.initialize();
    _totalDuration = Duration(seconds: widget.duration ?? 0);

    // Listen to playback state
    _voiceService.playbackState.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlaybackState.playing;
        });
      }
    });

    // Listen to position
    _voiceService.playbackPosition.listen((position) {
      if (mounted) {
        setState(() {
          _position = position;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: widget.isMe
            ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
            : Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // Play/Pause button
          GestureDetector(
            onTap: _togglePlayback,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: widget.isMe
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey[300],
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: widget.isMe ? Colors.white : Colors.grey[700],
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Waveform and progress
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Waveform visualization
                SizedBox(
                  height: 24,
                  child: CustomPaint(
                    size: const Size(double.infinity, 24),
                    painter: WaveformPainter(
                      progress: _totalDuration.inSeconds > 0
                          ? _position.inSeconds / _totalDuration.inSeconds
                          : 0,
                      color: widget.isMe
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Duration text
                Text(
                  '${_formatDuration(_position)} / ${_formatDuration(_totalDuration)}',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _voiceService.pausePlayback();
    } else {
      await _voiceService.playVoiceMessage(widget.voiceUrl);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Custom painter for waveform visualization
class WaveformPainter extends CustomPainter {
  final double progress;
  final Color color;

  WaveformPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = 3.0;
    final gap = 2.0;
    final barCount = (size.width / (barWidth + gap)).floor();

    final activeBars = (barCount * progress).floor();

    for (int i = 0; i < barCount; i++) {
      final x = i * (barWidth + gap);
      final isActive = i < activeBars;
      final barHeight = 8 + (i % 3) * 4.0;

      final paint = Paint()
        ..color = isActive ? color : color.withOpacity(0.3)
        ..style = PaintingStyle.fill;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - barHeight) / 2, barWidth, barHeight),
        const Radius.circular(2),
      );

      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
