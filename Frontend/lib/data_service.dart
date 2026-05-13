import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'supabase_service.dart';
import 'notification_service.dart';
import 'encryption_service.dart';

class DataService {
  static final DataService _instance = DataService._internal();
  factory DataService() => _instance;
  DataService._internal();

  final SupabaseClient _client = SupabaseService().client;

  /// Discovery radius cap (must match backend `NEARBY_5KM_AND_WAVES.sql`).
  static const double maxNearbyRadiusKm = 5.0;

  double _effectiveNearbyRadius(double radiusKm) {
    final r = radiusKm <= 0 ? maxNearbyRadiusKm : radiusKm;
    return r > maxNearbyRadiusKm ? maxNearbyRadiusKm : r;
  }

  // ============================================
  // NEARBY USERS
  // ============================================

  Future<List<NearbyUser>> getNearbyUsers({
    required double latitude,
    required double longitude,
    double radiusKm = maxNearbyRadiusKm,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final response = await _client.rpc(
        'get_nearby_users',
        params: {
          'user_lat': latitude,
          'user_lon': longitude,
          'radius_km': _effectiveNearbyRadius(radiusKm),
          'result_limit': limit,
          'result_offset': offset,
        },
      );

      final raw = (response as List)
          .map((json) => Map<String, dynamic>.from(json as Map))
          .toList();

      final ids = raw.map((row) => row['id']?.toString()).whereType<String>().toList();
      final coordsById = <String, Map<String, dynamic>>{};
      if (ids.isNotEmpty) {
        final coordRows = await _client
            .from('profiles')
            .select('id, latitude, longitude')
            .inFilter('id', ids);
        for (final row in (coordRows as List)) {
          final map = Map<String, dynamic>.from(row as Map);
          final id = map['id']?.toString();
          if (id != null) coordsById[id] = map;
        }
      }

      return raw.map((json) {
            final id = json['id']?.toString();
            final coords = id == null ? null : coordsById[id];
            if (coords != null) {
              json['latitude'] = coords['latitude'];
              json['longitude'] = coords['longitude'];
            }
            return NearbyUser.fromJson(json);
          }).where((u) => u.distanceMeters <= maxNearbyRadiusKm * 1000)
          .toList();
    } catch (e) {
      print('Error fetching nearby users: $e');
      return [];
    }
  }

  // ============================================
  // NEARBY GROUPS
  // ============================================

  Future<List<NearbyGroup>> getNearbyGroups({
    required double latitude,
    required double longitude,
    double radiusKm = maxNearbyRadiusKm,
  }) async {
    try {
      final response = await _client.rpc(
        'get_nearby_groups',
        params: {
          'user_lat': latitude,
          'user_lon': longitude,
          'radius_km': _effectiveNearbyRadius(radiusKm),
        },
      );

      final raw = (response as List).cast<Map<String, dynamic>>();

      // RPC `get_nearby_groups` returns member_count + distance, but it doesn't
      // include whether the current user is a member. We compute `isMember`
      // from `group_members` so UI Join/Leave state is correct.
      final user = _client.auth.currentUser;
      final Set<String> myGroupIds = <String>{};
      if (user != null && raw.isNotEmpty) {
        final groupIds = raw
            .map((g) => g['id']?.toString())
            .whereType<String>()
            .toList();
        if (groupIds.isNotEmpty) {
          final memberRows = await _client
              .from('group_members')
              .select('group_id')
              .inFilter('group_id', groupIds)
              .eq('user_id', user.id);

          for (final row in (memberRows as List)) {
            final gid = (row['group_id'] ?? row['groupId'])?.toString();
            if (gid != null && gid.isNotEmpty) myGroupIds.add(gid);
          }
        }
      }

      return raw
          .map((json) {
            final groupId = json['id']?.toString();
            final isMember = groupId != null && myGroupIds.contains(groupId);
            return NearbyGroup.fromJson(json, isMember: isMember);
          })
          .where((g) => g.distance <= maxNearbyRadiusKm + 1e-6)
          .toList();
    } catch (e) {
      print('Error fetching nearby groups: $e');
      return [];
    }
  }

  /// All groups the current user has joined (any distance; includes private).
  Future<List<NearbyGroup>> getMyJoinedGroups() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final memberRows = await _client
          .from('group_members')
          .select('group_id')
          .eq('user_id', user.id);

      final ids = (memberRows as List)
          .map((r) => r['group_id']?.toString())
          .whereType<String>()
          .toList();
      if (ids.isEmpty) return [];

      final groupsData = await _client
          .from('groups')
          .select(
            'id, name, description, category, cover_image_url, location_text, latitude, longitude, is_private',
          )
          .inFilter('id', ids);

      final countRows = await _client
          .from('group_members')
          .select('group_id')
          .inFilter('group_id', ids);

      final counts = <String, int>{};
      for (final r in countRows as List) {
        final gid = r['group_id']?.toString();
        if (gid == null) continue;
        counts[gid] = (counts[gid] ?? 0) + 1;
      }

