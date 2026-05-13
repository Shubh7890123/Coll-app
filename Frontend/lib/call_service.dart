import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'config.dart';
import 'socket_service.dart';
import 'supabase_service.dart';

typedef IncomingCallCallback =
    void Function({
      required String callId,
      required String callerId,
      required String conversationId,
      required bool isVideo,
      required String callerName,
      String? callerAvatar,
    });

class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  final SocketService _socketService = SocketService();
  StreamSubscription<SocketEvent>? _socketSub;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  final _callStateController = StreamController<CallState>.broadcast();
  final _callDurationController = StreamController<Duration>.broadcast();
  final _cameraStateController = StreamController<bool>.broadcast();
  final _muteStateController = StreamController<bool>.broadcast();
  final _incomingCallController = StreamController<CallSession>.broadcast();

  Stream<CallState> get callState => _callStateController.stream;
  Stream<Duration> get callDuration => _callDurationController.stream;
  Stream<bool> get cameraState => _cameraStateController.stream;
  Stream<bool> get muteState => _muteStateController.stream;
  Stream<CallSession> get incomingCalls => _incomingCallController.stream;

  RTCVideoRenderer get localRenderer => _localRenderer;
  RTCVideoRenderer get remoteRenderer => _remoteRenderer;

  CallState _currentState = CallState.idle;
  CallState get currentState => _currentState;

  CallSession? _session;
  bool _isMuted = false;
  bool _isCameraEnabled = true;
  bool _isSpeakerOn = false;
  Timer? _callTimer;
  Duration _duration = Duration.zero;
  IncomingCallCallback? _incomingCallCallback;

  Map<String, dynamic>? _queuedOffer;

  Map<String, dynamic> get _iceServers => {
        'iceServers': [
          if (Config.twilioTurnUrl.isNotEmpty)
            {
              'urls': Config.twilioTurnUrl,
              if (Config.twilioTurnUsername.isNotEmpty)
                'username': Config.twilioTurnUsername,
              if (Config.twilioTurnCredential.isNotEmpty)
                'credential': Config.twilioTurnCredential,
            },
          {
            'urls': [
              'stun:stun.l.google.com:19302',
              'stun:stun1.l.google.com:19302',
            ],
          },
        ],
      };

  Future<void> initialize({IncomingCallCallback? onIncomingCall}) async {
    _incomingCallCallback = onIncomingCall;
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _socketService.connect();

    _socketSub?.cancel();
    _socketSub = _socketService.events.listen(_handleSocketEvent);
  }

  Future<bool> startCall({
    required String conversationId,
    required String recipientId,
    required bool isVideo,
    String? callerName,
  }) async {
    if (_currentState != CallState.idle) return false;
    if (!await _ensurePermissions(isVideo)) {
      _updateCallState(CallState.permissionDenied);
      return false;
    }

    try {
      await _socketService.connect();
      final response = await _post('/api/calls/start-call', {
        'receiverId': recipientId,
        'callType': isVideo ? 'video' : 'voice',
      });

      _session = CallSession.fromJson(
        Map<String, dynamic>.from(response['data'] as Map),
        fallbackConversationId: conversationId,
      );
      _updateCallState(CallState.dialing);
      return true;
    } catch (e) {
      _updateCallState(CallState.error);
      await _cleanup();
      return false;
    }
  }

  Future<void> loadIncomingCall(String callId) async {
    final response = await _get('/api/calls/$callId');
    _session = CallSession.fromCallRow(
      Map<String, dynamic>.from(response['data'] as Map),
    );
    _updateCallState(CallState.ringing);
  }

  Future<bool> acceptCall() async {
    if (_session == null) return false;
    if (!await _ensurePermissions(_session!.isVideo)) {
      _updateCallState(CallState.permissionDenied);
      return false;
    }

    try {
      await _preparePeerConnection();
      await _post('/api/calls/accept-call', {'callId': _session!.callId});
      _updateCallState(CallState.connecting);

      if (_queuedOffer != null) {
        final offer = _queuedOffer!;
        _queuedOffer = null;
        await _handleOffer(offer);
      }
      return true;
    } catch (e) {
      _updateCallState(CallState.error);
      return false;
    }
  }

  Future<void> rejectCall() async {
    final callId = _session?.callId;
    if (callId != null) {
      await _post('/api/calls/reject-call', {'callId': callId});
    }
    await _cleanup();
  }

  Future<void> cancelCall() async {
    final callId = _session?.callId;
    if (callId != null) {
      await _post('/api/calls/cancel-call', {'callId': callId});
    }
    await _cleanup();
  }

  Future<void> endCall() async {
    final callId = _session?.callId;
    if (callId != null) {
      await _post('/api/calls/end-call', {'callId': callId});
    }
    await _cleanup();
  }

  Future<List<CallHistoryItem>> getCallHistory({
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _get('/api/calls/history?limit=$limit&offset=$offset');
    final rows = (response['data'] as List? ?? const []);
    return rows
        .map((row) => CallHistoryItem.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  void _handleSocketEvent(SocketEvent event) {
    switch (event.name) {
      case 'incoming_call':
        _onIncomingCall(event.data);
        break;
      case 'call_accepted':
        _onCallAccepted(event.data);
        break;
      case 'call_rejected':
        _finishRemote(CallState.rejected);
        break;
      case 'call_cancelled':
        _finishRemote(CallState.cancelled);
        break;
      case 'call_missed':
        _finishRemote(CallState.missed);
        break;
      case 'call_ended':
        _finishRemote(CallState.ended);
        break;
      case 'call_busy':
        _finishRemote(CallState.busy);
        break;
      case 'call_offer':
        _handleOfferOrQueue(event.data);
        break;
      case 'call_answer':
        _handleAnswer(event.data);
        break;
      case 'ice_candidate':
        _handleIceCandidate(event.data);
        break;
    }
  }

  void _onIncomingCall(Map<String, dynamic> data) {
    _session = CallSession.fromJson(data);
    _updateCallState(CallState.ringing);
    _incomingCallController.add(_session!);
    _incomingCallCallback?.call(
      callId: _session!.callId,
      callerId: _session!.callerId,
      conversationId: _session!.conversationId,
      isVideo: _session!.isVideo,
      callerName: _session!.callerName,
      callerAvatar: _session!.callerImage,
    );
  }

  Future<void> _onCallAccepted(Map<String, dynamic> data) async {
    _session = CallSession.fromJson(data);
    _updateCallState(CallState.connecting);

    if (_session!.callerId == _currentUserId) {
      await _preparePeerConnection();
      await _createAndSendOffer();
    }
  }

  Future<void> _preparePeerConnection() async {
    if (_peerConnection != null) return;

    _peerConnection = await createPeerConnection(_iceServers);
    _peerConnection!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _updateCallState(CallState.connected);
        _startCallTimer();
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _updateCallState(CallState.error);
      }
    };
    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      }
    };
    _peerConnection!.onIceCandidate = (candidate) {
      final recipientId = _session?.otherUserId(_currentUserId);
      if (recipientId == null || candidate.candidate == null) return;
      _socketService.emit('ice_candidate', {
        'callId': _session!.callId,
        'senderId': _currentUserId,
        'recipientId': recipientId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': _session?.isVideo == true ? {'facingMode': 'user'} : false,
    });
    _localRenderer.srcObject = _localStream;
    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }
  }

  Future<void> _createAndSendOffer() async {
    final recipientId = _session?.receiverId;
    if (_peerConnection == null || recipientId == null) return;
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _socketService.emit('call_offer', {
      'callId': _session!.callId,
      'senderId': _currentUserId,
      'recipientId': recipientId,
      'sdp': offer.sdp,
      'sdpType': offer.type,
      'isVideo': _session!.isVideo,
    });
  }

  Future<void> _handleOfferOrQueue(Map<String, dynamic> data) async {
    if (_peerConnection == null) {
      _queuedOffer = data;
      return;
    }
    await _handleOffer(data);
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    await _preparePeerConnection();
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(data['sdp']?.toString(), data['sdpType']?.toString()),
    );
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);
    _socketService.emit('call_answer', {
      'callId': data['callId'],
      'senderId': _currentUserId,
      'recipientId': data['senderId'],
      'sdp': answer.sdp,
      'sdpType': answer.type,
    });
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    if (_peerConnection == null) return;
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(data['sdp']?.toString(), data['sdpType']?.toString()),
    );
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    if (_peerConnection == null || data['candidate'] == null) return;
    await _peerConnection!.addCandidate(
      RTCIceCandidate(
        data['candidate']?.toString(),
        data['sdpMid']?.toString(),
        (data['sdpMLineIndex'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  Future<bool> _ensurePermissions(bool isVideo) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;
    if (isVideo) {
      final camera = await Permission.camera.request();
      if (!camera.isGranted) return false;
    }
    return true;
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_isMuted;
    }
    _muteStateController.add(_isMuted);
  }

  Future<void> toggleCamera() async {
    _isCameraEnabled = !_isCameraEnabled;
    for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _isCameraEnabled;
    }
    _cameraStateController.add(_isCameraEnabled);
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? [];
    if (tracks.isNotEmpty) {
      await Helper.switchCamera(tracks.first);
    }
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await Helper.setSpeakerphoneOn(_isSpeakerOn);
  }

  bool get isSpeakerOn => _isSpeakerOn;

  void _finishRemote(CallState state) {
    _updateCallState(state);
    _cleanup();
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _duration = Duration.zero;
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _duration += const Duration(seconds: 1);
      _callDurationController.add(_duration);
    });
  }

  void _updateCallState(CallState state) {
    _currentState = state;
    _callStateController.add(state);
  }

  String get _currentUserId => SupabaseService().currentUser?.id ?? '';

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final token = SupabaseService().client.auth.currentSession?.accessToken;
    final response = await http.post(
      Uri.parse('${Config.backendUrl}$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw Exception(json['message'] ?? 'Call request failed');
    }
    return json;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final token = SupabaseService().client.auth.currentSession?.accessToken;
    final response = await http.get(
      Uri.parse('${Config.backendUrl}$path'),
      headers: {if (token != null) 'Authorization': 'Bearer $token'},
    );
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw Exception(json['message'] ?? 'Call request failed');
    }
    return json;
  }

  Future<void> _cleanup() async {
    _callTimer?.cancel();
    _callTimer = null;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    await _peerConnection?.close();
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localStream = null;
    _peerConnection = null;
    _queuedOffer = null;
    _session = null;
    _isMuted = false;
    _isCameraEnabled = true;
  }

  Future<void> dispose() async {
    await _cleanup();
    await _socketSub?.cancel();
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    await _callStateController.close();
    await _callDurationController.close();
    await _cameraStateController.close();
    await _muteStateController.close();
    await _incomingCallController.close();
  }
}

