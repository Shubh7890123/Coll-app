import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// Service for managing polls in groups (like Telegram)
class PollService {
  static final PollService _instance = PollService._internal();
  factory PollService() => _instance;
  PollService._internal();

  final SupabaseClient _client = SupabaseService().client;

  /// Create a new poll in a group
  Future<Poll?> createPoll({
    required String groupId,
    required String question,
    required List<String> options,
    bool isAnonymous = true,
    bool allowsMultiple = false,
    DateTime? closesAt,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final optionsJson = options
          .map((text) => {'text': text, 'votes': 0})
          .toList();

      final response = await _client
          .from('polls')
          .insert({
            'group_id': groupId,
            'created_by': user.id,
            'question': question,
            'options': optionsJson,
            'is_anonymous': isAnonymous,
            'allows_multiple': allowsMultiple,
            'closes_at': closesAt?.toUtc().toIso8601String(),
          })
          .select()
          .single();

      return Poll.fromJson(response);
    } catch (e) {
      print('Error creating poll: $e');
      return null;
    }
  }

  /// Get all polls for a group
  Future<List<Poll>> getGroupPolls(String groupId) async {
    try {
      final response = await _client
          .from('polls')
          .select('*')
          .eq('group_id', groupId)
          .order('created_at', ascending: false);

      return (response as List).map((json) => Poll.fromJson(json)).toList();
    } catch (e) {
      print('Error getting group polls: $e');
      return [];
    }
  }

  /// Get a single poll by ID
  Future<Poll?> getPoll(String pollId) async {
    try {
      final response = await _client
          .from('polls')
          .select('*')
          .eq('id', pollId)
          .single();

      return Poll.fromJson(response);
    } catch (e) {
      print('Error getting poll: $e');
      return null;
    }
  }

  /// Vote on a poll
  Future<bool> voteOnPoll({
    required String pollId,
    required int optionIndex,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      // Check if poll allows multiple votes
      final poll = await getPoll(pollId);
      if (poll == null) return false;

      if (poll.allowsMultiple) {
        // For multiple choice, just add the vote
        await _client.from('poll_votes').insert({
          'poll_id': pollId,
          'user_id': user.id,
          'option_index': optionIndex,
        });
      } else {
        // For single choice, remove existing vote first
        await _client
            .from('poll_votes')
            .delete()
            .eq('poll_id', pollId)
            .eq('user_id', user.id);

        // Then add new vote
        await _client.from('poll_votes').insert({
          'poll_id': pollId,
          'user_id': user.id,
          'option_index': optionIndex,
        });
      }

      return true;
    } catch (e) {
      print('Error voting on poll: $e');
      return false;
    }
  }

  /// Remove vote from a poll
  Future<bool> removeVote(String pollId, int optionIndex) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client
          .from('poll_votes')
          .delete()
          .eq('poll_id', pollId)
          .eq('user_id', user.id)
          .eq('option_index', optionIndex);