      final list = (groupsData as List).map((row) {
        final map = Map<String, dynamic>.from(row as Map);
        final id = map['id']?.toString() ?? '';
        map['member_count'] = counts[id] ?? 0;
        map['distance'] = 0.0;
        return NearbyGroup.fromJson(map, isMember: true);
      }).toList();

      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      print('Error fetching joined groups: $e');
      return [];
    }
  }

  // ============================================
  // EVENTS
  // ============================================

  Future<List<NearbyEvent>> getNearbyEvents({
    required double latitude,
    required double longitude,
    double radiusKm = maxNearbyRadiusKm,
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final response = await _client.rpc(
        'get_nearby_events',
        params: {
          'user_lat': latitude,
          'user_lon': longitude,
          'radius_km': _effectiveNearbyRadius(radiusKm),
          'result_limit': limit,
          'result_offset': offset,
        },
      );

      return (response as List)
          .map((json) => NearbyEvent.fromJson(json as Map<String, dynamic>))
          .where((e) => e.distanceMeters <= maxNearbyRadiusKm * 1000)
          .toList();
    } catch (e) {
      print('Error fetching nearby events: $e');
      return [];
    }
  }

  Future<List<NearbyEvent>> getMyEvents() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final membershipRows = await _client
          .from('event_members')
          .select('event_id, role, rsvp_status')
          .eq('user_id', user.id);

      final memberships = <String, Map<String, dynamic>>{};
      for (final row in (membershipRows as List)) {
        final eventId = row['event_id']?.toString();
        if (eventId == null || eventId.isEmpty) continue;
        memberships[eventId] = Map<String, dynamic>.from(row as Map);
      }

      final createdRows = await _client
          .from('events')
          .select('id')
          .eq('created_by', user.id);
      for (final row in (createdRows as List)) {
        final eventId = row['id']?.toString();
        if (eventId == null || eventId.isEmpty) continue;
        memberships.putIfAbsent(eventId, () => {
          'event_id': eventId,
          'role': 'organizer',
          'rsvp_status': 'going',
        });
      }

      final eventIds = memberships.keys.toList();
      if (eventIds.isEmpty) return [];

      final eventRows = await _client
          .from('events')
          .select('''
            id,
            created_by,
            title,
            description,
            category,
            cover_image_url,
            starts_at,
            ends_at,
            location_text,
            latitude,
            longitude,
            max_attendees,
            is_cancelled,
            created_at,
            updated_at,
            profiles!events_created_by_fkey (
              id,
              username,
              display_name,
              avatar_url
            )
          ''')
          .inFilter('id', eventIds)
          .order('starts_at', ascending: true);

      final countRows = await _client
          .from('event_members')
          .select('event_id, rsvp_status')
          .inFilter('event_id', eventIds);

      final counts = <String, int>{};
      for (final row in (countRows as List)) {
        final eventId = row['event_id']?.toString();
        final status = row['rsvp_status']?.toString();
        if (eventId == null || status == 'not_going') continue;
        counts[eventId] = (counts[eventId] ?? 0) + 1;
      }

      return (eventRows as List).map((row) {
        final map = Map<String, dynamic>.from(row as Map);
        final eventId = map['id']?.toString() ?? '';
        final membership = memberships[eventId] ?? const {};
        final profile = Map<String, dynamic>.from(
          map['profiles'] as Map? ?? const {},
        );
        map['attendee_count'] = counts[eventId] ?? 0;
        map['my_role'] = membership['role'];
        map['my_rsvp_status'] = membership['rsvp_status'];
        map['distance'] = 0.0;
        map['distance_meters'] = 0.0;
        map['distance_text'] = 'Hosting';
        map['creator_display_name'] = profile['display_name'];
        map['creator_username'] = profile['username'];
        map['creator_avatar_url'] = profile['avatar_url'];
        return NearbyEvent.fromJson(map);
      }).toList();
    } catch (e) {
      print('Error fetching my events: $e');
      return [];
    }
  }

  Future<NearbyEvent?> getEventById(String eventId) async {
    try {
      final user = _client.auth.currentUser;
      final row = await _client
          .from('events')
          .select('''
            id,
            created_by,
            title,
            description,
            category,
            cover_image_url,
            starts_at,
            ends_at,
            location_text,
            latitude,
            longitude,
            max_attendees,
            is_cancelled,
            created_at,
            updated_at,
            profiles!events_created_by_fkey (
              id,
              username,
              display_name,
              avatar_url
            )
          ''')
          .eq('id', eventId)
          .single();

      final membership = user == null
          ? null
          : await _client
                .from('event_members')
                .select('role, rsvp_status')
                .eq('event_id', eventId)
                .eq('user_id', user.id)
                .maybeSingle();

      final countRows = await _client
          .from('event_members')
          .select('id')
          .eq('event_id', eventId)
          .neq('rsvp_status', 'not_going');

      final map = Map<String, dynamic>.from(row);
      final profile = Map<String, dynamic>.from(
        map['profiles'] as Map? ?? const {},
      );
      map['attendee_count'] = (countRows as List).length;
      map['my_role'] = membership?['role'];
      map['my_rsvp_status'] = membership?['rsvp_status'];
      map['distance'] = 0.0;
      map['distance_meters'] = 0.0;
      map['distance_text'] = '';
      map['creator_display_name'] = profile['display_name'];
      map['creator_username'] = profile['username'];
      map['creator_avatar_url'] = profile['avatar_url'];
      return NearbyEvent.fromJson(map);
    } catch (e) {
      print('Error fetching event: $e');
      return null;
    }
  }

  Future<List<EventMember>> getEventMembers(String eventId) async {
    try {
      final response = await _client
          .from('event_members')
          .select('''
            id,
            role,
            rsvp_status,
            created_at,
            profiles!event_members_user_id_fkey (
              id,
              username,
              display_name,
              avatar_url
            )
          ''')
          .eq('event_id', eventId)
          .order('created_at', ascending: true);

      return (response as List)
          .map((json) => EventMember.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error fetching event members: $e');
      return [];
    }
  }

  Future<bool> createEvent({
    required String title,
    required DateTime startsAt,
    required String locationText,
    required double latitude,
    required double longitude,
    String? description,
    String? category,
    String? coverImageUrl,
    DateTime? endsAt,
    int? maxAttendees,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final eventRow = await _client
          .from('events')
          .insert({
            'created_by': user.id,
            'title': title,
            'description': description,
            'category': category ?? 'MEETUP',
            'cover_image_url': coverImageUrl,
            'starts_at': startsAt.toUtc().toIso8601String(),
            'ends_at': endsAt?.toUtc().toIso8601String(),
            'location_text': locationText,
            'latitude': latitude,
            'longitude': longitude,
            'max_attendees': maxAttendees,
          })
          .select('id')
          .single();

      await _client.from('event_members').upsert({
        'event_id': eventRow['id'],
        'user_id': user.id,
        'role': 'organizer',
        'rsvp_status': 'going',
      }, onConflict: 'event_id,user_id');
      return true;
    } catch (e) {
      print('Error creating event: $e');
      return false;
    }
  }

  Future<bool> updateEvent({
    required String eventId,
    required String title,
    required DateTime startsAt,
    required String locationText,
    required double latitude,
    required double longitude,
    String? description,
    String? category,
    String? coverImageUrl,
    DateTime? endsAt,
    int? maxAttendees,
    bool? isCancelled,
  }) async {
    try {
      await _client
          .from('events')
          .update({
            'title': title,
            'description': description,
            'category': category ?? 'MEETUP',
            'cover_image_url': coverImageUrl,
            'starts_at': startsAt.toUtc().toIso8601String(),
            'ends_at': endsAt?.toUtc().toIso8601String(),
            'location_text': locationText,
            'latitude': latitude,
            'longitude': longitude,
            'max_attendees': maxAttendees,
            'is_cancelled': isCancelled,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', eventId);
      return true;
    } catch (e) {
      print('Error updating event: $e');
      return false;
    }
  }

  Future<bool> deleteEvent(String eventId) async {
    try {
      await _client.from('events').delete().eq('id', eventId);
      return true;
    } catch (e) {
      print('Error deleting event: $e');
      return false;
    }
  }

  Future<bool> setEventRsvp({
    required String eventId,
    required String status,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final existing = await _client
          .from('event_members')
          .select('id, role')
          .eq('event_id', eventId)
          .eq('user_id', user.id)
          .maybeSingle();

      await _client.from('event_members').upsert({
        'id': existing?['id'],
        'event_id': eventId,
        'user_id': user.id,
        'role': existing?['role'] ?? 'attendee',
        'rsvp_status': status,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'event_id,user_id');
      return true;
    } catch (e) {
      print('Error updating event RSVP: $e');
      return false;
    }
  }

  Future<bool> updateEventMemberRole({
    required String memberId,
    required String role,
  }) async {
    try {
      await _client
          .from('event_members')
          .update({
            'role': role,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', memberId);
      return true;
    } catch (e) {
      print('Error updating event member role: $e');
      return false;
    }
  }

  Future<bool> removeEventMember(String memberId) async {
    try {
      await _client.from('event_members').delete().eq('id', memberId);
      return true;
    } catch (e) {
      print('Error removing event member: $e');
      return false;
    }
  }

  // ============================================
  // STORIES
  // ============================================

  Future<List<Story>> getActiveStories({
    double? latitude,
    double? longitude,
    double radiusKm = maxNearbyRadiusKm,
  }) async {
    try {
      if (latitude != null && longitude != null) {
        final response = await _client.rpc(
          'get_visible_stories',
          params: {
            'user_lat': latitude,
            'user_lon': longitude,
            'radius_km': _effectiveNearbyRadius(radiusKm),
          },
        );

        return (response as List)
            .map(
              (json) =>
                  Story.fromVisibleStoryJson(json as Map<String, dynamic>),
            )
            .toList();
      }

      final response = await _client
          .from('stories')
          .select('''
            id,
            media_url,
            media_type,
            caption,
            created_at,
            expires_at,
            view_count,
            user_id,
            profiles!stories_user_id_fkey (
              id,
              username,
              display_name,
              avatar_url
            )
          ''')
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false);

      return (response as List).map((json) => Story.fromJson(json)).toList();
    } catch (e) {
      print('Error fetching stories: $e');
      return [];
    }
  }

  Future<bool> createStory({
    required String mediaUrl,
    String mediaType = 'image',
    String? caption,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client.from('stories').insert({
        'user_id': user.id,
        'media_url': mediaUrl,
        'media_type': mediaType,
        'caption': caption,
      });
      return true;
    } catch (e) {
      print('Error creating story: $e');
      return false;
    }
  }

  Future<bool> deleteStory(String storyId) async {
    try {
      await _client.from('stories').delete().eq('id', storyId);
      return true;
    } catch (e) {
      print('Error deleting story: $e');
      return false;
    }
  }

  // ============================================
  // FRIEND REQUEST SYSTEM (uses waves table)
  // ============================================

  /// Send a friend request to [receiverId]. Returns true if sent.
  Future<bool> sendFriendRequest(String receiverId) async {
    return sendWave(receiverId);
  }

  /// Remove a friend (delete the wave record in both directions).
  Future<bool> removeFriend(String friendId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      // Delete wave sent by current user to friend
      await _client
          .from('waves')
          .delete()
          .eq('sender_id', user.id)
          .eq('receiver_id', friendId);

      // Delete wave sent by friend to current user
      await _client
          .from('waves')
          .delete()
          .eq('sender_id', friendId)
          .eq('receiver_id', user.id);

      return true;
    } catch (e) {
      print('Error removing friend: \$e');
      return false;
    }
  }

  /// Get friend request status between current user and [targetUserId].
  /// Returns: 'pending' | 'accepted' | 'rejected' | 'received' | 'received_accepted' | null
  Future<String?> getFriendRequestStatus(String targetUserId) async {
    return getWaveStatus(targetUserId);
  }

  /// Count friends (accepted waves) for [userId].
  Future<int> getFriendsCount(String userId) async {
    try {
      final sentAccepted = await _client
          .from('waves')
          .select('id')
          .eq('sender_id', userId)
          .eq('status', 'accepted');

      final receivedAccepted = await _client
          .from('waves')
          .select('id')
          .eq('receiver_id', userId)
          .eq('status', 'accepted');

      final sentCount = (sentAccepted as List).length;
      final receivedCount = (receivedAccepted as List).length;
      return sentCount + receivedCount;
    } catch (e) {
      print('Error fetching friends count: \$e');
      return 0;
    }
  }

  /// Count groups that [userId] is a member of.
  Future<int> getUserGroupsCount(String userId) async {
    try {
      final rows = await _client
          .from('group_members')
          .select('group_id')
          .eq('user_id', userId);
      return (rows as List).length;
    } catch (e) {
      print('Error fetching groups count: \$e');
      return 0;
    }
  }

  /// Count active (non-expired) stories posted by [userId].
  Future<int> getUserStoriesCount(String userId) async {
    try {
      final rows = await _client
          .from('stories')
          .select('id')
          .eq('user_id', userId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String());
      return (rows as List).length;
    } catch (e) {
      print('Error fetching stories count: \$e');
      return 0;
    }
  }

  // ============================================
  // WAVES
  // ============================================

  Future<bool> sendWave(String receiverId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      // Check if wave already exists
      final existingWave = await _client
          .from('waves')
          .select('id')
          .eq('sender_id', user.id)
          .eq('receiver_id', receiverId)
          .maybeSingle();

      if (existingWave != null) {
        // Wave already exists, return true (idempotent)
        return true;
      }

      await _client.from('waves').insert({
        'sender_id': user.id,
        'receiver_id': receiverId,
      });

      // Send push notification to receiver
      await NotificationService().sendWaveNotification(receiverId);

      return true;
    } catch (e) {
      print('Error sending wave: $e');
      return false;
    }
  }

  Future<bool> respondToWave(String waveId, String status) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final waveResponse = await _client
          .from('waves')
          .select('sender_id')
          .eq('id', waveId)
          .single();

      await _client
          .from('waves')
          .update({
            'status': status,
            'responded_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', waveId);

      final senderId = waveResponse['sender_id'] as String?;
      if (senderId != null) {
        await NotificationService().sendWaveResponseNotification(
          targetUserId: senderId,
          accepted: status == 'accepted',
        );
      }

      return true;
    } catch (e) {
      print('Error responding to wave: $e');
      return false;
    }
  }

  Future<List<Wave>> getPendingWaves() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final response = await _client
          .from('waves')
          .select('''
            id,
            status,
            created_at,
            sender_id,
            profiles!waves_sender_id_fkey (
              id,
              username,
              display_name,
              avatar_url,
              bio
            )
          ''')
          .eq('receiver_id', user.id)
          .eq('status', 'pending')
          .order('created_at', ascending: false);

      return (response as List)
          .map((json) => Wave.fromJson(json, isReceived: true))
          .toList();
    } catch (e) {
      print('Error fetching waves: $e');
      return [];
    }
  }

  Future<bool> canChatWith(String targetUserId) async {
    try {
      final response = await _client.rpc(
        'can_chat_with',
        params: {'target_user_id': targetUserId},
      );
      return response == true;
    } catch (e) {
      print('Error checking chat permission: $e');
      return false;
    }
  }

  /// Get wave status between current user and target user
  /// Returns: 'pending' (sent, waiting), 'accepted' (they accepted), 'rejected' (they rejected),
  /// 'received' (they sent you a wave), or null (no wave)
  Future<String?> getWaveStatus(String targetUserId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final sentWave = await _client
          .from('waves')
          .select('status')
          .eq('sender_id', user.id)
          .eq('receiver_id', targetUserId)
          .maybeSingle();

      if (sentWave != null) {
        return sentWave['status'] as String?;
      }

      final receivedWave = await _client
          .from('waves')
          .select('status')
          .eq('sender_id', targetUserId)
          .eq('receiver_id', user.id)
          .maybeSingle();

      if (receivedWave != null) {
        final status = receivedWave['status'] as String?;
        if (status == 'pending') {
          return 'received';
        }
        return 'received_$status';
      }

      return null;
    } catch (e) {
      print('Error getting wave status: $e');
      return null;
    }
  }

  Future<bool> acceptReceivedWave(String senderId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final wave = await _client
          .from('waves')
          .select('id')
          .eq('sender_id', senderId)
          .eq('receiver_id', user.id)
          .eq('status', 'pending')
          .maybeSingle();

      if (wave == null) return false;

      return respondToWave(wave['id'] as String, 'accepted');
    } catch (e) {
      print('Error accepting received wave: $e');
      return false;
    }
  }

  Future<bool> rejectReceivedWave(String senderId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final wave = await _client
          .from('waves')
          .select('id')
          .eq('sender_id', senderId)
          .eq('receiver_id', user.id)
          .eq('status', 'pending')
          .maybeSingle();

      if (wave == null) return false;

      return respondToWave(wave['id'] as String, 'rejected');
    } catch (e) {
      print('Error rejecting received wave: $e');
      return false;
    }
  }

  // ============================================
  // CONVERSATIONS & MESSAGES
  // ============================================

  Future<List<Conversation>> getConversations() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final response = await _client
          .from('conversations')
          .select('''
          id,
          created_at,
          last_message,
          last_message_at,
          updated_at,
          user1_id,
          user2_id
        ''')
          .or('user1_id.eq.${user.id},user2_id.eq.${user.id}')
          .not('last_message_at', 'is', null)
          .order('last_message_at', ascending: false);

      // Get all unique user IDs to fetch their profiles
      final userIds = <String>{};
      for (final conv in response) {
        if (conv['user1_id'] != user.id) userIds.add(conv['user1_id']);
        if (conv['user2_id'] != user.id) userIds.add(conv['user2_id']);
      }

      final usersMap = <String, dynamic>{};
      if (userIds.isNotEmpty) {
        // Fetch user profiles
        final usersData = await _client
            .from('profiles')
            .select('id, username, display_name, avatar_url')
            .inFilter('id', userIds.toList());

        for (var u in usersData) {
          usersMap[u['id']] = u;
        }
      }

      final convIds = (response as List)
          .map((conv) => conv['id']?.toString())
          .whereType<String>()
          .toList();

      final latestMessagesByConversation = <String, Map<String, dynamic>>{};
      final unreadCountsByConversation = <String, int>{};
      if (convIds.isNotEmpty) {
        final messagesData = await _client
            .from('messages')
            .select(
              'id, conversation_id, content, created_at, sender_id, is_read, delivered_at, seen_at, media_url, media_type',
            )
            .inFilter('conversation_id', convIds)
            .order('created_at', ascending: false);

        for (final row in (messagesData as List)) {
          final message = Map<String, dynamic>.from(row as Map);
          final conversationId = message['conversation_id']?.toString();
          if (conversationId == null) continue;
          latestMessagesByConversation.putIfAbsent(
            conversationId,
            () => message,
          );
          if (message['sender_id'] != user.id &&
              (message['is_read'] == false || message['is_read'] == null)) {
            unreadCountsByConversation[conversationId] =
                (unreadCountsByConversation[conversationId] ?? 0) + 1;
          }
        }
      }

      final conversations = <Conversation>[];
      final encryption = EncryptionService();
      final encReady = encryption.isReady;

      for (final raw in response) {
        try {
          final json = Map<String, dynamic>.from(raw as Map);
          final otherUserId = json['user1_id'] == user.id
              ? json['user2_id']
              : json['user1_id'];
          final otherUserData = usersMap[otherUserId];
          final latestMessage = latestMessagesByConversation[json['id']];
          if (latestMessage != null) {
            json['messages'] = [latestMessage];
          }
          json['unread_count'] = unreadCountsByConversation[json['id']] ?? 0;

          final conv = Conversation.fromJson(
            json,
            currentUserId: user.id,
            otherUserData: otherUserData,
          );

          if (encReady && conv.otherUser != null) {
            final lastMsg = conv.lastMessage;
            if (lastMsg != null &&
                EncryptionService.isEncryptedPayload(lastMsg.content)) {
              final isMe = lastMsg.senderId == user.id;
              final peerId = isMe ? otherUserId : lastMsg.senderId;
              final decrypted = await encryption.tryDecrypt(
                lastMsg.content,
                peerId,
                isOutgoing: isMe,
              );
              conversations.add(
                Conversation(
                  id: conv.id,
                  lastMessageAt: conv.lastMessageAt,
                  user1Id: conv.user1Id,
                  user2Id: conv.user2Id,
                  otherUser: conv.otherUser,
                  lastMessage: Message(
                    id: lastMsg.id,
                    content: decrypted ?? '[Encrypted message - unable to decrypt]',
                    isRead: lastMsg.isRead,
                    createdAt: lastMsg.createdAt,
                    senderId: lastMsg.senderId,
                    deliveredAt: lastMsg.deliveredAt,
                    seenAt: lastMsg.seenAt,
                    mediaUrl: lastMsg.mediaUrl,
                    mediaType: lastMsg.mediaType,
                  ),
                  unreadCount: conv.unreadCount,
                ),
              );
              continue;
            }
          }

          conversations.add(conv);
        } catch (e) {
          print('Error processing conversation: $e');
        }
      }

      return conversations;
    } catch (e, stack) {
      print('Error fetching conversations: $e');
      print(stack);
      return [];
    }
  }

  /// Other participant in a 1:1 conversation (for chat header / profile when only `conversationId` is known).
  Future<String?> getOtherParticipantUserId(String conversationId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final row = await _client
          .from('conversations')
          .select('user1_id, user2_id')
          .eq('id', conversationId)
          .maybeSingle();

      if (row == null) return null;
      final u1 = row['user1_id']?.toString();
      final u2 = row['user2_id']?.toString();
      if (u1 == user.id) return u2;
      if (u2 == user.id) return u1;
      return null;
    } catch (e) {
      print('Error resolving conversation peer: $e');
      return null;
    }
  }

  Future<Conversation?> getOrCreateConversation(String otherUserId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      // Check if can chat
      final canChat = await canChatWith(otherUserId);
      if (!canChat) return null;

      // Check existing conversation
      final existing = await _client
          .from('conversations')
          .select()
          .or(
            'and(user1_id.eq.${user.id},user2_id.eq.$otherUserId),and(user1_id.eq.$otherUserId,user2_id.eq.${user.id})',
          )
          .maybeSingle();

      if (existing != null) {
        return Conversation.fromJson(existing, currentUserId: user.id);
      }

      // Create new conversation
      final newConv = await _client
          .from('conversations')
          .insert({'user1_id': user.id, 'user2_id': otherUserId})
          .select()
          .single();

      return Conversation.fromJson(newConv, currentUserId: user.id);
    } catch (e) {
      print('Error getting conversation: $e');
      return null;
    }
  }

  Future<List<Message>> getMessages(String conversationId) async {
    try {
      final response = await _client
          .from('messages')
          .select('''
            id,
            content,
            media_url,
            media_type,
            is_read,
            created_at,
            sender_id,
            delivered_at,
            seen_at,
            reply_to_id,
            deleted_for_me,
            deleted_for_everyone,
            shared_latitude,
            shared_longitude
          ''')
          .eq('conversation_id', conversationId)
          .order('created_at', ascending: true);

      final user = _client.auth.currentUser;
      return (response as List)
          .where((json) {
            final deletedForMe = (json as Map)['deleted_for_me'];
            if (user == null || deletedForMe is! List) return true;
            return !deletedForMe.map((id) => id.toString()).contains(user.id);
          })
          .map((json) => Message.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error fetching messages: $e');
      return [];
    }
  }

  Future<Message?> sendMessage({
    required String conversationId,
    required String content,
    String? mediaUrl,
    String? mediaType,
    String? targetUserId,
    String? replyToId,
    double? sharedLatitude,
    double? sharedLongitude,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final insert = <String, dynamic>{
        'conversation_id': conversationId,
        'sender_id': user.id,
        'content': content,
        'media_url': mediaUrl,
        'media_type': mediaType,
      };
      if (replyToId != null) insert['reply_to_id'] = replyToId;
      if (sharedLatitude != null) insert['shared_latitude'] = sharedLatitude;
      if (sharedLongitude != null) insert['shared_longitude'] = sharedLongitude;

      Map<String, dynamic>? response;
      try {
        final token = _client.auth.currentSession?.accessToken;
        if (token != null) {
          final apiResponse = await http.post(
            Uri.parse(
              '${Config.backendUrl}/conversations/$conversationId/messages',
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'content': content,
              'mediaUrl': mediaUrl,
              'mediaType': mediaType,
              'replyToId': replyToId,
            }),
          );

          if (apiResponse.statusCode >= 200 && apiResponse.statusCode < 300) {
            final decoded =
                jsonDecode(apiResponse.body) as Map<String, dynamic>;
            response = Map<String, dynamic>.from(decoded['data'] as Map);
            response['__sent_via_backend'] = true;
          }
        }
      } catch (e) {
        print('Backend send failed, falling back to Supabase insert: $e');
      }

      response ??= await _client
          .from('messages')
          .insert(insert)
          .select()
          .single();

      final message = Message.fromJson(response);

      // Keep the chat list fresh even before database triggers are deployed.
      await _client
          .from('conversations')
          .update({
            'last_message': content.isNotEmpty ? content : '[Media]',
            'last_message_at': message.createdAt.toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', conversationId);

      if (response['__sent_via_backend'] != true &&
          targetUserId != null &&
          content.isNotEmpty) {
        final preview = content.length > 50
            ? '${content.substring(0, 50)}...'
            : content;
        await NotificationService().sendMessageNotification(
          targetUserId: targetUserId,
          conversationId: conversationId,
          messagePreview: preview,
        );
      }

      return message;
    } catch (e) {
      print('Error sending message: $e');
      return null;
    }
  }

  // ============================================
  // GROUPS
  // ============================================

  Future<bool> joinGroup(String groupId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client.from('group_members').insert({
        'group_id': groupId,
        'user_id': user.id,
      });

      try {
        final groupRow = await _client
            .from('groups')
            .select('name')
            .eq('id', groupId)
            .maybeSingle();
        final groupName = groupRow?['name'] as String? ?? 'Group';
        await NotificationService().sendGroupJoinNotification(
          groupId: groupId,
          groupName: groupName,
        );
      } catch (e) {
        print('Error sending group join notification: $e');
      }

      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      print('Error joining group: $e');
      return false;
    } catch (e) {
      print('Error joining group: $e');
      return false;
    }
  }

  Future<bool> leaveGroup(String groupId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client
          .from('group_members')
          .delete()
          .eq('group_id', groupId)
          .eq('user_id', user.id);
      return true;
    } catch (e) {
      print('Error leaving group: $e');
      return false;
    }
  }

  Future<bool> createGroup({
    required String name,
    String? description,
    String? category,
    double? latitude,
    double? longitude,
    String? coverImageUrl,
    bool isPrivate = false,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      // Create the group
      final groupResponse = await _client
          .from('groups')
          .insert({
            'name': name,
            'description': description,
            'category': category,
            'latitude': latitude,
            'longitude': longitude,
            'cover_image_url': coverImageUrl,
            'is_private': isPrivate,
            'created_by': user.id,
          })
          .select()
          .single();

      // Add creator as admin member
      await _client.from('group_members').insert({
        'group_id': groupResponse['id'],
        'user_id': user.id,
        'role': 'admin',
      });

      return true;
    } catch (e) {
      print('Error creating group: $e');
      return false;
    }
  }

  Future<bool> updateGroupCover({
    required String groupId,
    required String coverImageUrl,
  }) async {
    try {
      await _client
          .from('groups')
          .update({'cover_image_url': coverImageUrl})
          .eq('id', groupId);
      return true;
    } catch (e) {
      print('Error updating group cover: $e');
      return false;
    }
  }

  Future<List<GroupMessage>> getGroupMessages(String groupId) async {
    try {
      final response = await _client
          .from('group_messages')
          .select('''
            id,
            group_id,
            sender_id,
            content,
            created_at,
            profiles (
              display_name,
              username,
              avatar_url
            )
          ''')
          .eq('group_id', groupId)
          .order('created_at', ascending: true);

      return (response as List)
          .map((row) => GroupMessage.fromJson(row as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error fetching group messages: $e');
      return [];
    }
  }

  Future<GroupMessage?> sendGroupMessage({
    required String groupId,
    required String content,
    String? groupName,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final trimmed = content.trim();
      if (trimmed.isEmpty) return null;

      final response = await _client
          .from('group_messages')
          .insert({
            'group_id': groupId,
            'sender_id': user.id,
            'content': trimmed,
          })
          .select('''
            id,
            group_id,
            sender_id,
            content,
            created_at,
            profiles (
              display_name,
              username,
              avatar_url
            )
          ''')
          .single();

      final message = GroupMessage.fromJson(response);

      final preview = trimmed.length > 50
          ? '${trimmed.substring(0, 50)}...'
          : trimmed;

      String? name = groupName;
      final groupRow = await _client
          .from('groups')
          .select('name')
          .eq('id', groupId)
          .maybeSingle();
      name ??= groupRow?['name'] as String?;
      name ??= 'Group';

      await NotificationService().sendGroupMessageNotification(
        groupId: groupId,
        groupName: name,
        messagePreview: preview,
        senderId: user.id,
      );

      return message;
    } catch (e) {
      print('Error sending group message: $e');
      return null;
    }
  }

  Future<List<GroupMember>> getGroupMembers(String groupId) async {
    try {
      final response = await _client
          .from('group_members')
          .select('''
            id,
            role,
            joined_at,
            profiles (
              id,
              username,
              display_name,
              avatar_url
            )
          ''')
          .eq('group_id', groupId)
          .order('joined_at', ascending: true);

      return (response as List)
          .map((json) => GroupMember.fromJson(json))
          .toList();
    } catch (e) {
      print('Error fetching group members: $e');
      return [];
    }
  }

  // ============================================
  // USER PROFILE
  // ============================================

  Future<UserProfile?> getUserProfile(String userId) async {
    try {
      final response = await _client
          .from('profiles')
          .select('*')
          .eq('id', userId)
          .single();

      return UserProfile.fromJson(response);
    } catch (e) {
      print('Error fetching user profile: $e');
      return null;
    }
  }

  Future<dynamic> updateProfile({
    String? displayName,
    String? username,
    String? bio,
    String? avatarUrl,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final updates = <String, dynamic>{};
      if (displayName != null) updates['display_name'] = displayName;
      if (username != null) updates['username'] = username;
      if (bio != null) updates['bio'] = bio;
      if (avatarUrl != null) updates['avatar_url'] = avatarUrl;

      if (updates.isEmpty) return true;

      await _client.from('profiles').update(updates).eq('id', user.id);
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return 'username_taken';
      print('Error updating profile: $e');
      return false;
    } catch (e) {
      print('Error updating profile: $e');
      return false;
    }
  }

  // ============================================
  // USER KEYS (for E2E encryption)
  // ============================================

  Future<String?> getUserPublicKey(String userId) async {
    try {
      final response = await _client
          .from('user_keys')
          .select('public_key, key_scheme')
          .eq('user_id', userId)
          .single();

      return response['public_key'] as String?;
    } catch (e) {
      print('Error fetching user public key: $e');
      return null;
    }
  }

  Future<bool> saveUserPublicKey(
    String publicKey, {
    int keyVersion = 1,
    int keyScheme = 1,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client.from('user_keys').upsert({
        'user_id': user.id,
        'public_key': publicKey,
        'key_version': keyVersion,
        'key_scheme': keyScheme,
      }, onConflict: 'user_id');

      return true;
    } catch (e) {
      print('Error saving user public key: $e');
      return false;
    }
  }

  // ============================================
  // BLOCK / REPORT
  // ============================================

  Future<bool> blockUser(String userId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      await _client.from('blocked_users').insert({
        'blocker_id': user.id,
        'blocked_id': userId,
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      print('Error blocking user: $e');
      return false;
    } catch (e) {
      print('Error blocking user: $e');
      return false;
    }
  }

  Future<bool> unblockUser(String userId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      await _client
          .from('blocked_users')
          .delete()
          .eq('blocker_id', user.id)
          .eq('blocked_id', userId);
      return true;
    } catch (e) {
      print('Error unblocking user: $e');
      return false;
    }
  }

  Future<bool> isUserBlocked(String userId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      final row = await _client
          .from('blocked_users')
          .select('id')
          .eq('blocker_id', user.id)
          .eq('blocked_id', userId)
          .maybeSingle();
      return row != null;
    } catch (e) {
      return false;
    }
  }

  Future<bool> isBlockedByUser(String userId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return true;
      final row = await _client
          .from('blocked_users')
          .select('id')
          .eq('blocker_id', userId)
          .eq('blocked_id', user.id)
          .maybeSingle();
      return row != null;
    } catch (e) {
      return false;
    }
  }

  Future<bool> reportUser(String userId, String reason) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      await _client.from('reported_users').insert({
        'reporter_id': user.id,
        'reported_id': userId,
        'reason': reason,
      });
      return true;
    } catch (e) {
      print('Error reporting user: $e');
      return false;
    }
  }

  // ============================================
  // MUTUAL FRIENDS
  // ============================================

  Future<List<MutualFriend>> getMutualFriends(String otherUserId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final myFriends = await _getFriendIds(user.id);
      final theirFriends = await _getFriendIds(otherUserId);
      final mutualIds = myFriends.intersection(theirFriends);

      if (mutualIds.isEmpty) return [];

      final profiles = await _client
          .from('profiles')
          .select('id, username, display_name, avatar_url')
          .inFilter('id', mutualIds.toList());

      return (profiles as List)
          .map((p) => MutualFriend.fromJson(p as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error fetching mutual friends: $e');
      return [];
    }
  }

  Future<Set<String>> _getFriendIds(String userId) async {
    final sent = await _client
        .from('waves')
        .select('receiver_id')
        .eq('sender_id', userId)
        .eq('status', 'accepted');
    final received = await _client
        .from('waves')
        .select('sender_id')
        .eq('receiver_id', userId)
        .eq('status', 'accepted');
    final ids = <String>{};
    for (final r in (sent as List)) {
      ids.add(r['receiver_id'] as String);
    }
    for (final r in (received as List)) {
      ids.add(r['sender_id'] as String);
    }
    return ids;
  }

  // ============================================
  // MESSAGE DELETE & REPLY
  // ============================================

  Future<bool> deleteMessageForMe(String messageId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      await _client.rpc(
        'append_deleted_for_me',
        params: {'msg_id': messageId, 'uid': user.id},
      );
      return true;
    } catch (e) {
      print('Error deleting message for me: $e');
      return false;
    }
  }

  Future<bool> deleteMessageForEveryone(String messageId) async {
    try {
      await _client
          .from('messages')
          .update({
            'content': '',
            'media_url': null,
            'media_type': null,
            'deleted_for_everyone': true,
          })
          .eq('id', messageId);
      return true;
    } catch (e) {
      print('Error deleting message for everyone: $e');
      return false;
    }
  }

  // ============================================
  // STORY VIEWS
  // ============================================

  Future<bool> markStoryViewed(String storyId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      await _client.from('story_views').insert({
        'story_id': storyId,
        'viewer_id': user.id,
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<int> getStoryViewCount(String storyId) async {
    try {
      final row = await _client
          .from('stories')
          .select('view_count')
          .eq('id', storyId)
          .single();
      return (row['view_count'] as num?)?.toInt() ?? 0;
    } catch (e) {
      return 0;
    }
  }

  // ============================================
  // LOCATION PRECISION
  // ============================================

  Future<bool> updateLocationPrecision(String precision) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;
      await _client
          .from('profiles')
          .update({'location_precision': precision})
          .eq('id', user.id);
      return true;
    } catch (e) {
      print('Error updating location precision: $e');
      return false;
    }
  }

  // ============================================
  // NOTIFICATIONS
  // ============================================

  Future<List<AppNotification>> getNotifications({
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final response = await _client
          .from('notifications')
          .select(
            'id, sender_id, receiver_id, type, title, body, data, is_read, created_at, read_at, grouped_count',
          )
          .eq('receiver_id', user.id)
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1);

      return (response as List)
          .map((json) => AppNotification.fromJson(json))
          .toList();
    } catch (e) {
      print('Error fetching notifications: $e');
      return [];
    }
  }

  Future<int> getUnreadNotificationCount() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return 0;

      final response = await _client
          .from('notifications')
          .select('id')
          .eq('receiver_id', user.id)
          .eq('is_read', false);

      return (response as List).length;
    } catch (e) {
      print('Error fetching unread notification count: $e');
      return 0;
    }
  }

  Future<bool> markNotificationAsRead(String notificationId) async {
    try {
      await _client
          .from('notifications')
          .update({
            'is_read': true,
            'read_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', notificationId);
      return true;
    } catch (e) {
      print('Error marking notification as read: $e');
      return false;
    }
  }

  Future<bool> markAllNotificationsAsRead() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client
          .from('notifications')
          .update({
            'is_read': true,
            'read_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('receiver_id', user.id)
          .eq('is_read', false);
      return true;
    } catch (e) {
      print('Error marking all notifications as read: $e');
      return false;
    }
  }

  Future<bool> clearAllNotifications() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client.from('notifications').delete().eq('receiver_id', user.id);
      return true;
    } catch (e) {
      print('Error clearing notifications: $e');
      return false;
    }
  }

  Future<NotificationPreferenceSettings> getNotificationSettings() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return NotificationPreferenceSettings.defaults();

      final response = await _client
          .from('notification_settings')
          .select('*')
          .eq('user_id', user.id)
          .maybeSingle();

      if (response == null) {
        return NotificationPreferenceSettings.defaults(userId: user.id);
      }

      return NotificationPreferenceSettings.fromJson(response);
    } catch (e) {
      print('Error fetching notification settings: $e');
      return NotificationPreferenceSettings.defaults();
    }
  }

  Future<bool> updateNotificationSettings(
    NotificationPreferenceSettings settings,
  ) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client.from('notification_settings').upsert({
        'user_id': user.id,
        'dm_notifications': settings.dmNotifications,
        'group_notifications': settings.groupNotifications,
        'friend_request_notifications': settings.friendRequestNotifications,
        'mention_notifications': settings.mentionNotifications,
        'call_notifications': settings.callNotifications,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');

      return true;
    } catch (e) {
      print('Error updating notification settings: $e');
      return false;
    }
  }

  // ============================================
  // TOTAL UNREAD COUNT (for nav badge)
  // ============================================

  Future<int> getTotalUnreadCount() async {
    return getUnreadNotificationCount();
  }

  // ============================================
  // ONLINE STATUS & LAST SEEN
  // ============================================

  /// Update current user's last_seen timestamp
  Future<void> updateLastSeen() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;

      await _client
          .from('profiles')
          .update({'last_seen': DateTime.now().toUtc().toIso8601String()})
          .eq('id', user.id);
    } catch (e) {
      print('Error updating last seen: $e');
    }
  }

  /// Get user's online status and last seen
  Future<UserProfile?> getUserOnlineStatus(String userId) async {
    try {
      final response = await _client
          .from('profiles')
          .select('id, last_seen')
          .eq('id', userId)
          .single();

      return UserProfile.fromJson(response);
    } catch (e) {
      print('Error fetching user online status: $e');
      return null;
    }
  }

  // ============================================
  // MESSAGE DELIVERY STATUS
  // ============================================

  /// Mark messages as delivered for current user
  Future<void> markMessagesAsDelivered(String conversationId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;

      // Mark all undelivered messages sent to current user as delivered
      await _client
          .from('messages')
          .update({'delivered_at': DateTime.now().toUtc().toIso8601String()})
          .eq('conversation_id', conversationId)
          .neq('sender_id', user.id)
          .filter('delivered_at', 'is', null);
    } catch (e) {
      print('Error marking messages as delivered: $e');
    }
  }

  /// Mark messages as seen for current user
  Future<void> markMessagesAsSeen(String conversationId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;

      // Mark all unseen messages sent to current user as seen
      await _client
          .from('messages')
          .update({
            'seen_at': DateTime.now().toUtc().toIso8601String(),
            'is_read': true,
          })
          .eq('conversation_id', conversationId)
          .neq('sender_id', user.id)
          .filter('seen_at', 'is', null);
    } catch (e) {
      print('Error marking messages as seen: $e');
    }
  }
}

