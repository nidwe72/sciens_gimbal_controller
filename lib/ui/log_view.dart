import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/gimbal_connection.dart';

class LogView extends ConsumerStatefulWidget {
  const LogView({super.key});

  @override
  ConsumerState<LogView> createState() => _LogViewState();
}

class _LogViewState extends ConsumerState<LogView> {
  final _scrollController = ScrollController();
  int _lastSeenLength = 0;
  bool _showRx = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(gimbalConnectionProvider);
    final allEntries = conn.log;
    final entries = _showRx
        ? allEntries
        : allEntries
            .where((e) => e.direction != LogDirection.rx)
            .toList(growable: false);

    // Autoscroll to bottom when new entries arrive.
    if (entries.length != _lastSeenLength) {
      _lastSeenLength = entries.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        }
      });
    }

    final theme = Theme.of(context);
    final hiddenCount = allEntries.length - entries.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Text(
                _showRx
                    ? 'Log (${entries.length})'
                    : 'Log (${entries.length}, $hiddenCount RX hidden)',
                style: theme.textTheme.labelLarge,
              ),
              const Spacer(),
              FilterChip(
                label: const Text('RX'),
                selected: _showRx,
                onSelected: (v) => setState(() => _showRx = v),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed:
                    allEntries.isEmpty ? null : () => conn.clearLog(),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'No log entries yet',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _LogRow(entry: entries[i]),
                ),
        ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});
  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (entry.direction) {
      LogDirection.tx => Colors.blue.shade700,
      LogDirection.rx => Colors.green.shade700,
      LogDirection.info => Colors.grey.shade600,
      LogDirection.error => theme.colorScheme.error,
    };
    final tag = switch (entry.direction) {
      LogDirection.tx => 'TX',
      LogDirection.rx => 'RX',
      LogDirection.info => 'ii',
      LogDirection.error => '!!',
    };
    final time = entry.time;
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
    final body =
        entry.bytes != null ? formatHex(entry.bytes!) : (entry.message ?? '');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          children: [
            TextSpan(
              text: '$timeStr ',
              style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
            TextSpan(
              text: '$tag ',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            TextSpan(text: body),
          ],
        ),
      ),
    );
  }
}
