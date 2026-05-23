import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../camera/camera_connection.dart';
import '../camera/camera_diagnostics.dart';
import '../state/gimbal_connection.dart';
import 'devices_panel.dart';
import 'header.dart';
import 'tabs/camera_tab.dart';
import 'tabs/controls_tab.dart';
import 'tabs/logs_tab.dart';

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

class _PlaygroundScreenState extends ConsumerState<PlaygroundScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _stepController = TextEditingController(text: '10');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Disconnect both transports cleanly, and stop the diagnostics
        // HTTP server so no socket is orphaned.
        await ref.read(cameraDiagnosticsProvider).stopServer();
        await ref.read(cameraConnectionProvider).disconnect();
        await ref.read(gimbalConnectionProvider).disconnect();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: const AppHeader(),
        body: Column(
          children: [
            const DevicesPanel(),
            const Divider(height: 1),
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'gimbal'),
                Tab(text: 'camera'),
                Tab(text: 'logs'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  ControlsTab(
                    stepController: _stepController,
                    onPanLeft: () => _move(course: -_stepDeg),
                    onPanRight: () => _move(course: _stepDeg),
                    onTiltUp: () => _move(pitch: _stepDeg),
                    onTiltDown: () => _move(pitch: -_stepDeg),
                    onLevel: _level,
                  ),
                  const CameraTab(),
                  const LogsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