class CallSession {
  final String callId;
  final String callerId;
  final String receiverId;
  final String callerName;
  final String? callerImage;
  final String receiverName;
  final String? receiverImage;
  final String callType;
  final String status;
  final String conversationId;

  CallSession({
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.callerName,
    this.callerImage,
    required this.receiverName,
    this.receiverImage,
    required this.callType,
    required this.status,
    this.conversationId = '',
  });

  bool get isVideo => callType == 'video';

  String? otherUserId(String currentUserId) {
    if (callerId == currentUserId) return receiverId;
    if (receiverId == currentUserId) return callerId;
    return null;
  }

  factory CallSession.fromJson(
    Map<String, dynamic> json, {
    String fallbackConversationId = '',
  }) {
    return CallSession(
      callId: json['callId']?.toString() ?? json['id']?.toString() ?? '',
      callerId: json['callerId']?.toString() ?? json['caller_id']?.toString() ?? '',
      receiverId: json['receiverId']?.toString() ?? json['receiver_id']?.toString() ?? '',
      callerName: json['callerName']?.toString() ?? 'Someone',
      callerImage: json['callerImage']?.toString(),
      receiverName: json['receiverName']?.toString() ?? 'Someone',
      receiverImage: json['receiverImage']?.toString(),
      callType: json['callType']?.toString() ?? json['call_type']?.toString() ?? 'voice',
      status: json['status']?.toString() ?? 'ringing',
      conversationId: json['conversationId']?.toString() ?? fallbackConversationId,
    );
  }