// ============================================
// DATA MODELS
// ============================================

class NearbyUser {
  final String id;
  final String? email;
  final String? username;
  final String? fullName;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final String? locationText;
  final double? latitude;
  final double? longitude;
  final String? gender;
  final DateTime? dateOfBirth;
  final int? age;
  final double distance;
  final double distanceMeters;
  final String distanceText;
  final DateTime? lastLocationUpdatedAt;

  NearbyUser({
    required this.id,
    this.email,
    this.username,
    this.fullName,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.locationText,
    this.latitude,
    this.longitude,
    this.gender,
    this.dateOfBirth,
    this.age,
    required this.distance,
    required this.distanceMeters,
    required this.distanceText,
    this.lastLocationUpdatedAt,
  });

  factory NearbyUser.fromJson(Map<String, dynamic> json) {
    final meters =
        (json['distance_meters'] as num?)?.toDouble() ??
        (((json['distance'] as num?)?.toDouble() ?? 0.0) * 1000);
    return NearbyUser(
      id: json['id'],
      email: json['email'],
      username: json['username'],
      fullName: json['full_name'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
      bio: json['bio'],
      locationText: json['location_text'],
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      gender: json['gender'],
      dateOfBirth: json['date_of_birth'] != null
          ? DateTime.tryParse(json['date_of_birth'].toString())
          : null,
      age: (json['age'] as num?)?.toInt(),
      distance: (json['distance'] as num?)?.toDouble() ?? 0.0,
      distanceMeters: meters,
      distanceText:
          json['distance_text']?.toString() ?? formatDistanceMeters(meters),
      lastLocationUpdatedAt: json['last_location_updated_at'] != null
          ? DateTime.tryParse(json['last_location_updated_at'].toString())
          : null,
    );
  }

  static String formatDistanceMeters(double meters) {
    if (meters < 0 || meters.isNaN || meters.isInfinite) {
      return 'Location unavailable';
    }
    if (meters < 1000) {
      return '${meters.round()} m away';
    }
    final km = meters / 1000;
    final rounded = km >= 10 ? km.round().toString() : km.toStringAsFixed(1);
    return '${rounded.endsWith('.0') ? rounded.substring(0, rounded.length - 2) : rounded} km away';
  }

  String get demographicsText {
    final parts = <String>[];
    final cleanGender = gender?.trim();
    if (cleanGender != null && cleanGender.isNotEmpty) {
      parts.add(cleanGender);
    }
    if (age != null && age! > 0) {
      parts.add('$age');
    }
    return parts.join(' • ');
  }

  String get displayDistance {
    return distanceText;
  }

  String get displayNameOrHandle {
    final name = _firstNonEmpty([displayName, fullName, username]);
    return name ?? publicHandle;
  }

  String get publicHandle {
    final cleanUsername = _cleanText(username);
    if (cleanUsername != null) {
      return cleanUsername.startsWith('@') ? cleanUsername : '@$cleanUsername';
    }

    final compactId = id.replaceAll('-', '');
    final suffix = compactId.length <= 6
        ? compactId.toUpperCase()
        : compactId.substring(compactId.length - 6).toUpperCase();
    return 'UID_$suffix';
  }
}

class NearbyGroup {
  final String id;
  final String name;
  final String? description;
  final String? category;
  final String? coverImageUrl;
  final String? locationText;
  final double? latitude;
  final double? longitude;
  final bool isPrivate;
  final int memberCount;
  final double distance;
  final bool isMember;

