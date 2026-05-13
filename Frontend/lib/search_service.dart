import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';
import 'models/search_result.dart';

class SearchService {
  static final SearchService _instance = SearchService._internal();
  factory SearchService() => _instance;
  SearchService._internal();

  final SupabaseClient _client = SupabaseService().client;

  Timer? _debounce;
  String _lastQuery = '';
  GlobalSearchResult? _cachedResult;

  static const int _debounceMs = 300;
  static const String _recentSearchesKey = 'colony_recent_searches';
  static const int _maxRecentSearches = 10;

  void dispose() {
    _debounce?.cancel();
  }

  void searchWithDebounce(
    String query, {
    required void Function(GlobalSearchResult) onResult,
    required void Function() onLoading,
  }) {
    _debounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _cachedResult = null;
      _lastQuery = '';
      onResult(GlobalSearchResult.empty());
      return;
    }
    if (trimmed == _lastQuery && _cachedResult != null) {
      onResult(_cachedResult!);
      return;
    }
    onLoading();
    _debounce = Timer(const Duration(milliseconds: _debounceMs), () async {
      final result = await globalSearch(trimmed);
      _lastQuery = trimmed;
      _cachedResult = result;
      onResult(result);
    });
  }

  Future<GlobalSearchResult> globalSearch(String query) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null || query.trim().isEmpty) {
        return GlobalSearchResult.empty();
      }

      final response = await _client.rpc(
        'global_search',
        params: {
          'p_query': query.trim(),
          'p_limit': 20,
          'p_user_id': user.id,
          'p_category': 'top',
        },
      );

      if (response == null || response is! List) {
        return GlobalSearchResult.empty();
      }

      final List<dynamic> rows = response;
      final List<UserSearchResult> users = [];
      final List<GroupSearchResult> groups = [];
      final List<SearchItemModel> top = [];

      for (final row in rows) {
        final map = row as Map<String, dynamic>;
        final type = map['type'] as String? ?? '';

        if (type == 'user') {
          final u = UserSearchResult.fromJson(map);
          users.add(u);
          top.add(UserSearchItemModel(u));
        } else if (type == 'group') {
          final g = GroupSearchResult.fromJson(map);
          groups.add(g);
          top.add(GroupSearchItemModel(g));
        }
      }

      return GlobalSearchResult(users: users, groups: groups, top: top);
    } catch (e) {
      print('Error in global search: $e');
      return GlobalSearchResult.empty();
    }
  }

  Future<List<UserSearchResult>> getTrendingUsers() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final response = await _client.rpc(
        'get_trending_users',
        params: {'p_limit': 10, 'p_user_id': user.id},
      );

      return (response as List? ?? [])
          .map((j) => UserSearchResult.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error fetching trending users: $e');
      return [];
    }
  }

  Future<List<GroupSearchResult>> getTrendingGroups() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return [];

      final response = await _client.rpc(
        'get_trending_groups',
        params: {'p_limit': 10, 'p_user_id': user.id},
      );

      return (response as List? ?? [])
          .map((j) => GroupSearchResult.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error fetching trending groups: $e');
      return [];
    }
  }

  Future<void> saveRecentSearch(String query) async {
    if (query.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final recent = prefs.getStringList(_recentSearchesKey) ?? [];
    recent.removeWhere((s) => s.toLowerCase() == query.trim().toLowerCase());
    recent.insert(0, query.trim());
    if (recent.length > _maxRecentSearches) {
      recent.removeRange(_maxRecentSearches, recent.length);
    }
    await prefs.setStringList(_recentSearchesKey, recent);
  }

  Future<List<String>> getRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_recentSearchesKey) ?? [];
  }

  Future<void> clearRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentSearchesKey);
  }

  Future<void> removeRecentSearch(String query) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = prefs.getStringList(_recentSearchesKey) ?? [];
    recent.removeWhere((s) => s.toLowerCase() == query.toLowerCase());
    await prefs.setStringList(_recentSearchesKey, recent);
  }

  void clearCache() {
    _cachedResult = null;
    _lastQuery = '';
  }
}

