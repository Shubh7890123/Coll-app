import 'dart:async';
import 'package:flutter/material.dart';
import '../data_service.dart';
import '../supabase_service.dart';

class StoryViewerScreen extends StatefulWidget {
  final List<Story> stories;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    this.initialIndex = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with TickerProviderStateMixin {
  late int _currentIndex;
  late AnimationController _progressController;
  late AnimationController _swipeController;
  Timer? _viewTimer;
  Offset _dragStart = Offset.zero;
  double _dragOffset = 0;
  bool _isOwnStory = false;

  static const _storyDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.stories.length - 1);
    _progressController = AnimationController(
      vsync: this,
      duration: _storyDuration,
    )..addStatusListener(_onProgressStatus);
    _swipeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _loadStory();
  }

  void _onProgressStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _goToNext();
    }
  }

  void _loadStory() {
    _progressController.reset();
    _progressController.forward();
    _checkOwnStory();
    _markViewed();
  }

  void _checkOwnStory() {
    final currentUserId = SupabaseService().client.auth.currentUser?.id;
    _isOwnStory = widget.stories[_currentIndex].userId == currentUserId;
  }

  void _markViewed() {
    final story = widget.stories[_currentIndex];
    DataService().markStoryViewed(story.id);
  }

  void _goToNext() {
    if (_currentIndex < widget.stories.length - 1) {
      setState(() {
        _currentIndex++;
      });
      _loadStory();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _goToPrevious() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
      _loadStory();
    } else {
      _progressController.reset();
      _progressController.forward();
    }
  }

  void _onTap(TapDownDetails details) {
    final width = MediaQuery.of(context).size.width;
    if (details.globalPosition.dx < width / 3) {
      _goToPrevious();
    } else {
      _goToNext();
    }
  }

  void _onPanStart(DragStartDetails details) {
    _dragStart = details.globalPosition;
    _progressController.stop();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final dy = details.globalPosition.dy - _dragStart.dy;
    if (dy > 0) {
      setState(() {
        _dragOffset = dy;
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_dragOffset > 100) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _dragOffset = 0;
      });
      _progressController.forward();
    }
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inHours > 0) return '${diff.inHours}h';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m';
    return 'now';
  }

  void _deleteStory() async {
    final story = widget.stories[_currentIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Story'),
        content: const Text('Are you sure you want to delete this story?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await DataService().deleteStory(story.id);
      if (widget.stories.length <= 1) {
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() {
          widget.stories.removeAt(_currentIndex);
          if (_currentIndex >= widget.stories.length) {
            _currentIndex = widget.stories.length - 1;
          }
        });
        _loadStory();
      }
    }
  }

  @override
  void dispose() {
    _progressController.dispose();
    _swipeController.dispose();
    _viewTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.stories[_currentIndex];
    final isVideo = story.mediaType == 'video';

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: _onTap,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          transform: Matrix4.translationValues(0, _dragOffset, 0)
            ..setEntry(0, 0, 1 - (_dragOffset / 1000).clamp(0, 0.1))
            ..setEntry(1, 1, 1 - (_dragOffset / 1000).clamp(0, 0.1)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildMedia(story, isVideo),
              _buildProgressBar(),
              _buildHeader(story),
              if (story.caption != null && story.caption!.isNotEmpty)
                _buildCaption(story),
              if (_isOwnStory && story.viewCount > 0) _buildViewCount(story),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMedia(Story story, bool isVideo) {
    if (isVideo) {
      return Center(
        child: Icon(
          Icons.play_circle_outline,
          color: Colors.white.withValues(alpha: 0.5),
          size: 64,
        ),
      );
    }
    return Image.network(
      story.mediaUrl,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
      ),
      loadingBuilder: (_, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Center(
          child: CircularProgressIndicator(
            value: loadingProgress.expectedTotalBytes != null
                ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                : null,
            color: Colors.white,
          ),
        );
      },
    );
  }

  Widget _buildProgressBar() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 4,
      left: 8,
      right: 8,
      child: Row(
        children: List.generate(widget.stories.length, (index) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedBuilder(
                animation: _progressController,
                builder: (context, _) {
                  double value;
                  if (index < _currentIndex) {
                    value = 1.0;
                  } else if (index == _currentIndex) {
                    value = _progressController.value;
                  } else {
                    value = 0.0;
                  }
                  return LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.white,
                    ),
                    minHeight: 2.5,
                    borderRadius: BorderRadius.circular(1.25),
                  );
                },
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildHeader(Story story) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 8,
      right: 8,
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundImage: story.user.avatarUrl != null
                ? NetworkImage(story.user.avatarUrl!)
                : null,
            backgroundColor: Colors.white24,
            child: story.user.avatarUrl == null
                ? Text(
                    (story.user.displayName ?? story.user.username ?? '?')
                        .substring(0, 1)
                        .toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  story.user.displayName ?? story.user.username ?? 'Unknown',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                Text(
                  _timeAgo(story.createdAt),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (_isOwnStory)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white),
              onPressed: _deleteStory,
            ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildCaption(Story story) {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 32,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          story.caption!,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildViewCount(Story story) {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 8,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.remove_red_eye, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Text(
              '${story.viewCount}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
