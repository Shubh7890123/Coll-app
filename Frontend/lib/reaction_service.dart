import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Service for managing message reactions (like Telegram)
class ReactionService {
  static final ReactionService _instance = ReactionService._internal();
  factory ReactionService() => _instance;
  ReactionService._internal();

  final SupabaseClient _client = SupabaseService().client;

  /// Add a reaction to a message
  Future<bool> addReaction({
    required String messageId,
    required String emoji,
    bool isGroupMessage = false,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client.from('message_reactions').insert({
        'message_id': messageId,
        'user_id': user.id,
        'emoji': emoji,
      });

      return true;
    } catch (e) {
      print('Error adding reaction: $e');
      return false;
    }
  }

  /// Remove a reaction from a message
  Future<bool> removeReaction({
    required String messageId,
    required String emoji,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client
          .from('message_reactions')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', user.id)
          .eq('emoji', emoji);

      return true;
    } catch (e) {
      print('Error removing reaction: $e');
      return false;
    }
  }

  /// Toggle a reaction (add if not exists, remove if exists)
  Future<bool> toggleReaction({
    required String messageId,
    required String emoji,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      // Check if reaction exists
      final existing = await _client
          .from('message_reactions')
          .select('id')
          .eq('message_id', messageId)
          .eq('user_id', user.id)
          .eq('emoji', emoji)
          .maybeSingle();

      if (existing != null) {
        // Remove existing reaction
        return removeReaction(messageId: messageId, emoji: emoji);
      } else {
        // Add new reaction
        return addReaction(messageId: messageId, emoji: emoji);
      }
    } catch (e) {
      print('Error toggling reaction: $e');
      return false;
    }
  }

  /// Get reactions for a message
  Future<Map<String, ReactionInfo>> getReactions(String messageId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return {};

      final response = await _client
          .from('message_reactions')
          .select('emoji, user_id')
          .eq('message_id', messageId);

      final reactions = <String, ReactionInfo>{};

      for (final row in response as List) {
        final emoji = row['emoji'] as String;
        final reactorId = row['user_id'] as String;

        if (!reactions.containsKey(emoji)) {
          reactions[emoji] = ReactionInfo(
            emoji: emoji,
            count: 0,
            userIds: [],
            currentUserReacted: false,
          );
        }

        reactions[emoji]!.count++;
        reactions[emoji]!.userIds.add(reactorId);

        if (reactorId == user.id) {
          reactions[emoji]!.currentUserReacted = true;
        }
      }

      return reactions;
    } catch (e) {
      print('Error getting reactions: $e');
      return {};
    }
  }

  /// Get reactions for multiple messages (batch)
  Future<Map<String, Map<String, ReactionInfo>>> getReactionsForMessages(
    List<String> messageIds,
  ) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null || messageIds.isEmpty) return {};

      final response = await _client
          .from('message_reactions')
          .select('message_id, emoji, user_id')
          .inFilter('message_id', messageIds);

      final result = <String, Map<String, ReactionInfo>>{};

      for (final row in response as List) {
        final messageId = row['message_id'] as String;
        final emoji = row['emoji'] as String;
        final reactorId = row['user_id'] as String;

        result.putIfAbsent(messageId, () => {});

        if (!result[messageId]!.containsKey(emoji)) {
          result[messageId]![emoji] = ReactionInfo(
            emoji: emoji,
            count: 0,
            userIds: [],
            currentUserReacted: false,
          );
        }

        result[messageId]![emoji]!.count++;
        result[messageId]![emoji]!.userIds.add(reactorId);

        if (reactorId == user.id) {
          result[messageId]![emoji]!.currentUserReacted = true;
        }
      }

      return result;
    } catch (e) {
      print('Error getting reactions batch: $e');
      return {};
    }
  }

  /// Subscribe to reaction changes for a message
  RealtimeChannel subscribeToReactions(
    String messageId,
    Function(Map<String, ReactionInfo>) onUpdate,
  ) {
    return _client
        .channel('reactions_$messageId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'message_reactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'message_id',
            value: messageId,
          ),
          callback: (payload) async {
            final reactions = await getReactions(messageId);
            onUpdate(reactions);
          },
        )
        .subscribe();
  }
}

/// Model for reaction information
class ReactionInfo {
  final String emoji;
  int count;
  final List<String> userIds;
  bool currentUserReacted;

  ReactionInfo({
    required this.emoji,
    required this.count,
    required this.userIds,
    required this.currentUserReacted,
  });
}

/// Common emoji reactions for quick access
class CommonReactions {
  static const List<String> reactions = [
    '❤️',
    '👍',
    '👎',
    '😂',
    '😮',
    '😢',
    '🎉',
    '🔥',
    '👏',
    '🤔',
    '👀',
    '🙏',
    '🤣',
    '😍',
    '🤯',
  ];
}