  factory CallSession.fromCallRow(Map<String, dynamic> row) {
    final caller = Map<String, dynamic>.from(row['caller'] as Map? ?? const {});
    final receiver = Map<String, dynamic>.from(row['receiver'] as Map? ?? const {});
    return CallSession(
      callId: row['id'].toString(),
      callerId: row['caller_id'].toString(),
      receiverId: row['receiver_id'].toString(),
      callerName: caller['display_name']?.toString() ?? caller['username']?.toString() ?? 'Someone',
      callerImage: caller['avatar_url']?.toString(),
      receiverName: receiver['display_name']?.toString() ?? receiver['username']?.toString() ?? 'Someone',
      receiverImage: receiver['avatar_url']?.toString(),
      callType: row['call_type']?.toString() ?? 'voice',
      status: row['status']?.toString() ?? 'ringing',
    );
  }
}

class CallHistoryItem {
  final String id;
  final String callType;
  final String status;
  final int duration;
  final DateTime createdAt;
  final String callerId;
  final String receiverId;
  final String callerName;
  final String receiverName;

  CallHistoryItem({
    required this.id,
    required this.callType,
    required this.status,
    required this.duration,
    required this.createdAt,
    required this.callerId,
    required this.receiverId,
    required this.callerName,
    required this.receiverName,
  });

  factory CallHistoryItem.fromJson(Map<String, dynamic> json) {
    final caller = Map<String, dynamic>.from(json['caller'] as Map? ?? const {});
    final receiver = Map<String, dynamic>.from(json['receiver'] as Map? ?? const {});
    return CallHistoryItem(
      id: json['id'].toString(),
      callType: json['call_type']?.toString() ?? 'voice',
      status: json['status']?.toString() ?? 'ended',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'].toString()),
      callerId: json['caller_id'].toString(),
      receiverId: json['receiver_id'].toString(),
      callerName: caller['display_name']?.toString() ?? caller['username']?.toString() ?? 'Caller',
      receiverName: receiver['display_name']?.toString() ?? receiver['username']?.toString() ?? 'Receiver',
    );
  }
}

enum CallState {
  idle,
  dialing,
  ringing,
  connecting,
  connected,
  disconnected,
  ended,
  error,
  rejected,
  cancelled,
  missed,
  busy,
  permissionDenied,
}

enum CallType { voice, video }