  NearbyGroup({
    required this.id,
    required this.name,
    this.description,
    this.category,
    this.coverImageUrl,
    this.locationText,
    this.latitude,
    this.longitude,
    required this.isPrivate,
    required this.memberCount,
    required this.distance,
    this.isMember = false,
  });

  factory NearbyGroup.fromJson(Map<String, dynamic> json, {bool? isMember}) {
    final dynamic memberVal = isMember ?? json['is_member'] ?? false;
    final computedIsMember = memberVal is bool
        ? memberVal
        : (memberVal.toString().toLowerCase() == 'true');

    return NearbyGroup(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      category: json['category'],
      coverImageUrl: json['cover_image_url'],
      locationText: json['location_text'],
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      isPrivate: json['is_private'] ?? false,
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      distance: (json['distance'] as num?)?.toDouble() ?? 0.0,
      isMember: computedIsMember,
    );
  }

  String get displayDistance {
    if (distance < 1) {
      return '${(distance * 1000).round()}m';
    }
    return '${distance.round()}km';
  }
}

class NearbyEvent {
  final String id;
  final String createdBy;
  final String title;
  final String? description;
  final String category;
  final String? coverImageUrl;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String locationText;
  final double latitude;
  final double longitude;
  final int? maxAttendees;
  final bool isCancelled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double distance;
  final double distanceMeters;
  final String distanceText;
  final int attendeeCount;
  final String? myRole;
  final String? myRsvpStatus;
  final String? creatorDisplayName;
  final String? creatorUsername;
  final String? creatorAvatarUrl;

