import 'package:flutter/material.dart';
import '../poll_service.dart';

/// Widget for displaying and voting on polls
class PollWidget extends StatefulWidget {
  final Poll poll;
  final Function()? onVote;
  final bool isCompact;

  const PollWidget({
    super.key,
    required this.poll,
    this.onVote,
    this.isCompact = false,
  });

  @override
  State<PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<PollWidget> {
  final PollService _pollService = PollService();
  PollResults? _results;
  List<int> _userVotes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPollData();
  }

  Future<void> _loadPollData() async {
    final results = await _pollService.getPollResults(widget.poll.id);
    final userVotes = await _pollService.getUserVotes(widget.poll.id);

    if (mounted) {
      setState(() {
        _results = results;
        _userVotes = userVotes;
        _isLoading = false;
      });
    }
  }

  Future<void> _vote(int optionIndex) async {
    if (!widget.poll.canVote) return;

    final success = await _pollService.voteOnPoll(
      pollId: widget.poll.id,
      optionIndex: optionIndex,
    );

    if (success) {
      await _loadPollData();
      widget.onVote?.call();
    }
  }

  Future<void> _removeVote(int optionIndex) async {
    final success = await _pollService.removeVote(widget.poll.id, optionIndex);
    if (success) {
      await _loadPollData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 100,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final hasVoted = _userVotes.isNotEmpty;
    final totalVotes = _results?.totalVotes ?? widget.poll.totalVotes;

    return Container(
      width: widget.isCompact ? null : 300,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Poll header
          Row(
            children: [
              Icon(
                Icons.poll,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'POLL',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const Spacer(),
              if (widget.poll.isAnonymous)
                Icon(Icons.visibility_off, size: 16, color: Colors.grey[600]),
            ],
          ),
          const SizedBox(height: 12),
          // Question
          Text(
            widget.poll.question,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          // Options
          ...widget.poll.options.asMap().entries.map((entry) {
            final index = entry.key;
            final option = entry.value;
            final voteCount = _results?.getVoteCount(index) ?? 0;
            final percentage = _results?.getVotePercentage(index) ?? 0;
            final isSelected = _userVotes.contains(index);

            return _PollOption(
              text: option.text,
              voteCount: voteCount,
              percentage: percentage,
              isSelected: isSelected,
              hasVoted: hasVoted,
              canVote: widget.poll.canVote,
              onTap: () => _vote(index),
              onRemoveVote: () => _removeVote(index),
            );
          }),
          const SizedBox(height: 12),
          // Footer
          Row(
            children: [
              Text(
                '$totalVotes votes',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const Spacer(),
              if (widget.poll.isClosed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('Closed', style: TextStyle(fontSize: 10)),
                )
              else if (widget.poll.isExpired)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Expired',
                    style: TextStyle(fontSize: 10, color: Colors.orange),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Individual poll option
class _PollOption extends StatelessWidget {
  final String text;
  final int voteCount;
  final double percentage;
  final bool isSelected;
  final bool hasVoted;
  final bool canVote;
  final VoidCallback onTap;
  final VoidCallback onRemoveVote;

  const _PollOption({
    required this.text,
    required this.voteCount,
    required this.percentage,
    required this.isSelected,
    required this.hasVoted,
    required this.canVote,
    required this.onTap,
    required this.onRemoveVote,
  });

  @override
  Widget build(BuildContext context) {
    final showResults = hasVoted || !canVote;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: canVote && !hasVoted ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: showResults
                ? Colors.grey.withOpacity(0.1)
                : isSelected
                ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                : Colors.grey.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.withOpacity(0.2),
            ),
          ),
          child: Stack(
            children: [
              // Progress bar background
              if (showResults)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: percentage / 100,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(
                                context,
                              ).colorScheme.primary.withOpacity(0.2)
                            : Colors.grey.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              // Content
              Row(
                children: [
                  if (showResults) ...[
                    Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (showResults) ...[
                    Text(
                      '${percentage.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey[700],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '($voteCount)',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ] else if (isSelected)
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Widget for creating a new poll
class PollCreator extends StatefulWidget {
  final String groupId;
  final Function(Poll)? onPollCreated;

  const PollCreator({super.key, required this.groupId, this.onPollCreated});

  @override
  State<PollCreator> createState() => _PollCreatorState();
}

class _PollCreatorState extends State<PollCreator> {
  final PollService _pollService = PollService();
  final _questionController = TextEditingController();
  final List<TextEditingController> _optionControllers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _isAnonymous = true;
  bool _allowsMultiple = false;
  bool _isCreating = false;

  @override
  void dispose() {
    _questionController.dispose();
    for (final controller in _optionControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _createPoll() async {
    if (_questionController.text.trim().isEmpty) return;

    final options = _optionControllers
        .where((c) => c.text.trim().isNotEmpty)
        .map((c) => c.text.trim())
        .toList();

    if (options.length < 2) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add at least 2 options')));
      return;
    }

    setState(() => _isCreating = true);

    final poll = await _pollService.createPoll(
      groupId: widget.groupId,
      question: _questionController.text.trim(),
      options: options,
      isAnonymous: _isAnonymous,
      allowsMultiple: _allowsMultiple,
    );

    setState(() => _isCreating = false);

    if (poll != null) {
      widget.onPollCreated?.call(poll);
      if (mounted) Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to create poll')));
    }
  }

  void _addOption() {
    if (_optionControllers.length < 10) {
      setState(() {
        _optionControllers.add(TextEditingController());
      });
    }
  }

  void _removeOption(int index) {
    if (_optionControllers.length > 2) {
      setState(() {
        _optionControllers[index].dispose();
        _optionControllers.removeAt(index);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        left: 16,
        right: 16,
        top: 16,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Title
          Text(
            'Create Poll',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          // Question
          TextField(
            controller: _questionController,
            decoration: InputDecoration(
              hintText: 'Ask a question...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.all(16),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          // Options
          Text('Options', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ..._optionControllers.asMap().entries.map((entry) {
            final index = entry.key;
            final controller = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      decoration: InputDecoration(
                        hintText: 'Option ${index + 1}',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  if (_optionControllers.length > 2)
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Colors.red,
                      ),
                      onPressed: () => _removeOption(index),
                    ),
                ],
              ),
            );
          }),
          // Add option button
          if (_optionControllers.length < 10)
            TextButton.icon(
              onPressed: _addOption,
              icon: const Icon(Icons.add),
              label: const Text('Add Option'),
            ),
          const SizedBox(height: 16),
          // Settings
          Row(
            children: [
              Checkbox(
                value: _isAnonymous,
                onChanged: (v) => setState(() => _isAnonymous = v ?? true),
              ),
              const Text('Anonymous'),
              const SizedBox(width: 16),
              Checkbox(
                value: _allowsMultiple,
                onChanged: (v) => setState(() => _allowsMultiple = v ?? false),
              ),
              const Text('Multiple choice'),
            ],
          ),
          const SizedBox(height: 16),
          // Create button
          ElevatedButton(
            onPressed: _isCreating ? null : _createPoll,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isCreating
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create Poll'),
          ),
        ],
      ),
    );
  }
}
