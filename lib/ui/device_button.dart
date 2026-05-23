import 'package:flutter/material.dart';

/// Connection state of a single device, as surfaced by the
/// [DevicesPanel] icons. Mapped from `GimbalConnection` /
/// `CameraConnection` by the panel.
enum DeviceState { disconnected, connecting, connected }

/// One icon in the devices panel: a filled / outlined glyph + a label,
/// dimmed when [state] is disconnected, with a small ring overlay when
/// connecting, and tinted with the theme primary when connected.
///
/// Pass [outlinedIcon] for the disconnected / connecting variant; if
/// omitted, [icon] is used in all states (acceptable when no outlined
/// glyph exists for the icon family).
class DeviceButton extends StatelessWidget {
  const DeviceButton({
    super.key,
    required this.icon,
    this.outlinedIcon,
    required this.label,
    required this.state,
    required this.onTap,
    this.light = false,
  });

  final IconData icon;
  final IconData? outlinedIcon;
  final String label;
  final DeviceState state;
  final VoidCallback onTap;

  /// When true, render in a white-themed variant suitable for use on a
  /// primary-coloured background (the app header). Default behaviour
  /// (false) uses the theme's onSurface / primary colours for the three
  /// states.
  final bool light;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glyph = state == DeviceState.connected ? icon : (outlinedIcon ?? icon);

    final Color glyphColor;
    final Color labelColor;
    final Color spinnerColor;
    if (light) {
      switch (state) {
        case DeviceState.connected:
          glyphColor = Colors.white;
          labelColor = Colors.white;
        case DeviceState.connecting:
        case DeviceState.disconnected:
          glyphColor = Colors.white.withValues(alpha: 0.5);
          labelColor = Colors.white.withValues(alpha: 0.6);
      }
      spinnerColor = Colors.white;
    } else {
      switch (state) {
        case DeviceState.connected:
          glyphColor = theme.colorScheme.primary;
          labelColor = theme.colorScheme.primary;
        case DeviceState.connecting:
        case DeviceState.disconnected:
          glyphColor =
              theme.colorScheme.onSurface.withValues(alpha: 0.5);
          labelColor =
              theme.colorScheme.onSurface.withValues(alpha: 0.6);
      }
      spinnerColor = theme.colorScheme.outline;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(glyph, size: 32, color: glyphColor),
                  if (state == DeviceState.connecting)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          spinnerColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: labelColor),
            ),
          ],
        ),
      ),
    );
  }
}