      return true;
    } catch (e) {
      print('Error removing vote: $e');
      return false;
    }
  }

  /// Get user's votes for a poll
  Future<List<int>> getUserVotes(String pollId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final response = await _client
          .from('poll_votes')
          .select('option_index')
          .eq('poll_id', pollId)
          .eq('user_id', user.id);

      return (response as List)
          .map((row) => row['option_index'] as int)
          .toList();
    } catch (e) {
      print('Error getting user votes: $e');
      return [];
    }
  }

  /// Close a poll (only creator can do this)
  Future<bool> closePoll(String pollId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client
          .from('polls')
          .update({'is_closed': true})
          .eq('id', pollId)
          .eq('created_by', user.id);

      return true;
    } catch (e) {
      print('Error closing poll: $e');
      return false;
    }
  }

  /// Delete a poll (only creator can do this)
  Future<bool> deletePoll(String pollId) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      await _client
          .from('polls')
          .delete()
          .eq('id', pollId)
          .eq('created_by', user.id);

      return true;
    } catch (e) {
      print('Error deleting poll: $e');
      return false;
    }
  }

  /// Get poll results with vote counts
  Future<PollResults?> getPollResults(String pollId) async {
    try {
      final poll = await getPoll(pollId);
      if (poll == null) return null;

      final votesResponse = await _client
          .from('poll_votes')
          .select('option_index, user_id')
          .eq('poll_id', pollId);

      final voteCounts = <int, int>{};
      final votersByOption = <int, List<String>>{};

      for (final row in votesResponse as List) {
        final optionIndex = row['option_index'] as int;
        final userId = row['user_id'] as String;

        voteCounts[optionIndex] = (voteCounts[optionIndex] ?? 0) + 1;
        votersByOption.putIfAbsent(optionIndex, () => []).add(userId);
      }

      return PollResults(
        poll: poll,
        voteCounts: voteCounts,
        votersByOption: votersByOption,
        totalVotes: votesResponse.length,
      );
    } catch (e) {
      print('Error getting poll results: $e');
      return null;
    }
  }

  /// Subscribe to poll updates
  RealtimeChannel subscribeToPoll(String pollId, Function(Poll) onUpdate) {
    return _client
        .channel('poll_$pollId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'polls',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: pollId,
          ),
          callback: (payload) async {
            final poll = await getPoll(pollId);
            if (poll != null) onUpdate(poll);
          },
        )
        .subscribe();
  }

  /// Subscribe to vote updates for a poll
  RealtimeChannel subscribeToVotes(String pollId, Function() onVoteUpdate) {
    return _client
        .channel('poll_votes_$pollId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'poll_votes',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'poll_id',
            value: pollId,
          ),
          callback: (payload) {
            onVoteUpdate();
          },
        )
        .subscribe();
  }
}

/// Poll model
class Poll {
  final String id;
  final String groupId;
  final String? createdBy;
  final String question;
  final List<PollOption> options;
  final bool isAnonymous;
  final bool allowsMultiple;
  final bool isClosed;
  final int totalVotes;
  final DateTime createdAt;
  final DateTime? closesAt;

  Poll({
    required this.id,
    required this.groupId,
    this.createdBy,
    required this.question,
    required this.options,
    required this.isAnonymous,
    required this.allowsMultiple,
    required this.isClosed,
    required this.totalVotes,
    required this.createdAt,
    this.closesAt,
  });

  factory Poll.fromJson(Map<String, dynamic> json) {
    final optionsList = json['options'] as List? ?? [];

    return Poll(
      id: json['id'],
      groupId: json['group_id'],
      createdBy: json['created_by'],
      question: json['question'],
      options: optionsList
          .map((opt) => PollOption.fromJson(opt as Map<String, dynamic>))
          .toList(),
      isAnonymous: json['is_anonymous'] ?? true,
      allowsMultiple: json['allows_multiple'] ?? false,
      isClosed: json['is_closed'] ?? false,
      totalVotes: json['total_votes'] ?? 0,
      createdAt: DateTime.parse(json['created_at']),
      closesAt: json['closes_at'] != null
          ? DateTime.parse(json['closes_at'])
          : null,
    );
  }

  bool get isExpired {
    if (closesAt == null) return false;
    return DateTime.now().isAfter(closesAt!);
  }

  bool get canVote => !isClosed && !isExpired;
}

/// Poll option model
class PollOption {
  final String text;
  int votes;

  PollOption({required this.text, this.votes = 0});

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      text: json['text'] as String,
      votes: json['votes'] as int? ?? 0,
    );
  }
}

/// Poll results model
class PollResults {
  final Poll poll;
  final Map<int, int> voteCounts;
  final Map<int, List<String>> votersByOption;
  final int totalVotes;

  PollResults({
    required this.poll,
    required this.voteCounts,
    required this.votersByOption,
    required this.totalVotes,
  });

  int getVoteCount(int optionIndex) {
    return voteCounts[optionIndex] ?? 0;
  }

  double getVotePercentage(int optionIndex) {
    if (totalVotes == 0) return 0;
    final count = getVoteCount(optionIndex);
    return (count / totalVotes) * 100;
  }

  bool didUserVote(String userId, int optionIndex) {
    return votersByOption[optionIndex]?.contains(userId) ?? false;
  }
}