  NearbyEvent({
    required this.id,
    required this.createdBy,
    required this.title,
    this.description,
    required this.category,
    this.coverImageUrl,
    required this.startsAt,
    this.endsAt,
    required this.locationText,
    required this.latitude,
    required this.longitude,
    this.maxAttendees,
    required this.isCancelled,
    required this.createdAt,
    required this.updatedAt,
    required this.distance,
    required this.distanceMeters,
    required this.distanceText,
    required this.attendeeCount,
    this.myRole,
    this.myRsvpStatus,
    this.creatorDisplayName,
    this.creatorUsername,
    this.creatorAvatarUrl,
  });

  factory NearbyEvent.fromJson(Map<String, dynamic> json) {
    final meters =
        (json['distance_meters'] as num?)?.toDouble() ??
        (((json['distance'] as num?)?.toDouble() ?? 0.0) * 1000);
    return NearbyEvent(
      id: json['id'].toString(),
      createdBy: json['created_by'].toString(),
      title: json['title']?.toString() ?? 'Untitled Event',
      description: json['description']?.toString(),
      category: json['category']?.toString() ?? 'MEETUP',
      coverImageUrl: json['cover_image_url']?.toString(),
      startsAt: DateTime.parse(json['starts_at'].toString()).toLocal(),
      endsAt: json['ends_at'] == null
          ? null
          : DateTime.parse(json['ends_at'].toString()).toLocal(),
      locationText: json['location_text']?.toString() ?? 'Location pending',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      maxAttendees: (json['max_attendees'] as num?)?.toInt(),
      isCancelled: json['is_cancelled'] == true,
      createdAt: DateTime.parse(json['created_at'].toString()).toLocal(),
      updatedAt: DateTime.parse(json['updated_at'].toString()).toLocal(),
      distance: (json['distance'] as num?)?.toDouble() ?? 0.0,
      distanceMeters: meters,
      distanceText:
          json['distance_text']?.toString() ??
          NearbyUser.formatDistanceMeters(meters),
      attendeeCount: (json['attendee_count'] as num?)?.toInt() ?? 0,
      myRole: json['my_role']?.toString(),
      myRsvpStatus: json['my_rsvp_status']?.toString(),
      creatorDisplayName: json['creator_display_name']?.toString(),
      creatorUsername: json['creator_username']?.toString(),
      creatorAvatarUrl: json['creator_avatar_url']?.toString(),
    );
  }

