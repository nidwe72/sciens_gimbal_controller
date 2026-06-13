import 'package:flutter/material.dart';

import '../parallax/parallax_info_sheet.dart';

/// Third sub-tab under the Gimbal tab — **Control | Parallax | Logs**.
///
/// Helps find the no-parallax point (entrance-pupil position) of a taking lens
/// by sliding the camera fore/aft on the nodal rail until panning introduces no
/// parallax between a near and a far target.
///
/// PR 9.1 / 9.1b ship the CV-free explainers (reached from the "More infos" link
/// → a two-tab Problem | Solution panel). The capture + measurement controls
/// (focal input, auto-pan, the live metric) arrive in PRs 9.2–9.7.
class ParallaxCalibrationTab extends StatelessWidget {
  const ParallaxCalibrationTab({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.center_focus_strong,
                size: 40, color: cs.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: 14),
            Text('Parallax calibration',
                style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              'Find the lens no-parallax point so panned tiles stitch without '
              'breaking near/far edges. Capture + measurement controls arrive '
              'in a later step.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: () => showParallaxInfo(context),
              icon: const Icon(Icons.info_outline),
              label: const Text('More infos'),
            ),
          ],
        ),
      ),
    );
  }
}
