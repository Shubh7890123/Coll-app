import 'dart:async';
import 'dart:io';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'storage_service.dart';

/// Service for recording and playing voice messages
class VoiceService {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal();

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  String? _currentRecordingPath;
  String? _currentlyPlayingUrl;

  // Stream controllers for UI updates
  final StreamController<RecordingState> _recordingStateController =
      StreamController<RecordingState>.broadcast();
  final StreamController<PlaybackState> _playbackStateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<Duration> _recordingDurationController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _playbackPositionController =
      StreamController<Duration>.broadcast();

  Stream<RecordingState> get recordingState => _recordingStateController.stream;
  Stream<PlaybackState> get playbackState => _playbackStateController.stream;
  Stream<Duration> get recordingDuration => _recordingDurationController.stream;
  Stream<Duration> get playbackPosition => _playbackPositionController.stream;

  Timer? _recordingTimer;
  Duration _currentRecordingDuration = Duration.zero;

  bool _isRecording = false;
  bool get isRecording => _isRecording;
  bool get isPlaying => _player.state == PlayerState.playing;
  String? get currentlyPlayingUrl => _currentlyPlayingUrl;

  /// Initialize the service
  Future<void> initialize() async {
    // Listen to player state changes
    _player.onPlayerStateChanged.listen((state) {
      _playbackStateController.add(
        state == PlayerState.playing
            ? PlaybackState.playing
            : state == PlayerState.paused
            ? PlaybackState.paused
            : PlaybackState.stopped,
      );
    });

    // Listen to position changes
    _player.onPositionChanged.listen((position) {
      _playbackPositionController.add(position);
    });

    // Listen to duration changes
    _player.onDurationChanged.listen((duration) {
      // Duration updated
    });

    // Listen to completion
    _player.onPlayerComplete.listen((_) {
      _currentlyPlayingUrl = null;
      _playbackStateController.add(PlaybackState.completed);
    });
  }

  /// Start recording voice message
  Future<bool> startRecording() async {
    try {
      // Check permission
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        print('Microphone permission denied');
        return false;
      }

      // Get temp directory
      final tempDir = await getTemporaryDirectory();
      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _currentRecordingPath = path.join(tempDir.path, fileName);

      // Start recording
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _currentRecordingPath!,
      );

      _recordingStateController.add(RecordingState.recording);

      // Start duration timer
      _currentRecordingDuration = Duration.zero;
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _currentRecordingDuration += const Duration(seconds: 1);
        _recordingDurationController.add(_currentRecordingDuration);
      });

      return true;
    } catch (e) {
      print('Error starting recording: $e');
      return false;
    }
  }

  /// Stop recording and return the file
  Future<VoiceRecordingResult?> stopRecording() async {
    try {
      _recordingTimer?.cancel();

      final path = await _recorder.stop();
      _recordingStateController.add(RecordingState.stopped);

      if (path == null) return null;

      final file = File(path);
      final exists = await file.exists();
      if (!exists) return null;

      final fileSize = await file.length();
      final duration = _currentRecordingDuration;

      return VoiceRecordingResult(
        filePath: path,
        duration: duration,
        fileSize: fileSize,
      );
    } catch (e) {
      print('Error stopping recording: $e');
      return null;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    try {
      _recordingTimer?.cancel();
      await _recorder.stop();
      _recordingStateController.add(RecordingState.cancelled);

      // Delete temp file
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      print('Error cancelling recording: $e');
    }
  }

  /// Play voice message from URL
  Future<bool> playVoiceMessage(String url) async {
    try {
      // If playing same message, toggle pause/play
      if (_currentlyPlayingUrl == url && _player.state == PlayerState.playing) {
        await pausePlayback();
        return true;
      }

      // If paused same message, resume
      if (_currentlyPlayingUrl == url && _player.state == PlayerState.paused) {
        await resumePlayback();
        return true;
      }

      // Stop current playback
      await stopPlayback();

      // Play new message
      _currentlyPlayingUrl = url;
      await _player.play(UrlSource(url));
      _playbackStateController.add(PlaybackState.playing);

      return true;
    } catch (e) {
      print('Error playing voice message: $e');
      return false;
    }
  }

  /// Play voice message from file path (for local preview)
  Future<bool> playLocalVoiceMessage(String filePath) async {
    try {
      if (_player.state == PlayerState.playing) {
        await pausePlayback();
        return true;
      }

      if (_player.state == PlayerState.paused &&
          _currentlyPlayingUrl == filePath) {
        await resumePlayback();
        return true;
      }

      await stopPlayback();

      _currentlyPlayingUrl = filePath;
      await _player.play(DeviceFileSource(filePath));
      _playbackStateController.add(PlaybackState.playing);

      return true;
    } catch (e) {
      print('Error playing local voice: $e');
      return false;
    }
  }

  /// Pause playback
  Future<void> pausePlayback() async {
    await _player.pause();
    _playbackStateController.add(PlaybackState.paused);
  }

  /// Resume playback
  Future<void> resumePlayback() async {
    await _player.resume();
    _playbackStateController.add(PlaybackState.playing);
  }

  /// Stop playback
  Future<void> stopPlayback() async {
    await _player.stop();
    _currentlyPlayingUrl = null;
    _playbackStateController.add(PlaybackState.stopped);
  }

  /// Seek to position
  Future<void> seekTo(Duration position) async {
    await _player.seek(position);
  }

  /// Get duration of audio file
  Future<Duration?> getDuration(String url) async {
    try {
      // For remote URLs, we need to play briefly to get duration
      // This is a workaround - in production, store duration in database
      return await _player.getDuration();
    } catch (e) {
      print('Error getting duration: $e');
      return null;
    }
  }

  /// Upload voice message to storage
  Future<String?> uploadVoiceMessage(
    String filePath,
    String conversationId,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final path = 'chat_media/$conversationId/voice/$fileName';

      final url = await StorageService().uploadFileFromPath(
        filePath: filePath,
        bucket: 'chat-media',
        storagePath: path,
      );

      return url;
    } catch (e) {
      print('Error uploading voice: $e');
      return null;
    }
  }

  /// Delete temp recording file
  Future<void> deleteTempRecording() async {
    try {
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
        _currentRecordingPath = null;
      }
    } catch (e) {
      print('Error deleting temp recording: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _recordingTimer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _recordingStateController.close();
    _playbackStateController.close();
    _recordingDurationController.close();
    _playbackPositionController.close();
  }
}

/// Recording states
enum RecordingState { idle, recording, stopped, cancelled }

/// Playback states
enum PlaybackState { idle, playing, paused, stopped, completed }

/// Result of voice recording
class VoiceRecordingResult {
  final String filePath;
  final Duration duration;
  final int fileSize;

  VoiceRecordingResult({
    required this.filePath,
    required this.duration,
    required this.fileSize,
  });

  String get formattedDuration {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get fileSizeFormatted {
    if (fileSize < 1024) return '${fileSize}B';
    if (fileSize < 1024 * 1024)
      return '${(fileSize / 1024).toStringAsFixed(1)}KB';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