  bool get isOrganizer => myRole == 'organizer';
  bool get isAdmin => myRole == 'admin' || isOrganizer;
  bool get isGoing => myRsvpStatus == 'going';
  bool get isInterested => myRsvpStatus == 'interested' || isGoing;

  String get creatorLabel {
    final name = _firstNonEmpty([creatorDisplayName, creatorUsername]);
    return name ?? 'Community Host';
  }

  String get displayDistance {
    if (distanceText.isNotEmpty) return distanceText;
    return NearbyUser.formatDistanceMeters(distanceMeters);
  }

  String get scheduleLabel {
    final now = DateTime.now();
    final date = startsAt;
    final sameDay =
        now.year == date.year && now.month == date.month && now.day == date.day;
    final tomorrow = now.add(const Duration(days: 1));
    final isTomorrow =
        tomorrow.year == date.year &&
        tomorrow.month == date.month &&
        tomorrow.day == date.day;
    final prefix = sameDay
        ? 'Today'
        : isTomorrow
        ? 'Tomorrow'
        : _weekdayName(date.weekday);
    final time = _formatTime(date);
    return '$prefix, $time';
  }

  static String _weekdayName(int weekday) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[(weekday - 1).clamp(0, 6)];
  }

  static String _formatTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final period = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }
}

