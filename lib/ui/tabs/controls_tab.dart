import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/gimbal_connection.dart';
import '../gimbal_visualization.dart';

/// First Playground tab. Hosts the 3D visualization (top) plus the
/// orientation status line and the pan/tilt/level controls. Uses
/// AutomaticKeepAliveClientMixin so the visualization's smoothing
/// state survives switching to the logs tab.
class ControlsTab extends ConsumerStatefulWidget {
  const ControlsTab({
    super.key,
    required this.stepController,
    required this.onPanLeft,
    required this.onPanRight,
    required this.onTiltUp,
    required this.onTiltDown,
    required this.onLevel,
  });

  final TextEditingController stepController;
  final VoidCallback onPanLeft;
  final VoidCallback onPanRight;
  final VoidCallback onTiltUp;
  final VoidCallback onTiltDown;
  final VoidCallback onLevel;

  @override
  ConsumerState<ControlsTab> createState() => _ControlsTabState();
}

class _ControlsTabState extends ConsumerState<ControlsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final conn = ref.watch(gimbalConnectionProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 3D pose visualization. Takes the remaining vertical space
        // above the orientation line + controls panel below.
        const Expanded(child: GimbalVisualization()),
        const Divider(height: 1),
        _OrientationLine(conn: conn),
        const Divider(height: 1),
        _ControlsPanel(
          stepController: widget.stepController,
          enabled: conn.isConnected && !conn.moving,
          moving: conn.moving,
          onPanLeft: widget.onPanLeft,
          onPanRight: widget.onPanRight,
          onTiltUp: widget.onTiltUp,
          onTiltDown: widget.onTiltDown,
          onLevel: widget.onLevel,
        ),
      ],
    );
  }
}

class _OrientationLine extends StatelessWidget {
  const _OrientationLine({required this.conn});
  final GimbalConnection conn;

  String _fmt(double? v) =>
      v == null ? '—' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}°';

  String _modeName(int? mode) {
    if (mode == null) return '—';
    switch (mode) {
      case 0:
        return 'PF';
      case 1:
        return 'PTF';
      case 2:
        return 'FPV';
      case 3:
        return 'LK';
      case 4:
        return 'FFC';
      default:
        return 'mode$mode';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = conn.orientationAt != null;
    final age = hasData
        ? DateTime.now().difference(conn.orientationAt!).inMilliseconds
        : null;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _angleBox(theme, 'Yaw', conn.yawDeg)),
              Expanded(child: _angleBox(theme, 'Pitch', conn.pitchDeg)),
              Expanded(child: _angleBox(theme, 'Roll', conn.rollDeg)),
              if (age != null)
                Text(
                  '${age}ms ago',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                )
              else
                Text(
                  'waiting...',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'mode: ${_modeName(conn.followMode)}'
            '${conn.followMode != null ? " (${conn.followMode})" : ""}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _angleBox(ThemeData theme, String label, double? value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        Text(
          _fmt(value),
          style: theme.textTheme.titleMedium?.copyWith(
            fontFamily: 'monospace',
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ControlsPanel extends StatelessWidget {
  const _ControlsPanel({
    required this.stepController,
    required this.enabled,
    required this.moving,
    required this.onPanLeft,
    required this.onPanRight,
    required this.onTiltUp,
    required this.onTiltDown,
    required this.onLevel,
  });
  final TextEditingController stepController;
  final bool enabled;
  final bool moving;
  final VoidCallback onPanLeft;
  final VoidCallback onPanRight;
  final VoidCallback onTiltUp;
  final VoidCallback onTiltDown;
  final VoidCallback onLevel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Step:', style: theme.textTheme.labelLarge),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: stepController,
                  enabled: enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: false),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: '°',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              if (moving) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                Text('moving...', style: theme.textTheme.bodySmall),
              ],
              const Spacer(),
              FilledButton.icon(
                onPressed: enabled ? onLevel : null,
                icon: const Icon(Icons.home),
                label: const Text('Level'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? onPanLeft : null,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Pan'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? onPanRight : null,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Pan'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? onTiltDown : null,
                  icon: const Icon(Icons.arrow_downward),
                  label: const Text('Tilt'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled ? onTiltUp : null,
                  icon: const Icon(Icons.arrow_upward),
                  label: const Text('Tilt'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
