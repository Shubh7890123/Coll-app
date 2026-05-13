import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'config.dart';
import 'supabase_service.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  final _eventController = StreamController<SocketEvent>.broadcast();

  Stream<SocketEvent> get events => _eventController.stream;
  bool get isConnected => _socket?.connected == true;

  Future<void> connect() async {
    final user = SupabaseService().client.auth.currentUser;
    if (user == null) return;
    if (_socket?.connected == true) return;

    _socket?.dispose();
    _socket = io.io(
      Config.backendUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    _socket!
      ..onConnect((_) {
        emit('presence:register', {'userId': user.id});
        emit('notifications:join', {'userId': user.id});
      })
      ..onAny((event, data) {
        if (data is Map) {
          _eventController.add(
            SocketEvent(event, Map<String, dynamic>.from(data)),
          );
        }
      });
  }

  void emit(String event, Map<String, dynamic> payload) {
    _socket?.emit(event, payload);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}

class SocketEvent {
  final String name;
  final Map<String, dynamic> data;

  SocketEvent(this.name, this.data);
}
