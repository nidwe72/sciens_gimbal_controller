import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../camera/camera_connection.dart';
import '../../panorama/panorama_grid.dart';
import '../../panorama/pano_tile_image.dart';
import '../../state/gimbal_connection.dart';
import '../../state/panorama_controller.dart';
import '../full_screen_image.dart';

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
        // Take / Cancel are the first controls (SPEC Phase 4: buttons-
        // first layout) so the primary actions are reachable without
        // scrolling past the parameters.
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
        // Disable-reason travels with the button it explains.
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
        const SizedBox(height: 16),
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
          tileImages: pano.tileImages,
          currentIndex: pano.currentIndex,
        ),
        const SizedBox(height: 12),
        // Phase 6 — assembly mode: Geometric (flat, instant) or OpenPano
        // (feature-stitched, slower, spherical).
        Center(
          child: SegmentedButton<StitchMode>(
            segments: const [
              ButtonSegment(
                value: StitchMode.geometric,
                label: Text('Geometric'),
                icon: Icon(Icons.grid_on),
              ),
              ButtonSegment(
                value: StitchMode.openpano,
                label: Text('OpenPano'),
                icon: Icon(Icons.auto_awesome),
              ),
              ButtonSegment(
                value: StitchMode.affine,
                label: Text('Affine'),
                icon: Icon(Icons.dashboard_customize),
              ),
            ],
            selected: {pano.stitchMode},
            showSelectedIcon: false,
            onSelectionChanged: pano.stitching
                ? null
                : (s) => ref
                    .read(panoramaControllerProvider)
                    .setStitchMode(s.first),
          ),
        ),
        const SizedBox(height: 8),
        // Stitch (assemble + cache) / View (open the cached preview).
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: pano.canStitch
                    ? () => ref.read(panoramaControllerProvider).stitchPano()
                    : null,
                icon: const Icon(Icons.auto_awesome_mosaic),
                label: const Text('Stitch pano'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: (pano.hasStitchedPano && !pano.stitching)
                    ? () => _openPano(
                          context,
                          ref.read(panoramaControllerProvider).stitchedPano!,
                        )
                    : null,
                icon: const Icon(Icons.fullscreen),
                label: const Text('View pano'),
              ),
            ),
          ],
        ),
        // Live stitch progress — for the affine path this is the server's
        // stitchEvents stream made visible (stage + percentage + bar).
        if (pano.stitching && pano.stitchStage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  pano.stitchProgress != null
                      ? '${pano.stitchStage}  ${(pano.stitchProgress! * 100).round()}%'
                      : pano.stitchStage!,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: pano.stitchProgress),
              ],
            ),
          ),
        if (pano.stitchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              pano.stitchError!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// Open the cached stitched panorama full-screen. Passes a `clone()` so
  /// the viewer can dispose its copy without invalidating the controller's
  /// cached image (so "View pano" stays repeatable).
  void _openPano(BuildContext context, ui.Image pano) {
    final view = pano.clone();
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FullScreenImage(loader: () async => view),
    ));
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

/// Cell grid — always visible (even before a run / while disconnected).
/// Empty cells show a subtle border with no fill; as the run captures
/// each tile its cell fills with that tile's image (demo crop / live SM
/// thumbnail). See SPEC Phase 4 "Per-tile tile images".
class _TileGridView extends StatelessWidget {
  const _TileGridView({
    required this.grid,
    required this.tileStates,
    required this.tileImages,
    required this.currentIndex,
  });

  final PanoramaGrid grid;
  final List<TileState> tileStates;
  final List<PanoTileImage?> tileImages;
  final int currentIndex;

  TileState _stateForIndex(int index) =>
      index < tileStates.length ? tileStates[index] : TileState.pending;

  PanoTileImage? _imageForIndex(int index) =>
      index < tileImages.length ? tileImages[index] : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Resolve grid coordinates → serpentine index for state/image lookup.
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
    final image = index == null ? null : _imageForIndex(index);
    final isCurrent = index != null && index == currentIndex;

    // Fill colour shows only when there's no image yet: empty pending
    // cells have NO fill (border only); active = the tile being shot;
    // failed = transient before abort.
    Color? fill;
    switch (state) {
      case TileState.pending:
        fill = null;
      case TileState.active:
        fill = cs.primary.withValues(alpha: 0.30);
      case TileState.taken:
        // A taken tile always carries an image (a failed fetch aborts
        // the run); the tint is only a paint-order backstop.
        fill = cs.tertiary.withValues(alpha: 0.25);
      case TileState.failed:
        fill = cs.error;
    }
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(
        painter: _TileCellPainter(
          image: image,
          fill: fill,
          border: isCurrent ? cs.onSurface : cs.outlineVariant,
          borderWidth: isCurrent ? 2 : 1,
          radius: 2,
        ),
      ),
    );
  }
}

/// Paints one grid cell: an optional image (a sub-rectangle of a shared
/// demo asset, or a whole live thumbnail) cover-fitted into the cell,
/// else a fill colour, plus a rounded border.
class _TileCellPainter extends CustomPainter {
  _TileCellPainter({
    required this.image,
    required this.fill,
    required this.border,
    required this.borderWidth,
    required this.radius,
  });

  final PanoTileImage? image;
  final Color? fill;
  final Color border;
  final double borderWidth;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    canvas.save();
    canvas.clipRRect(rrect);
    final img = image;
    if (img != null) {
      // Cover-fit: shrink the source rect to the cell's aspect (centred)
      // so the slice fills the cell without distortion.
      final src = _coverSrc(img.src, size);
      canvas.drawImageRect(
        img.image,
        src,
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else if (fill != null) {
      canvas.drawRect(rect, Paint()..color = fill!);
    }
    canvas.restore();

    canvas.drawRRect(
      rrect.deflate(borderWidth / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..color = border,
    );
  }

  /// The sub-rect of [src] matching the cell's aspect ratio, centred —
  /// the source region that maps onto the full cell under cover-fit.
  Rect _coverSrc(Rect src, Size cell) {
    final srcAr = src.width / src.height;
    final dstAr = cell.width / cell.height;
    var w = src.width;
    var h = src.height;
    if (srcAr > dstAr) {
      w = src.height * dstAr; // too wide → crop horizontally
    } else {
      h = src.width / dstAr; // too tall → crop vertically
    }
    return Rect.fromCenter(center: src.center, width: w, height: h);
  }

  @override
  bool shouldRepaint(_TileCellPainter old) =>
      old.image != image ||
      old.fill != fill ||
      old.border != border ||
      old.borderWidth != borderWidth ||
      old.radius != radius;
}
