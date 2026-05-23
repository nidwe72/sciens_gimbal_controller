import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../camera/camera_connection.dart';
import '../state/gimbal_connection.dart';
import 'device_button.dart';
import 'sheets/camera_sheet.dart';
import 'sheets/gimbal_sheet.dart';

/// Horizontal row of [DeviceButton]s — one per device (camera +
/// gimbal) — that sits below the app header. Each button reflects
/// its device's connection state and opens a modal bottom sheet for
/// connect / disconnect on tap.
class DevicesPanel extends ConsumerWidget {
  const DevicesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gimbal = ref.watch(gimbalConnectionProvider);
    final camera = ref.watch(cameraConnectionProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          DeviceButton(
            icon: Icons.camera_alt,
            outlinedIcon: Icons.camera_alt_outlined,
            label: 'Camera',
            state: _cameraState(camera),
            onTap: () => _openSheet(context, const CameraSheet()),
          ),
          DeviceButton(
            // Material Icons has no joystick glyph in this Flutter SDK;
            // sports_esports is the closest match (controller-style
            // silhouette). Swap to a custom asset or material_symbols_icons
            // joystick later if desired.
            icon: Icons.sports_esports,
            outlinedIcon: Icons.sports_esports_outlined,
            label: 'Gimbal',
            state: _gimbalState(gimbal),
            onTap: () => _openSheet(context, const GimbalSheet()),
          ),
        ],
      ),
    );
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

  static DeviceState _gimbalState(GimbalConnection conn) {
    if (conn.isConnected) return DeviceState.connected;
    if (conn.connecting) return DeviceState.connecting;
    return DeviceState.disconnected;
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
