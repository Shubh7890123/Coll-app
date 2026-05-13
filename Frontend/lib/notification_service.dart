import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'device_id_service.dart';
import 'main.dart' show appNavigatorKey;
import 'screens/call_screen.dart';
import 'screens/call_history_screen.dart';
import 'screens/chat_detail_screen.dart';
import 'screens/group_chat_screen.dart';
import 'screens/notifications_screen.dart';
import 'supabase_service.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('Handling background message: ${message.messageId}');
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final DeviceIdService _deviceIdService = DeviceIdService();

  SupabaseClient get _client => SupabaseService().client;

  bool _initialized = false;
  StreamSubscription<String>? _tokenRefreshSubscription;
  String? _lastSavedToken;
  String? _lastSavedUserId;

  Future<void> initialize() async {
    if (_initialized) return;

    if (Firebase.apps.isEmpty) {
      debugPrint('Firebase must be initialized before NotificationService');
      return;
    }

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await _initLocalNotifications();
    await _requestPermissions();
    _setupMessageListeners();

    _initialized = true;

    if (_client.auth.currentUser != null) {
      await _saveFcmToken();
    }
  }

  Future<void> onUserAuthenticated() async {
    await _saveFcmToken();
  }

  Future<void> onUserSignedOut() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;

      final deviceId = await _safeDeviceId();
      await _client
          .from('user_device_tokens')
          .delete()
          .eq('user_id', user.id)
          .eq('device_id', deviceId);
      _lastSavedToken = null;
      _lastSavedUserId = null;
    } catch (e) {
      debugPrint('Error removing FCM token on sign out: $e');
    }
  }

  Future<String> _safeDeviceId() async {
    try {
      return await _deviceIdService.getDeviceId();
    } catch (_) {
      final token = await _messaging.getToken();
      final prefix = Platform.isAndroid
          ? 'android'
          : (Platform.isIOS ? 'ios' : 'device');
      if (token == null || token.isEmpty) {
        return '$prefix-unknown';
      }
      return '$prefix-${token.substring(0, min(token.length, 24))}';
    }
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    const channels = [
      AndroidNotificationChannel(
        'dm_messages',
        'Direct Messages',
        description: 'Direct message notifications',
        importance: Importance.high,
      ),
      AndroidNotificationChannel(
        'group_activity',
        'Group Activity',
        description: 'Group chat and mention notifications',
        importance: Importance.high,
      ),
      AndroidNotificationChannel(
        'friend_activity',
        'Friend Activity',
        description: 'Friend request and acceptance notifications',
        importance: Importance.high,
      ),
      AndroidNotificationChannel(
        'calls',
        'Calls',
        description: 'Incoming audio and video calls',
        importance: Importance.max,
      ),
      AndroidNotificationChannel(
        'general',
        'General',
        description: 'General notifications',
        importance: Importance.high,
      ),
    ];

    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin != null) {
      for (final channel in channels) {
        await androidPlugin.createNotificationChannel(channel);
      }
    }

    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  }

  Future<void> _requestPermissions() async {
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> _saveFcmToken() async {
    try {
      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) return;

      await _saveFcmTokenToDatabase(token);
      _tokenRefreshSubscription ??= _messaging.onTokenRefresh.listen((
        refreshedToken,
      ) async {
        if (refreshedToken.isEmpty) return;
        await _saveFcmTokenToDatabase(refreshedToken);
      });
    } catch (e) {
      debugPrint('Error saving FCM token: $e');
    }
  }

  Future<void> _saveFcmTokenToDatabase(String token) async {
    final user = _client.auth.currentUser;
    if (user == null || token.isEmpty) return;

    final deviceType = Platform.isAndroid
        ? 'android'
        : (Platform.isIOS ? 'ios' : 'other');
    final deviceId = await _safeDeviceId();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final authToken = _client.auth.currentSession?.accessToken;

    if (_lastSavedToken == token && _lastSavedUserId == user.id) {
      return;
    }

    if (authToken != null && authToken.isNotEmpty) {
      try {
        final response = await http.post(
          Uri.parse('${Config.backendUrl}/api/notifications/device-tokens'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
          body: jsonEncode({
            'fcmToken': token,
            'deviceType': deviceType,
            'deviceId': deviceId,
          }),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          _lastSavedToken = token;
          _lastSavedUserId = user.id;
          return;
        }

        debugPrint(
          'Warning: Express backend rejected FCM token save '
          '(${response.statusCode}): ${response.body}',
        );
      } catch (e) {
        debugPrint('Warning: Could not save FCM token to Express backend: $e');
        // Fallback to Supabase direct insert below
      }
    }

    await _client.from('user_device_tokens').upsert({
      'user_id': user.id,
      'fcm_token': token,
      'device_type': deviceType,
      'device_id': deviceId,
      'last_seen_at': nowIso,
      'updated_at': nowIso,
      'invalidated_at': null,
    }, onConflict: 'user_id,device_id');

    _lastSavedToken = token;
    _lastSavedUserId = user.id;
  }

  void _setupMessageListeners() {
    FirebaseMessaging.onMessage.listen((message) {
      _handleMessage(message, isForeground: true);
    });

    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageTap);

    _messaging.getInitialMessage().then((message) {
      if (message != null) {
        _handleMessageTap(message);
      }
    });
  }

  void _handleMessage(RemoteMessage message, {required bool isForeground}) {
    if (!isForeground) return;

    final data = message.data;
    final notification = message.notification;
    final title = notification?.title ?? data['title'] ?? 'New Notification';
    final body = notification?.body ?? data['body'] ?? '';

    _showLocalNotification(
      title: title,
      body: body,
      type: data['type'] ?? 'system_alert',
      senderAvatar: data['sender_avatar'],
      senderName: data['sender_name'],
      data: data,
    );
  }

  Future<void> _showLocalNotification({
    required String title,
    required String body,
    required String type,
    String? senderAvatar,
    String? senderName,
    Map<String, dynamic>? data,
  }) async {
    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    AndroidBitmap<Object>? largeIconBitmap;

    if (senderAvatar != null && senderAvatar.isNotEmpty) {
      final bytes = await _downloadBitmap(senderAvatar);
      if (bytes != null) {
        largeIconBitmap = ByteArrayAndroidBitmap(bytes);
      }
    }

    final androidDetails = AndroidNotificationDetails(
      _getChannelId(type),
      _getChannelName(type),
      channelDescription: _getChannelDescription(type),
      importance: Importance.high,
      priority: Priority.high,
      largeIcon: largeIconBitmap,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: senderName,
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _localNotifications.show(
      id,
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: jsonEncode(data ?? const {}),
    );
  }

  Future<Uint8List?> _downloadBitmap(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint('Error downloading sender avatar: $e');
    }
    return null;
  }

  String _getChannelId(String type) {
    switch (type) {
      case 'dm_message':
        return 'dm_messages';
      case 'group_message':
      case 'mention':
      case 'group_invite':
        return 'group_activity';
      case 'friend_request':
      case 'friend_accept':
        return 'friend_activity';
      case 'audio_call':
      case 'voice_call':
      case 'video_call':
        return 'calls';
      default:
        return 'general';
    }
  }

  String _getChannelName(String type) {
    switch (type) {
      case 'dm_message':
        return 'Direct Messages';
      case 'group_message':
      case 'mention':
      case 'group_invite':
        return 'Group Activity';
      case 'friend_request':
      case 'friend_accept':
        return 'Friend Activity';
      case 'audio_call':
      case 'voice_call':
      case 'video_call':
        return 'Calls';
      default:
        return 'General';
    }
  }

  String _getChannelDescription(String type) {
    switch (type) {
      case 'dm_message':
        return 'Notifications for direct messages';
      case 'group_message':
      case 'mention':
      case 'group_invite':
        return 'Notifications for groups and mentions';
      case 'friend_request':
      case 'friend_accept':
        return 'Notifications for friend activity';
      case 'audio_call':
      case 'voice_call':
      case 'video_call':
        return 'Notifications for incoming calls';
      default:
        return 'General notifications';
    }
  }

  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      _handleNotificationTap(data);
    } catch (e) {
      debugPrint('Error parsing notification payload: $e');
    }
  }

  void _handleMessageTap(RemoteMessage message) {
    _handleNotificationTap(message.data);
  }

  void _handleNotificationTap(Map<String, dynamic> data) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    final type = data['type']?.toString();
    final chatId =
        data['chatId']?.toString() ??
        data['conversation_id']?.toString() ??
        data['conversationId']?.toString();
    final groupId = data['groupId']?.toString() ?? data['group_id']?.toString();
    final senderId =
        data['senderId']?.toString() ?? data['sender_id']?.toString();
    final senderName =
        data['sender_name']?.toString() ??
        data['callerName']?.toString() ??
        'User';
    final senderAvatar =
        data['sender_avatar']?.toString() ?? data['callerAvatar']?.toString();

    switch (type) {
      case 'dm_message':
      case 'friend_accept':
        if (chatId != null && senderId != null) {
          navigator.push(
            MaterialPageRoute(
              builder: (_) => ChatDetailScreen(
                conversationId: chatId,
                otherUserId: senderId,
                otherUserName: senderName,
                otherUserAvatar: senderAvatar,
              ),
            ),
          );
        } else {
          navigator.push(
            MaterialPageRoute(builder: (_) => const NotificationsScreen()),
          );
        }
        break;
      case 'group_message':
      case 'mention':
      case 'group_invite':
        if (groupId != null) {
          navigator.push(
            MaterialPageRoute(
              builder: (_) => GroupChatScreen(
                groupId: groupId,
                groupName:
                    data['groupName']?.toString() ??
                    data['group_name']?.toString() ??
                    'Group',
              ),
            ),
          );
        } else {
          navigator.push(
            MaterialPageRoute(builder: (_) => const NotificationsScreen()),
          );
        }
        break;
      case 'friend_request':
      case 'system_alert':
        navigator.push(
          MaterialPageRoute(builder: (_) => const NotificationsScreen()),
        );
        break;
      case 'audio_call':
      case 'voice_call':
      case 'video_call':
        final conversationId =
            data['conversationId']?.toString() ??
            data['conversation_id']?.toString() ??
            '';
        final callId =
            data['callId']?.toString() ?? data['call_id']?.toString();
        if (senderId != null) {
          navigator.push(
            MaterialPageRoute(
              builder: (_) => CallScreen(
                conversationId: conversationId,
                callId: callId,
                recipientId: senderId,
                recipientName: senderName,
                recipientAvatar: senderAvatar,
                isVideo: type == 'video_call',
                isIncoming: true,
              ),
            ),
          );
        }
        break;
      case 'missed_call':
        navigator.push(
          MaterialPageRoute(builder: (_) => const CallHistoryScreen()),
        );
        break;
      default:
        navigator.push(
          MaterialPageRoute(builder: (_) => const NotificationsScreen()),
        );
    }
  }

  Future<void> sendNotificationToUser({
    required String targetUserId,
    required String type,
    required String title,
    required String body,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;
      final authToken = _client.auth.currentSession?.accessToken;
      if (authToken == null || authToken.isEmpty) return;

      final response = await http.post(
        Uri.parse('${Config.backendUrl}/api/notifications/send'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: jsonEncode({
          'receiverId': targetUserId,
          'type': type,
          'title': title,
          'body': body,
          'data': additionalData ?? <String, dynamic>{},
          'options': const <String, dynamic>{},
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Failed to send notification: ${response.statusCode} ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Error sending notification: $e');
    }
  }

  Future<void> sendWaveNotification(String targetUserId) async {
    await sendNotificationToUser(
      targetUserId: targetUserId,
      type: 'friend_request',
      title: 'New Friend Request',
      body: 'Someone sent you a request',
      additionalData: {'screen': 'friend_requests'},
    );
  }

  Future<void> sendWaveResponseNotification({
    required String targetUserId,
    required bool accepted,
  }) async {
    await sendNotificationToUser(
      targetUserId: targetUserId,
      type: 'friend_accept',
      title: 'Friend Request Accepted',
      body: accepted
          ? 'Your friend request was accepted'
          : 'Your friend request was declined',
      additionalData: {'screen': accepted ? 'chat' : 'notifications'},
    );
  }

  Future<void> sendMessageNotification({
    required String targetUserId,
    required String conversationId,
    required String messagePreview,
  }) async {
    await sendNotificationToUser(
      targetUserId: targetUserId,
      type: 'dm_message',
      title: 'New Message',
      body: messagePreview,
      additionalData: {
        'screen': 'chat',
        'chatId': conversationId,
        'conversation_id': conversationId,
      },
    );
  }

  Future<void> sendGroupMessageNotification({
    required String groupId,
    required String groupName,
    required String messagePreview,
    required String senderId,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) return;

    final members = await _client
        .from('group_members')
        .select('user_id')
        .eq('group_id', groupId)
        .neq('user_id', user.id);

    for (final member in (members as List)) {
      await sendNotificationToUser(
        targetUserId: member['user_id'].toString(),
        type: 'group_message',
        title: groupName,
        body: messagePreview,
        additionalData: {
          'screen': 'group_chat',
          'groupId': groupId,
          'group_name': groupName,
          'senderId': senderId,
        },
      );
    }
  }

  Future<void> sendGroupJoinNotification({
    required String groupId,
    required String groupName,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) return;

    final admins = await _client
        .from('group_members')
        .select('user_id')
        .eq('group_id', groupId)
        .inFilter('role', ['admin', 'moderator'])
        .neq('user_id', user.id);

    for (final admin in (admins as List)) {
      await sendNotificationToUser(
        targetUserId: admin['user_id'].toString(),
        type: 'system_alert',
        title: 'Group Member Joined',
        body: 'A new member joined $groupName',
        additionalData: {
          'screen': 'group_chat',
          'groupId': groupId,
          'group_name': groupName,
        },
      );
    }
  }

  Future<void> sendCallNotification({
    required String targetUserId,
    required String callId,
    required String callType,
    required String conversationId,
  }) async {
    final type = callType == 'video' ? 'video_call' : 'voice_call';
    await sendNotificationToUser(
      targetUserId: targetUserId,
      type: type,
      title: 'Incoming Call',
      body: 'Tap to answer',
      additionalData: {
        'screen': 'call',
        'callId': callId,
        'callType': callType,
        'conversationId': conversationId,
      },
    );
  }

  Future<void> subscribeToTopic(String topic) =>
      _messaging.subscribeToTopic(topic);

  Future<void> unsubscribeFromTopic(String topic) =>
      _messaging.unsubscribeFromTopic(topic);
}
