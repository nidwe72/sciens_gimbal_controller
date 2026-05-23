import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../camera/camera_connection.dart';

/// Modal-bottom-sheet body for the camera device. Hosts the
/// auto-discovery / Demo Lumix S5 / manual-IP connect flow when
/// disconnected; shows the connect-phase progress while connecting;
/// shows the connected-camera summary + Disconnect button when
/// connected.
///
/// Designed to be opened via `showModalBottomSheet(isScrollControlled:
/// true, ...)`. Auto-dismisses on transition to Connected via
/// [Navigator.pop].
class CameraSheet extends ConsumerStatefulWidget {
  const CameraSheet({super.key});

  @override
  ConsumerState<CameraSheet> createState() => _CameraSheetState();
}

class _CameraSheetState extends ConsumerState<CameraSheet> {
  final _manualIpController = TextEditingController(text: '192.168.54.1');
  bool _showManualIp = false;

  @override
  void dispose() {
    _manualIpController.dispose();
    super.dispose();
  }

  Future<void> _connect({String? manualIp, bool demo = false}) async {
    final conn = ref.read(cameraConnectionProvider);
    final ok = await conn.connect(manualIp: manualIp, demo: demo);
    if (!mounted) return;
    if (!ok) {
      // If auto-discovery failed, surface the manual-IP entry row
      // so the user can retry with an explicit IP.
      if (manualIp == null && !demo) {
        setState(() => _showManualIp = true);
      }
      return;
    }
    // Auto-dismiss the sheet on successful connect (spec).
    Navigator.of(context).pop();
  }

  Future<void> _disconnect() async {
    final conn = ref.read(cameraConnectionProvider);
    await conn.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(cameraConnectionProvider);
    final theme = Theme.of(context);
    final body = switch (conn.status) {
      CameraStatus.disconnected || CameraStatus.error => _DisconnectedBody(
          conn: conn,
          showManualIp: _showManualIp,
          manualIpController: _manualIpController,
          onToggleManualIp: () =>
              setState(() => _showManualIp = !_showManualIp),
          onConnect: () => _connect(),
          onConnectManual: () =>
              _connect(manualIp: _manualIpController.text.trim()),
          onConnectDemo: () => _connect(demo: true),
        ),
      CameraStatus.discovering ||
      CameraStatus.registering ||
      CameraStatus.loadingCaps =>
        _ConnectingBody(conn: conn),
      CameraStatus.connected =>
        _ConnectedBody(conn: conn, onDisconnect: _disconnect),
    };

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Camera', style: theme.textTheme.titleMedium),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: body,
          ),
        ],
      ),
    );
  }
}

class _DisconnectedBody extends StatelessWidget {
  const _DisconnectedBody({
    required this.conn,
    required this.showManualIp,
    required this.manualIpController,
    required this.onToggleManualIp,
    required this.onConnect,
    required this.onConnectManual,
    required this.onConnectDemo,
  });

  final CameraConnection conn;
  final bool showManualIp;
  final TextEditingController manualIpController;
  final VoidCallback onToggleManualIp;
  final VoidCallback onConnect;
  final VoidCallback onConnectManual;
  final VoidCallback onConnectDemo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: onConnect,
          icon: const Icon(Icons.link),
          label: const Text('Connect to camera'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onConnectDemo,
          icon: const Icon(Icons.science_outlined),
          label: const Text('Demo Lumix S5'),
        ),
        const SizedBox(height: 16),
        Text(
          'Status: ${conn.statusText}',
          style: theme.textTheme.bodyMedium,
        ),
        if (conn.errorText != null) ...[
          const SizedBox(height: 8),
          Text(
            conn.errorText!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          'Make sure the camera is in WiFi → Smartphone mode and your '
          'phone is joined to the LUMIX-… network.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: onToggleManualIp,
          icon: Icon(
            showManualIp ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
            size: 18,
          ),
          label: Text(
            showManualIp ? 'Hide manual IP' : 'Enter camera IP manually',
          ),
        ),
        if (showManualIp) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: manualIpController,
                  decoration: const InputDecoration(
                    labelText: 'Camera IP',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.url,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onConnectManual,
                child: const Text('Connect'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ConnectingBody extends StatelessWidget {
  const _ConnectingBody({required this.conn});
  final CameraConnection conn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                conn.statusText,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Phase: ${_phaseLabel(conn.status)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  String _phaseLabel(CameraStatus s) => switch (s) {
        CameraStatus.discovering => 'discovering',
        CameraStatus.registering => 'registering',
        CameraStatus.loadingCaps => 'loading capabilities',
        _ => '—',
      };
}

class _ConnectedBody extends StatelessWidget {
  const _ConnectedBody({required this.conn, required this.onDisconnect});
  final CameraConnection conn;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              conn.isDemo ? Icons.science_outlined : Icons.wifi,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conn.isDemo ? 'Demo Lumix S5' : 'Lumix camera',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    conn.cameraIp ?? '—',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Status: ${conn.statusText}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Spacer(),
            OutlinedButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect'),
            ),
          ],
        ),
      ],
    );
  }
}
