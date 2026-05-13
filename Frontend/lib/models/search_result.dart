enum FriendshipStatus {
  none,
  pendingSent,
  pendingReceived,
  friends,
}

/// Search result model for users
class UserSearchResult {
  final String id;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final String? locationText;
  final int followersCount;
  final bool isVerified;
  final int score;
  final int mutualFriendsCount;
  final FriendshipStatus friendshipStatus;
  final bool isMe;

  UserSearchResult({
    required this.id,
    required this.username,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.locationText,
    this.followersCount = 0,
    this.isVerified = false,
    this.score = 0,
    this.mutualFriendsCount = 0,
    this.friendshipStatus = FriendshipStatus.none,
    this.isMe = false,
  });

  factory UserSearchResult.fromJson(Map<String, dynamic> json) {
    return UserSearchResult(
      id: json['id']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? json['display_name']?.toString() ?? json['name']?.toString(),
      avatarUrl: json['avatarUrl']?.toString() ?? json['avatar_url']?.toString(),
      bio: json['bio']?.toString(),
      locationText: json['locationText']?.toString() ?? json['location_text']?.toString(),
      followersCount: (json['followersCount'] ?? json['followers_count'] as num?)?.toInt() ?? 0,
      isVerified: json['isVerified'] == true || json['is_verified'] == true,
      score: (json['score'] as num?)?.toInt() ?? 0,
      mutualFriendsCount: (json['mutualFriendsCount'] ?? json['mutual_friends_count'] as num?)?.toInt() ?? 0,
      friendshipStatus: _parseFriendshipStatus(json['friendshipStatus']?.toString() ?? json['friendship_status']?.toString()),
      isMe: json['isMe'] == true || json['is_me'] == true,
    );
  }

  String get displayNameOrUsername => (displayName != null && displayName!.isNotEmpty) ? displayName! : (username.isNotEmpty ? username : 'User');

  static FriendshipStatus _parseFriendshipStatus(String? status) {
    switch (status) {
      case 'pending_sent':
      case 'pending':
        return FriendshipStatus.pendingSent;
      case 'pending_received':
      case 'received':
        return FriendshipStatus.pendingReceived;
      case 'friends':
      case 'accepted':
        return FriendshipStatus.friends;
      default:
        return FriendshipStatus.none;
    }
  }
}

/// Search result model for groups
class GroupSearchResult {
  final String id;
  final String name;
  final String? description;
  final String? coverImageUrl;
  final int memberCount;
  final bool isPrivate;
  final String? category;
  final bool isMember;
  final int score;

  GroupSearchResult({
    required this.id,
    required this.name,
    this.description,
    this.coverImageUrl,
    this.memberCount = 0,
    this.isPrivate = false,
    this.category,
    this.isMember = false,
    this.score = 0,
  });

  factory GroupSearchResult.fromJson(Map<String, dynamic> json) {
    return GroupSearchResult(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['group_name']?.toString() ?? '',
      description: json['description']?.toString() ?? json['group_description']?.toString(),
      coverImageUrl: json['coverImageUrl']?.toString() ?? json['cover_image_url']?.toString(),
      memberCount: (json['memberCount'] ?? json['member_count'] as num?)?.toInt() ?? 0,
      isPrivate: json['isPrivate'] == true || json['is_private'] == true,
      category: json['category']?.toString(),
      isMember: json['isMember'] == true || json['is_member'] == true,
      score: (json['score'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Aggregated search results
class GlobalSearchResult {
  final List<UserSearchResult> users;
  final List<GroupSearchResult> groups;
  final List<SearchItemModel> top;

  const GlobalSearchResult({
    required this.users,
    required this.groups,
    required this.top,
  });

  factory GlobalSearchResult.empty() => const GlobalSearchResult(users: [], groups: [], top: []);

  bool get isEmpty => users.isEmpty && groups.isEmpty && top.isEmpty;
}

/// Abstract item for top results
abstract class SearchItemModel {
  String get type;
  int get score;
}

class UserSearchItemModel extends SearchItemModel {
  final UserSearchResult user;
  UserSearchItemModel(this.user);

  @override
  String get type => 'user';
  @override
  int get score => user.score;
}

class GroupSearchItemModel extends SearchItemModel {
  final GroupSearchResult group;
  GroupSearchItemModel(this.group);

  @override
  String get type => 'group';
  @override
  int get score => group.score;
}
