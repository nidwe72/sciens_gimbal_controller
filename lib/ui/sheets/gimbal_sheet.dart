import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../ble/transport/ble_gimbal_transport.dart';
import '../../ble/transport/demo_gimbal_transport.dart';
import '../../ble/transport/gimbal_transport.dart';
import '../../state/gimbal_connection.dart';
import '../device_row.dart';

/// Modal-bottom-sheet body for the gimbal device. Hosts the BLE scan
/// list and connect flow when disconnected; shows the connected-device
/// summary + Disconnect button when connected.
///
/// Designed to be opened via `showModalBottomSheet(isScrollControlled:
/// true, ...)`. Auto-dismisses on successful connect via [Navigator.pop].
class GimbalSheet extends ConsumerStatefulWidget {
  const GimbalSheet({super.key});

  @override
  ConsumerState<GimbalSheet> createState() => _GimbalSheetState();
}

class _GimbalSheetState extends ConsumerState<GimbalSheet> {
  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<bool>? _scanningSub;

  /// Always starts with the synthetic DemoRow so users without a SCORP
  /// (or on an emulator without BLE) have something to tap.
  List<DeviceRow> _rows = [DemoRow()];
  bool _scanning = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _scanningSub = FlutterBluePlus.isScanning.listen((s) {
      if (mounted) setState(() => _scanning = s);
    });
    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      final sorted = [...results]..sort((a, b) => b.rssi.compareTo(a.rssi));
      final scanned = sorted.map(ScannedRow.new).toList();
      setState(() => _rows = [DemoRow(), ...scanned]);
    });
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _scanningSub?.cancel();
    if (FlutterBluePlus.isScanningNow) {
      FlutterBluePlus.stopScan();
    }
    super.dispose();
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await FlutterBluePlus.stopScan();
      return;
    }

    setState(() => _statusMessage = null);

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectGranted =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    if (!scanGranted || !connectGranted) {
      if (mounted) {
        setState(() => _statusMessage = 'Bluetooth permissions denied');
      }
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      if (mounted) {
        setState(() => _statusMessage = 'Bluetooth is off — turn it on and retry');
      }
      return;
    }

    setState(() => _rows = [DemoRow()]);
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Scan failed: $e');
      }
    }
  }

  Future<void> _onDeviceTap(DeviceRow row) async {
    final conn = ref.read(gimbalConnectionProvider);
    if (conn.connecting) return;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    if (_scanning) await FlutterBluePlus.stopScan();

    final GimbalTransport transport = switch (row) {
      ScannedRow(:final scan) => BleGimbalTransport(scan.device),
      DemoRow() => DemoGimbalTransport(),
    };

    final ok = await conn.connect(transport);
    if (!mounted) return;

    if (ok) {
      // Auto-dismiss the sheet on successful connect (spec).
      navigator.pop();
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text('Connect failed: ${conn.status}')),
      );
    }
  }

  Future<void> _onDisconnect() async {
    final conn = ref.read(gimbalConnectionProvider);
    await conn.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conn = ref.watch(gimbalConnectionProvider);

    return SafeArea(
      top: false,
      child: conn.isConnected
          ? _ConnectedBody(conn: conn, onDisconnect: _onDisconnect)
          : _scanBody(theme, conn),
    );
  }

  Widget _scanBody(ThemeData theme, GimbalConnection conn) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Gimbal', style: theme.textTheme.titleMedium),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: conn.connecting ? null : _toggleScan,
                icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
                label: Text(_scanning ? 'Stop' : 'Scan'),
              ),
              const SizedBox(width: 16),
              if (conn.connecting) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(conn.status, style: theme.textTheme.bodySmall),
                ),
              ] else if (_scanning && _statusMessage == null)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (_statusMessage != null)
                Expanded(
                  child: Text(
                    _statusMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final row = _rows[i];
              return _DeviceRowTile(
                row: row,
                onTap: conn.connecting ? null : () => _onDeviceTap(row),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConnectedBody extends StatelessWidget {
  const _ConnectedBody({required this.conn, required this.onDisconnect});
  final GimbalConnection conn;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Gimbal', style: theme.textTheme.titleMedium),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              const Spacer(),
              OutlinedButton.icon(
                onPressed: onDisconnect,
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Disconnect'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Single row in the scan list.
class _DeviceRowTile extends StatelessWidget {
  const _DeviceRowTile({required this.row, required this.onTap});
  final DeviceRow row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = row.isDemo ||
        (row is ScannedRow && (row as ScannedRow).looksLikeScorp);

    return ListTile(
      leading: Icon(
        switch (row) {
          DemoRow() => Icons.play_circle_outline,
          ScannedRow(:final looksLikeScorp) =>
            looksLikeScorp ? Icons.videocam : Icons.bluetooth,
        },
        color: highlight ? theme.colorScheme.primary : null,
      ),
      title: Row(
        children: [
          Flexible(child: Text(row.displayName, overflow: TextOverflow.ellipsis)),
          if (row.isDemo) ...[
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'DEMO',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(row.subtitle),
      trailing: Text(row.rssiText),
      onTap: onTap,
    );
  }
}
