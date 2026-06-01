import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../camera/camera_connection.dart';
import '../../panorama/panorama_grid.dart';
import '../../state/gimbal_connection.dart';
import '../../state/panorama_controller.dart';

/// The 'Pano' sub-tab inside the Camera tab. Brenizer inputs + a live
/// tile grid + Take/Cancel, wired to [PanoramaController]. See
/// SPEC-flutter-app.md "Phase 4 — UI — the 'Pano' sub-tab".
class PanoTab extends ConsumerStatefulWidget {
  const PanoTab({super.key});

  @override
  ConsumerState<PanoTab> createState() => _PanoTabState();
}

class _PanoTabState extends ConsumerState<PanoTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final pano = ref.watch(panoramaControllerProvider);
    final gimbalConnected =
        ref.watch(gimbalConnectionProvider.select((c) => c.isConnected));
    final cameraConnected =
        ref.watch(cameraConnectionProvider.select((c) => c.isConnected));
    final grid = pano.grid;
    final locked = pano.running;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!gimbalConnected || !cameraConnected)
          _ConnectHint(
            gimbalConnected: gimbalConnected,
            cameraConnected: cameraConnected,
          ),
        _FocalSlider(
          label: 'Taking-lens focal',
          value: pano.focalTaking,
          min: 50,
          max: 150,
          unit: 'mm',
          enabled: !locked,
          onChanged: (v) => ref
              .read(panoramaControllerProvider)
              .updateSettings(focalTaking: v),
        ),
        _FocalSlider(
          label: 'Stitched-image focal',
          value: pano.focalStitch,
          min: 24,
          max: 100,
          unit: 'mm',
          enabled: !locked,
          onChanged: (v) => ref
              .read(panoramaControllerProvider)
              .updateSettings(focalStitch: v),
        ),
        _FocalSlider(
          label: 'Overlap',
          value: pano.overlap * 100,
          min: 0,
          max: kOverlapMax * 100,
          unit: '%',
          enabled: !locked,
          onChanged: (v) => ref
              .read(panoramaControllerProvider)
              .updateSettings(overlap: v / 100),
        ),
        _FocalSlider(
          label: 'Settle delay',
          value: pano.settleSeconds.toDouble(),
          min: 0,
          max: 10,
          divisions: 10,
          unit: 's',
          decimals: 0,
          enabled: !locked,
          onChanged: (v) => ref
              .read(panoramaControllerProvider)
              .updateSettings(settleSeconds: v.round()),
        ),
        const SizedBox(height: 8),
        _GridSummary(grid: grid, state: pano.state, message: pano.message),
        const SizedBox(height: 12),
        _TileGridView(
          grid: grid,
          tileStates: pano.tileStates,
          currentIndex: pano.currentIndex,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: pano.canStart
                    ? () => ref.read(panoramaControllerProvider).start()
                    : null,
                icon: const Icon(Icons.panorama_horizontal),
                label: const Text('Take panorama'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: pano.running
                    ? () => ref.read(panoramaControllerProvider).cancel()
                    : null,
                icon: const Icon(Icons.stop),
                label: Text(pano.state == PanoState.cancelling
                    ? 'Cancelling…'
                    : 'Cancel'),
              ),
            ),
          ],
        ),
        if (!grid.canRun && gimbalConnected && cameraConnected)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              grid.overCap
                  ? 'Too many tiles (${grid.totalShots} > $kPanoMaxTileCount). '
                      'Use a wider stitched focal or shorter taking lens.'
                  : 'These focals barely exceed one frame — nothing to '
                      'stitch. Widen the gap between the two focals.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _ConnectHint extends StatelessWidget {
  const _ConnectHint({
    required this.gimbalConnected,
    required this.cameraConnected,
  });

  final bool gimbalConnected;
  final bool cameraConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = <String>[
      if (!gimbalConnected) 'gimbal',
      if (!cameraConnected) 'camera',
    ].join(' + ');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connect the $missing to run a panorama. '
              '(The virtual/demo gimbal works too.)',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _FocalSlider extends StatelessWidget {
  const _FocalSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.enabled,
    required this.onChanged,
    this.divisions,
    this.decimals = 0,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final bool enabled;
  final int? divisions;
  final int decimals;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            Text('${value.toStringAsFixed(decimals)} $unit',
                style: theme.textTheme.labelLarge),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}

class _GridSummary extends StatelessWidget {
  const _GridSummary({
    required this.grid,
    required this.state,
    required this.message,
  });

  final PanoramaGrid grid;
  final PanoState state;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = grid.warnCount && !grid.overCap;
    return Row(
      children: [
        Text(
          '${grid.nCols} × ${grid.nRows}  =  ${grid.totalShots} shots',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(width: 12),
        if (warn)
          Text('⚠ large run',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.tertiary)),
        const Spacer(),
        if (message != null)
          Flexible(
            child: Text(
              message!,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: state == PanoState.aborted
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// Cell grid: redraws on settings change; cells recolour as the run
/// captures each tile.
class _TileGridView extends StatelessWidget {
  const _TileGridView({
    required this.grid,
    required this.tileStates,
    required this.currentIndex,
  });

  final PanoramaGrid grid;
  final List<TileState> tileStates;
  final int currentIndex;

  TileState _stateForIndex(int index) =>
      index < tileStates.length ? tileStates[index] : TileState.pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Resolve grid coordinates → serpentine index for colour lookup.
    final indexByRowCol = <int, int>{};
    for (final t in grid.tiles) {
      indexByRowCol[t.row * grid.nCols + t.col] = t.index;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 3.0;
        final cellW =
            (constraints.maxWidth - spacing * (grid.nCols - 1)) / grid.nCols;
        // Echo the 3:2 frame aspect.
        final cellH = cellW * 2 / 3;
        return Column(
          children: [
            for (var r = 0; r < grid.nRows; r++)
              Padding(
                padding: EdgeInsets.only(bottom: r == grid.nRows - 1 ? 0 : spacing),
                child: Row(
                  children: [
                    for (var c = 0; c < grid.nCols; c++)
                      Padding(
                        padding: EdgeInsets.only(
                            right: c == grid.nCols - 1 ? 0 : spacing),
                        child: _cell(
                          theme,
                          indexByRowCol[r * grid.nCols + c],
                          cellW,
                          cellH,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _cell(ThemeData theme, int? index, double w, double h) {
    final cs = theme.colorScheme;
    final state = index == null ? TileState.pending : _stateForIndex(index);
    final isCurrent = index != null && index == currentIndex;
    Color color;
    switch (state) {
      case TileState.pending:
        color = cs.surfaceContainerHighest;
      case TileState.active:
        color = cs.primary;
      case TileState.taken:
        color = cs.tertiary;
      case TileState.failed:
        color = cs.error;
    }
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
        border: isCurrent
            ? Border.all(color: cs.onSurface, width: 2)
            : null,
      ),
    );
  }
}