class EventMember {
  final String id;
  final String role;
  final String rsvpStatus;
  final DateTime createdAt;
  final GroupMemberUser user;

  EventMember({
    required this.id,
    required this.role,
    required this.rsvpStatus,
    required this.createdAt,
    required this.user,
  });

  factory EventMember.fromJson(Map<String, dynamic> json) {
    return EventMember(
      id: json['id'].toString(),
      role: json['role']?.toString() ?? 'attendee',
      rsvpStatus: json['rsvp_status']?.toString() ?? 'interested',
      createdAt: DateTime.tryParse(json['created_at'].toString())?.toLocal() ??
          DateTime.now(),
      user: GroupMemberUser.fromJson(
        Map<String, dynamic>.from(
          json['profiles'] as Map? ?? const {},
        ),
      ),
    );
  }
}

class Story {
  final String id;
  final String mediaUrl;
  final String mediaType;
  final String? caption;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String userId;
  final StoryUser user;
  final int viewCount;

  Story({
    required this.id,
    required this.mediaUrl,
    required this.mediaType,
    this.caption,
    required this.createdAt,
    required this.expiresAt,
    required this.userId,
    required this.user,
    this.viewCount = 0,
  });

  factory Story.fromJson(Map<String, dynamic> json) {
    return Story(
      id: json['id'],
      mediaUrl: json['media_url'],
      mediaType: json['media_type'] ?? 'image',
      caption: json['caption'],
      createdAt: DateTime.parse(json['created_at']),
      expiresAt: DateTime.parse(json['expires_at']),
      userId: json['user_id'],
      user: StoryUser.fromJson(json['profiles']),
      viewCount: (json['view_count'] as num?)?.toInt() ?? 0,
    );
  }

