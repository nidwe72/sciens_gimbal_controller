import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../camera/camera_connection.dart';
import '../camera/camera_diagnostics.dart';
import '../state/gimbal_connection.dart';
import 'header.dart';
import 'tabs/camera_tab.dart';
import 'tabs/gimbal_tab.dart';

/// Post-connect screen. Layout:
///
///   [AppHeader]
///   [ConnectionSummary] — sticky, stays visible across tab switches
///   [TabBar: pan/tilt/roll | logs]
///   [TabBarView — selected tab body]
class PlaygroundScreen extends ConsumerStatefulWidget {
  const PlaygroundScreen({super.key});

  @override
  ConsumerState<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends ConsumerState<PlaygroundScreen> {
  final _stepController = TextEditingController(text: '10');
  int _selectedIndex = 0;

  @override
  void dispose() {
    _stepController.dispose();
    super.dispose();
  }

  double get _stepDeg {
    final v = double.tryParse(_stepController.text);
    return (v == null || v <= 0) ? 0.0 : v;
  }

  Future<void> _move({double course = 0, double pitch = 0}) async {
    final conn = ref.read(gimbalConnectionProvider);
    if (!conn.isConnected) return;
    await conn.moveByAngle(courseDeg: course, pitchDeg: pitch);
  }

  Future<void> _level() async {
    final conn = ref.read(gimbalConnectionProvider);
    if (!conn.isConnected) return;
    await conn.levelHome();
  }

  static const int _cameraTabIndex = 0;
  static const int _gimbalTabIndex = 1;

  @override
  Widget build(BuildContext context) {
    // Auto-switch to the gimbal tab when the gimbal lands a connection.
    ref.listen<bool>(
      gimbalConnectionProvider.select((c) => c.isConnected),
      (prev, next) {
        if (prev != true && next == true) {
          setState(() => _selectedIndex = _gimbalTabIndex);
        }
      },
    );
    // Auto-switch to the camera tab when the camera lands a connection.
    ref.listen<CameraStatus>(
      cameraConnectionProvider.select((c) => c.status),
      (prev, next) {
        if (prev != CameraStatus.connected && next == CameraStatus.connected) {
          setState(() => _selectedIndex = _cameraTabIndex);
        }
      },
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Disconnect both transports cleanly, and stop the diagnostics
        // HTTP server so no socket is orphaned.
        await ref.read(cameraDiagnosticsProvider).stopServer();
        await ref.read(cameraConnectionProvider).disconnect();
        await ref.read(gimbalConnectionProvider).disconnect();
        // PlaygroundScreen is the root route — Navigator.pop() is a
        // no-op here, which left the Android predictive-back gesture
        // hanging on a black preview. SystemNavigator.pop() finishes
        // the activity normally (app goes to recents).
        await SystemNavigator.pop();
      },
      child: Scaffold(
        appBar: const AppHeader(),
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            const CameraTab(),
            GimbalTab(
              stepController: _stepController,
              onPanLeft: () => _move(course: -_stepDeg),
              onPanRight: () => _move(course: _stepDeg),
              onTiltUp: () => _move(pitch: _stepDeg),
              onTiltDown: () => _move(pitch: -_stepDeg),
              onLevel: _level,
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (i) =>
              setState(() => _selectedIndex = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.camera_alt_outlined),
              selectedIcon: Icon(Icons.camera_alt),
              label: 'Camera',
            ),
            NavigationDestination(
              icon: Icon(Icons.sports_esports_outlined),
              selectedIcon: Icon(Icons.sports_esports),
              label: 'Gimbal',
            ),
          ],
        ),
      ),
    );
  }
}

