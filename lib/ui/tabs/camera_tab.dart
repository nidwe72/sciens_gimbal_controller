import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../camera/camera_connection.dart';

/// Middle Playground tab. Hosts the camera connect/disconnect UI and
/// (in later PRs) the shutter / ISO / capture controls and live
/// preview pane. PR 3 scope: Disconnected state with manual-IP
/// fallback, connecting status states, and a Connected placeholder.
class CameraTab extends ConsumerStatefulWidget {
  const CameraTab({super.key});

  @override
  ConsumerState<CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends ConsumerState<CameraTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _manualIpController = TextEditingController(text: '192.168.54.1');
  bool _showManualIp = false;

  @override
  void dispose() {
    _manualIpController.dispose();
    super.dispose();
  }

  Future<void> _connect({String? manualIp}) async {
    final conn = ref.read(cameraConnectionProvider);
    final ok = await conn.connect(manualIp: manualIp);
    if (!ok && mounted) {
      // If auto-discovery failed, surface the manual-IP entry row
      // so the user can retry with an explicit IP.
      if (manualIp == null) {
        setState(() => _showManualIp = true);
      }
    }
  }

  Future<void> _disconnect() async {
    final conn = ref.read(cameraConnectionProvider);
    await conn.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final conn = ref.watch(cameraConnectionProvider);

    // Pause-decode when the tab is hidden. TickerMode goes false on
    // the inactive tab(s) of a TabBarView, so we ride that signal
    // rather than wiring up a VisibilityDetector. Datagrams keep
    // draining; only the JPEG decode is skipped.
    conn.setPreviewPaused(!TickerMode.valuesOf(context).enabled);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: switch (conn.status) {
          CameraStatus.disconnected || CameraStatus.error =>
            _DisconnectedView(
              conn: conn,
              showManualIp: _showManualIp,
              manualIpController: _manualIpController,
              onToggleManualIp: () =>
                  setState(() => _showManualIp = !_showManualIp),
              onConnect: () => _connect(),
              onConnectManual: () => _connect(
                manualIp: _manualIpController.text.trim(),
              ),
            ),
          CameraStatus.discovering ||
          CameraStatus.registering ||
          CameraStatus.loadingCaps =>
            _ConnectingView(conn: conn),
          CameraStatus.connected => _ConnectedView(
              conn: conn,
              onDisconnect: _disconnect,
            ),
        },
      ),
    );
  }
}

class _DisconnectedView extends StatelessWidget {
  const _DisconnectedView({
    required this.conn,
    required this.showManualIp,
    required this.manualIpController,
    required this.onToggleManualIp,
    required this.onConnect,
    required this.onConnectManual,
  });

  final CameraConnection conn;
  final bool showManualIp;
  final TextEditingController manualIpController;
  final VoidCallback onToggleManualIp;
  final VoidCallback onConnect;
  final VoidCallback onConnectManual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onConnect,
          icon: const Icon(Icons.link),
          label: const Text('Connect to camera'),
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

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({required this.conn});
  final CameraConnection conn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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

class _ConnectedView extends StatefulWidget {
  const _ConnectedView({required this.conn, required this.onDisconnect});
  final CameraConnection conn;
  final VoidCallback onDisconnect;

  @override
  State<_ConnectedView> createState() => _ConnectedViewState();
}

class _ConnectedViewState extends State<_ConnectedView> {
  bool _previewToggle = false;
  bool _toggleBusy = false;

  Future<void> _onTogglePreview(bool value) async {
    if (_toggleBusy) return;
    setState(() => _toggleBusy = true);
    if (value) {
      final ok = await widget.conn.startLivePreview();
      if (!mounted) return;
      setState(() {
        _previewToggle = ok;
        _toggleBusy = false;
      });
    } else {
      await widget.conn.stopLivePreview();
      if (!mounted) return;
      setState(() {
        _previewToggle = false;
        _toggleBusy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conn = widget.conn;
    // Surface preview errors from the underlying connection state.
    final previewError = conn.previewError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.videocam, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Lumix camera'),
                  Text(
                    conn.cameraIp ?? '—',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: widget.onDisconnect,
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect'),
            ),
          ],
        ),
        const Divider(height: 24),
        // PR 4: live-preview toggle + preview pane.
        SwitchListTile(
          value: _previewToggle,
          onChanged: _toggleBusy ? null : _onTogglePreview,
          title: const Text('Live preview'),
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
        if (previewError != null) ...[
          const SizedBox(height: 4),
          Text(
            previewError,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (_previewToggle) ...[
          const SizedBox(height: 8),
          _PreviewPane(conn: conn),
        ],
      ],
    );
  }
}

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({required this.conn});
  final CameraConnection conn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: ValueListenableBuilder<ui.Image?>(
          valueListenable: conn.previewImage,
          builder: (context, image, _) {
            if (image == null) {
              return Text(
                'Waiting for frames...',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                ),
              );
            }
            return RawImage(
              image: image,
              fit: BoxFit.contain,
            );
          },
        ),
      ),
    );
  }
}