  factory Story.fromVisibleStoryJson(Map<String, dynamic> json) {
    return Story(
      id: json['id'],
      mediaUrl: json['media_url'],
      mediaType: json['media_type'] ?? 'image',
      caption: json['caption'],
      createdAt: DateTime.parse(json['created_at']),
      expiresAt: DateTime.parse(json['expires_at']),
      userId: json['user_id'],
      user: StoryUser(
        id: json['profile_id'] ?? json['user_id'],
        username: json['username'],
        displayName: json['display_name'],
        avatarUrl: json['avatar_url'],
      ),
      viewCount: (json['view_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class StoryUser {
  final String id;
  final String? username;
  final String? displayName;
  final String? avatarUrl;

  StoryUser({
    required this.id,
    this.username,
    this.displayName,
    this.avatarUrl,
  });

  factory StoryUser.fromJson(Map<String, dynamic> json) {
    return StoryUser(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
    );
  }

  String get displayNameOrHandle {
    final name = _firstNonEmpty([displayName, username]);
    return name ?? publicHandle;
  }

  String get publicHandle {
    final cleanUsername = _cleanText(username);
    if (cleanUsername != null) {
      return cleanUsername.startsWith('@') ? cleanUsername : '@$cleanUsername';
    }

    final compactId = id.replaceAll('-', '');
    final suffix = compactId.length <= 6
        ? compactId.toUpperCase()
        : compactId.substring(compactId.length - 6).toUpperCase();
    return 'UID_$suffix';
  }
}

String? _cleanText(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final clean = _cleanText(value);
    if (clean != null) return clean;
  }
  return null;
}

class Wave {
  final String id;
  final String status;
  final DateTime createdAt;
  final String senderId;
  final WaveUser? sender;
  final WaveUser? receiver;

  Wave({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.senderId,
    this.sender,
    this.receiver,
  });

  factory Wave.fromJson(Map<String, dynamic> json, {bool isReceived = false}) {
    return Wave(
      id: json['id'],
      status: json['status'],
      createdAt: DateTime.parse(json['created_at']),
      senderId: json['sender_id'],
      sender: isReceived && json['profiles'] != null
          ? WaveUser.fromJson(json['profiles'])
          : null,
    );
  }
}

class WaveUser {
  final String id;
  final String? username;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;

  WaveUser({
    required this.id,
    this.username,
    this.displayName,
    this.avatarUrl,
    this.bio,
  });

  factory WaveUser.fromJson(Map<String, dynamic> json) {
    return WaveUser(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
      bio: json['bio'],
    );
  }
}

class AppNotification {
  final String id;
  final String? senderId;
  final String receiverId;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final bool isRead;
  final DateTime createdAt;
  final DateTime? readAt;
  final int groupedCount;

  AppNotification({
    required this.id,
    this.senderId,
    required this.receiverId,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.isRead,
    required this.createdAt,
    this.readAt,
    this.groupedCount = 1,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    final map = rawData is Map<String, dynamic>
        ? rawData
        : Map<String, dynamic>.from(rawData as Map? ?? const {});

    return AppNotification(
      id: json['id'].toString(),
      senderId: json['sender_id']?.toString(),
      receiverId: json['receiver_id'].toString(),
      type: json['type']?.toString() ?? 'system_alert',
      title: json['title']?.toString() ?? 'Notification',
      body: json['body']?.toString() ?? '',
      data: map,
      isRead: json['is_read'] == true,
      createdAt: DateTime.parse(json['created_at'].toString()),
      readAt: json['read_at'] != null
          ? DateTime.parse(json['read_at'].toString())
          : null,
      groupedCount: (json['grouped_count'] as num?)?.toInt() ?? 1,
    );
  }
}

class NotificationPreferenceSettings {
  final String? userId;
  final bool dmNotifications;
  final bool groupNotifications;
  final bool friendRequestNotifications;
  final bool mentionNotifications;
  final bool callNotifications;

  NotificationPreferenceSettings({
    this.userId,
    required this.dmNotifications,
    required this.groupNotifications,
    required this.friendRequestNotifications,
    required this.mentionNotifications,
    required this.callNotifications,
  });

  factory NotificationPreferenceSettings.defaults({String? userId}) {
    return NotificationPreferenceSettings(
      userId: userId,
      dmNotifications: true,
      groupNotifications: true,
      friendRequestNotifications: true,
      mentionNotifications: true,
      callNotifications: true,
    );
  }

  factory NotificationPreferenceSettings.fromJson(Map<String, dynamic> json) {
    return NotificationPreferenceSettings(
      userId: json['user_id']?.toString(),
      dmNotifications: json['dm_notifications'] != false,
      groupNotifications: json['group_notifications'] != false,
      friendRequestNotifications: json['friend_request_notifications'] != false,
      mentionNotifications: json['mention_notifications'] != false,
      callNotifications: json['call_notifications'] != false,
    );
  }
}

class Conversation {
  final String id;
  final DateTime? lastMessageAt;
  final String user1Id;
  final String user2Id;
  final ConversationUser? otherUser;
  final Message? lastMessage;
  final int unreadCount;

  Conversation({
    required this.id,
    this.lastMessageAt,
    required this.user1Id,
    required this.user2Id,
    this.otherUser,
    this.lastMessage,
    this.unreadCount = 0,
  });

  factory Conversation.fromJson(
    Map<String, dynamic> json, {
    required String currentUserId,
    Map<String, dynamic>? otherUserData,
  }) {
    final otherUserId = json['user1_id'] == currentUserId
        ? json['user2_id']
        : json['user1_id'];

    Message? lastMsg;
    int unread =
        (json['unread_count'] as num?)?.toInt() ??
        (json['unreadCount'] as num?)?.toInt() ??
        0;
    if (json['messages'] != null && (json['messages'] as List).isNotEmpty) {
      final messages = json['messages'] as List;
      messages.sort((a, b) => b['created_at'].compareTo(a['created_at']));
      lastMsg = Message.fromJson(messages.first);

      // Count unread messages (not sent by current user and not read)
      unread = unread > 0
          ? unread
          : messages
                .where(
                  (m) =>
                      m['sender_id'] != currentUserId &&
                      (m['is_read'] == false || m['is_read'] == null),
                )
                .length;
    } else if (json['last_message'] != null || json['lastMessage'] != null) {
      final createdAt =
          json['last_message_at'] ??
          json['lastMessageAt'] ??
          json['updated_at'] ??
          json['created_at'];
      lastMsg = Message(
        id: '${json['id']}_last',
        content: (json['last_message'] ?? json['lastMessage'] ?? '').toString(),
        isRead: unread == 0,
        createdAt: createdAt != null
            ? DateTime.parse(createdAt.toString())
            : DateTime.now(),
        senderId: '',
      );
    }

    ConversationUser? otherUser;
    if (otherUserData != null) {
      otherUser = ConversationUser.fromJson(otherUserData);
    } else if (otherUserId != null) {
      otherUser = ConversationUser(id: otherUserId);
    }

    return Conversation(
      id: json['id'],
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'].toString())
          : json['lastMessageAt'] != null
          ? DateTime.parse(json['lastMessageAt'].toString())
          : null,
      user1Id: json['user1_id'],
      user2Id: json['user2_id'],
      otherUser: otherUser,
      lastMessage: lastMsg,
      unreadCount: unread,
    );
  }
}

class ConversationUser {
  final String id;
  final String? username;
  final String? displayName;
  final String? avatarUrl;

  ConversationUser({
    required this.id,
    this.username,
    this.displayName,
    this.avatarUrl,
  });

  factory ConversationUser.fromJson(Map<String, dynamic> json) {
    return ConversationUser(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
    );
  }
}

class Message {
  final String id;
  final String content;
  final String? mediaUrl;
  final String? mediaType;
  final bool isRead;
  final DateTime createdAt;
  final String senderId;
  final DateTime? deliveredAt;
  final DateTime? seenAt;
  final String? replyToId;
  final bool deletedForEveryone;
  final double? sharedLatitude;
  final double? sharedLongitude;

  Message({
    required this.id,
    required this.content,
    this.mediaUrl,
    this.mediaType,
    required this.isRead,
    required this.createdAt,
    required this.senderId,
    this.deliveredAt,
    this.seenAt,
    this.replyToId,
    this.deletedForEveryone = false,
    this.sharedLatitude,
    this.sharedLongitude,
  });

  MessageStatus get status {
    if (seenAt != null) return MessageStatus.seen;
    if (deliveredAt != null) return MessageStatus.delivered;
    return MessageStatus.sent;
  }

  bool get isLocationMessage => mediaType == 'location';
  bool get isDeleted => deletedForEveryone;

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'],
      content: json['content'] ?? '',
      mediaUrl: json['media_url'],
      mediaType: json['media_type'],
      isRead: json['is_read'] ?? false,
      createdAt: DateTime.parse(json['created_at']),
      senderId: json['sender_id'],
      deliveredAt: json['delivered_at'] != null
          ? DateTime.parse(json['delivered_at'])
          : null,
      seenAt: json['seen_at'] != null ? DateTime.parse(json['seen_at']) : null,
      replyToId: json['reply_to_id'],
      deletedForEveryone: json['deleted_for_everyone'] ?? false,
      sharedLatitude: (json['shared_latitude'] as num?)?.toDouble(),
      sharedLongitude: (json['shared_longitude'] as num?)?.toDouble(),
    );
  }
}

enum MessageStatus {
  sent, // Single tick - message sent but not delivered
  delivered, // Double tick grey - message delivered
  seen, // Double tick blue - message seen
}

class GroupMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String content;
  final DateTime createdAt;
  final String? senderDisplayName;
  final String? senderUsername;
  final String? senderAvatarUrl;

  GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.content,
    required this.createdAt,
    this.senderDisplayName,
    this.senderUsername,
    this.senderAvatarUrl,
  });

  String get senderLabel {
    final d = senderDisplayName?.trim();
    if (d != null && d.isNotEmpty) return d;
    final u = senderUsername?.trim();
    if (u != null && u.isNotEmpty) return u;
    return 'Member';
  }

  factory GroupMessage.fromJson(Map<String, dynamic> json) {
    dynamic prof = json['profiles'];
    if (prof is List && prof.isNotEmpty) {
      prof = prof.first;
    }
    Map<String, dynamic>? pmap;
    if (prof is Map) {
      pmap = Map<String, dynamic>.from(prof);
    }

    return GroupMessage(
      id: json['id'].toString(),
      groupId: json['group_id'].toString(),
      senderId: json['sender_id'].toString(),
      content: json['content'] as String? ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
      senderDisplayName: pmap?['display_name'] as String?,
      senderUsername: pmap?['username'] as String?,
      senderAvatarUrl: pmap?['avatar_url'] as String?,
    );
  }
}

class GroupMember {
  final String id;
  final String role;
  final DateTime joinedAt;
  final GroupMemberUser user;

  GroupMember({
    required this.id,
    required this.role,
    required this.joinedAt,
    required this.user,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      id: json['id'],
      role: json['role'],
      joinedAt: DateTime.parse(json['joined_at']),
      user: GroupMemberUser.fromJson(json['profiles']),
    );
  }
}

class GroupMemberUser {
  final String id;
  final String? username;
  final String? displayName;
  final String? avatarUrl;

  GroupMemberUser({
    required this.id,
    this.username,
    this.displayName,
    this.avatarUrl,
  });

  factory GroupMemberUser.fromJson(Map<String, dynamic> json) {
    return GroupMemberUser(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
    );
  }
}

class UserProfile {
  final String id;
  final String? email;
  final String? username;
  final String? fullName;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final String? locationText;
  final double? latitude;
  final double? longitude;
  final DateTime? lastSeen;
  final String? locationPrecision;

  UserProfile({
    required this.id,
    this.email,
    this.username,
    this.fullName,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.locationText,
    this.latitude,
    this.longitude,
    this.lastSeen,
    this.locationPrecision,
  });

  bool get isOnline {
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen!).inMinutes < 5;
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'],
      email: json['email'],
      username: json['username'],
      fullName: json['full_name'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
      bio: json['bio'],
      locationText: json['location_text'],
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      lastSeen: json['last_seen'] != null
          ? DateTime.parse(json['last_seen'])
          : null,
      locationPrecision: json['location_precision'],
    );
  }
}

class MutualFriend {
  final String id;
  final String? username;
  final String? displayName;
  final String? avatarUrl;

  MutualFriend({
    required this.id,
    this.username,
    this.displayName,
    this.avatarUrl,
  });

  factory MutualFriend.fromJson(Map<String, dynamic> json) {
    return MutualFriend(
      id: json['id'],
      username: json['username'],
      displayName: json['display_name'],
      avatarUrl: json['avatar_url'],
    );
  }
}
