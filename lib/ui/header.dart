import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../camera/camera_connection.dart';
import '../state/gimbal_connection.dart';
import 'device_button.dart';
import 'sheets/camera_sheet.dart';
import 'sheets/gimbal_sheet.dart';

/// Application header. Three regions:
///
/// - **Leading** — the Sciens brand mark (assets/branding/sciens.svg) at
///   ~36 dp with `sciens.at` underneath.
/// - **Title** — `Panoramique` + the tagline `old glass, wide world`.
/// - **Actions** — two [DeviceButton]s (camera + gimbal) showing each
///   device's connection state and opening its modal connect sheet on
///   tap. Replaces the standalone DevicesPanel introduced in PR 11.
class AppHeader extends ConsumerWidget implements PreferredSizeWidget {
  const AppHeader({super.key});

  static const _toolbarHeight = 80.0;

  @override
  Size get preferredSize => const Size.fromHeight(_toolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final gimbalConn = ref.watch(gimbalConnectionProvider);
    final cameraConn = ref.watch(cameraConnectionProvider);

    return AppBar(
      backgroundColor: primary,
      foregroundColor: Colors.white,
      elevation: 0,
      toolbarHeight: _toolbarHeight,
      leadingWidth: 72,
      leading: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/branding/sciens.svg',
              width: 36,
              height: 36,
              colorFilter: const ColorFilter.mode(
                Colors.white,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'sciens.at',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 9,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Panoramique',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'old glass, wide world',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.75),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
      actions: [
        DeviceButton(
          icon: Icons.camera_alt,
          outlinedIcon: Icons.camera_alt_outlined,
          label: 'Camera',
          state: _cameraState(cameraConn),
          light: true,
          onTap: () => _openSheet(context, const CameraSheet()),
        ),
        DeviceButton(
          icon: Icons.sports_esports,
          outlinedIcon: Icons.sports_esports_outlined,
          label: 'Gimbal',
          state: _gimbalState(gimbalConn),
          light: true,
          onTap: () => _openSheet(context, const GimbalSheet()),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  static DeviceState _gimbalState(GimbalConnection conn) {
    if (conn.isConnected) return DeviceState.connected;
    if (conn.connecting) return DeviceState.connecting;
    return DeviceState.disconnected;
  }

  static DeviceState _cameraState(CameraConnection conn) {
    switch (conn.status) {
      case CameraStatus.connected:
        return DeviceState.connected;
      case CameraStatus.discovering:
      case CameraStatus.registering:
      case CameraStatus.loadingCaps:
        return DeviceState.connecting;
      case CameraStatus.disconnected:
      case CameraStatus.error:
        return DeviceState.disconnected;
    }
  }

  static void _openSheet(BuildContext context, Widget sheet) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => sheet,
    );
  }
}
