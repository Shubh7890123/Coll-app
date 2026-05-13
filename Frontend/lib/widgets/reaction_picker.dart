import 'package:flutter/material.dart';
import '../reaction_service.dart';

/// Widget for displaying and picking message reactions
class ReactionPicker extends StatelessWidget {
  final String messageId;
  final Map<String, ReactionInfo> reactions;
  final Function(String) onReactionSelected;
  final bool isCompact;

  const ReactionPicker({
    super.key,
    required this.messageId,
    required this.reactions,
    required this.onReactionSelected,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty && isCompact) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        // Existing reactions
        ...reactions.entries.map((entry) {
          final emoji = entry.key;
          final info = entry.value;
          return _ReactionChip(
            emoji: emoji,
            count: info.count,
            isSelected: info.currentUserReacted,
            onTap: () => onReactionSelected(emoji),
          );
        }),
        // Add reaction button
        _AddReactionButton(onTap: () => _showEmojiPicker(context)),
      ],
    );
  }

  void _showEmojiPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _EmojiPickerSheet(
        onEmojiSelected: (emoji) {
          Navigator.pop(context);
          onReactionSelected(emoji);
        },
      ),
    );
  }
}

/// Individual reaction chip
class _ReactionChip extends StatelessWidget {
  final String emoji;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
          : Colors.grey.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 4),
              Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Add reaction button
class _AddReactionButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddReactionButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.grey.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Icon(
            Icons.add_reaction_outlined,
            size: 16,
            color: Colors.grey[600],
          ),
        ),
      ),
    );
  }
}

/// Emoji picker bottom sheet
class _EmojiPickerSheet extends StatelessWidget {
  final Function(String) onEmojiSelected;

  const _EmojiPickerSheet({required this.onEmojiSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Add Reaction',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          // Quick reactions
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: CommonReactions.reactions.map((emoji) {
                return _EmojiButton(
                  emoji: emoji,
                  onTap: () => onEmojiSelected(emoji),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// Individual emoji button
class _EmojiButton extends StatelessWidget {
  final String emoji;
  final VoidCallback onTap;

  const _EmojiButton({required this.emoji, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          child: Text(emoji, style: const TextStyle(fontSize: 28)),
        ),
      ),
    );
  }
}

/// Reaction bar that shows on message long press
class ReactionBar extends StatelessWidget {
  final String messageId;
  final Function(String) onReactionSelected;
  final VoidCallback onMoreReactions;

  const ReactionBar({
    super.key,
    required this.messageId,
    required this.onReactionSelected,
    required this.onMoreReactions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quick reactions
          ...CommonReactions.reactions.take(6).map((emoji) {
            return _QuickReactionButton(
              emoji: emoji,
              onTap: () => onReactionSelected(emoji),
            );
          }),
          // Divider
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.grey[300],
          ),
          // More button
          _QuickReactionButton(emoji: '➕', onTap: onMoreReactions),
        ],
      ),
    );
  }
}

/// Quick reaction button for the reaction bar
class _QuickReactionButton extends StatelessWidget {
  final String emoji;
  final VoidCallback onTap;

  const _QuickReactionButton({required this.emoji, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(8),
          child: Text(emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
}
