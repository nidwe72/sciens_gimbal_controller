import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/gimbal_connection.dart';
import 'connect_screen.dart';
import 'header.dart';
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
    _tabController = TabController(length: 2, vsync: this);
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
    final conn = ref.watch(gimbalConnectionProvider);

    // If the connection dropped, kick back to ConnectScreen.
    if (!conn.connecting && !conn.isConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const ConnectScreen()),
          );
        }
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await conn.disconnect();
        if (context.mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const ConnectScreen()),
          );
        }
      },
      child: Scaffold(
        appBar: const AppHeader(),
        body: Column(
          children: [
            _ConnectionSummary(conn: conn),
            const Divider(height: 1),
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'pan/tilt/roll'),
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

class _ConnectionSummary extends StatelessWidget {
  const _ConnectionSummary({required this.conn});
  final GimbalConnection conn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.bluetooth_connected, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conn.connectedName ?? '(no device)',
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  '${conn.connectedId ?? "—"}   MTU: ${conn.mtu ?? "—"}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await conn.disconnect();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const ConnectScreen()),
              );
            },
            icon: const Icon(Icons.link_off, size: 18),
            label: const Text('Disconnect'),
          ),
        ],
      ),
    );
  }
}
