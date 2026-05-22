import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../camera/camera_connection.dart';
import '../../camera/lumix_protocol.dart';
import 'camera_diagnostics_view.dart';

/// Shooting-mode hint — the dial position the user has set on the
/// camera body. Pure client-side state: the Lumix protocol exposes no
/// way to read or set the dial. Drives which controls the camera tab
/// leaves editable — an advisory convention; the body itself does not
/// enforce it (see SPEC Pre-PR 5 — as built).
enum CameraMode { p, a, s, m }

// --- PR 5 controls: mode-enablement matrix + shutter option list.
// The matrix is advisory (the camera doesn't enforce it); it only
// governs which dropdowns the tab leaves interactive.

/// Shutter is user-settable only with the dial in S or M.
bool _shutterEditable(CameraMode? m) =>
    m == CameraMode.s || m == CameraMode.m;

/// ISO is settable in every mode — but not until a mode is picked.
bool _isoEditable(CameraMode? m) => m != null;

/// Aperture is user-settable with the dial in A or M.
bool _apertureEditable(CameraMode? m) =>
    m == CameraMode.a || m == CameraMode.m;

/// Shutter dropdown options — the 19 hardcoded wires paired with
/// human labels. Built once.
final List<({String wire, String display})> _shutterOptions = [
  for (final w in defaultShutterValues)
    (wire: w, display: shutterSecondsToLabel(shutterWireToSeconds(w)!)),
];

/// Aperture dropdown options — the 25 hardcoded f-stop wires paired
/// with f-number labels. Built once.
final List<({String wire, String display})> _apertureOptions = [
  for (final w in defaultApertureValues)
    (wire: w, display: apertureFNumberToLabel(apertureWireToFNumber(w)!)),
];

/// Polled ISO value if it's one of the body's listed options, else
/// null (then shown via the dropdown's hint).
String? _snapIso(String? polled, List<String> options) {
  if (polled == null) return null;
  return options.contains(polled) ? polled : null;
}

/// Middle Playground tab. Hosts two sub-tabs: "Camera" (connect /
/// live preview / — in PR 5 — controls) and "Debug/Diagnostics" (the
/// diagnostics wizard). See SPEC-flutter-app.md Phase 2, Pre-PR 5.
class CameraTab extends ConsumerStatefulWidget {
  const CameraTab({super.key});

  @override
  ConsumerState<CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends ConsumerState<CameraTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: const [
          TabBar(
            tabs: [
              Tab(text: 'Camera'),
              Tab(text: 'Debug/Diagnostics'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _CameraControlsTab(),
                CameraDiagnosticsView(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Camera" sub-tab — connect / disconnect lifecycle and the
/// live-preview pane. AutomaticKeepAliveClientMixin keeps the
/// live-preview toggle (and PR 5's mode-hint) state alive when the
/// user flips to the Debug/Diagnostics sub-tab and back.
class _CameraControlsTab extends ConsumerStatefulWidget {
  const _CameraControlsTab();

  @override
  ConsumerState<_CameraControlsTab> createState() => _CameraControlsTabState();
}

class _CameraControlsTabState extends ConsumerState<_CameraControlsTab>
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

    // Pause-decode when this sub-tab is hidden. TickerMode goes false
    // for the inactive sub-tab of the nested TabBarView, and for the
    // whole camera tab when another Playground tab is selected — so
    // riding this signal covers both. Datagrams keep draining; only
    // the JPEG decode is skipped.
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

  /// Dial-position hint. Null until the user picks — session-only,
  /// resets on reconnect (this State is rebuilt fresh).
  CameraMode? _modeHint;

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
    final isoValues = conn.caps?.isoValues ?? const <String>[];
    final isoOptions = [
      for (final v in isoValues) (wire: v, display: v),
    ];
    final shutterWire = nearestShutterWire(conn.shutterWire);
    final shutterLabel = shutterWire == null
        ? null
        : _shutterOptions
            .firstWhere((o) => o.wire == shutterWire,
                orElse: () => (wire: '', display: ''))
            .display;
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
        const Divider(height: 24),
        _ModeHintSelector(
          mode: _modeHint,
          onChanged: (m) => setState(() => _modeHint = m),
        ),
        const SizedBox(height: 12),
        _SettingDropdownRow(
          label: 'Shutter',
          options: _shutterOptions,
          selectedWire: shutterWire,
          editable: _shutterEditable(_modeHint),
          onApply: (w) => conn.applySetting('shtrspeed', w),
        ),
        _SettingDropdownRow(
          label: 'ISO',
          options: isoOptions,
          selectedWire: _snapIso(conn.isoWire, isoValues),
          editable: _isoEditable(_modeHint) && isoValues.isNotEmpty,
          onApply: (w) => conn.applySetting('iso', w),
        ),
        if (conn.focalWire == apertureSentinelWire)
          const _ApertureSentinelRow()
        else
          _SettingDropdownRow(
            label: 'Aperture',
            options: _apertureOptions,
            selectedWire: nearestApertureWire(conn.focalWire),
            editable: _apertureEditable(_modeHint),
            onApply: (w) => conn.applySetting('focal', w),
          ),
        const SizedBox(height: 20),
        _CaptureButton(conn: conn, shutterLabel: shutterLabel),
      ],
    );
  }
}

/// `P / A / S / M` segmented selector for the dial-position hint.
/// Empty (no default) on connect; the controls below stay read-only
/// until a mode is chosen.
class _ModeHintSelector extends StatelessWidget {
  const _ModeHintSelector({required this.mode, required this.onChanged});

  final CameraMode? mode;
  final ValueChanged<CameraMode?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mode (set on dial)', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        SegmentedButton<CameraMode>(
          segments: const [
            ButtonSegment(value: CameraMode.p, label: Text('P')),
            ButtonSegment(value: CameraMode.a, label: Text('A')),
            ButtonSegment(value: CameraMode.s, label: Text('S')),
            ButtonSegment(value: CameraMode.m, label: Text('M')),
          ],
          selected: mode == null ? const <CameraMode>{} : {mode!},
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          onSelectionChanged: (sel) =>
              onChanged(sel.isEmpty ? null : sel.first),
        ),
        if (mode == null) ...[
          const SizedBox(height: 6),
          Text(
            'Pick the dial position to enable the controls.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }
}

/// One labelled setting dropdown (Shutter / ISO; aperture reuses it
/// in Step 5). Holds an optimistic "pending" pick so a 1 Hz poll
/// update mid-interaction can't yank the user's selection — it clears
/// once polling catches up, or after a 3 s fallback.
class _SettingDropdownRow extends StatefulWidget {
  const _SettingDropdownRow({
    required this.label,
    required this.options,
    required this.selectedWire,
    required this.editable,
    required this.onApply,
  });

  final String label;
  final List<({String wire, String display})> options;

  /// The polled value snapped to an option, or null.
  final String? selectedWire;
  final bool editable;

  /// Applies the pick; returns null on success or an error string.
  final Future<String?> Function(String wire) onApply;

  @override
  State<_SettingDropdownRow> createState() => _SettingDropdownRowState();
}

class _SettingDropdownRowState extends State<_SettingDropdownRow> {
  String? _pending;
  Timer? _pendingTimer;
  String? _errorText;
  Timer? _errorTimer;

  @override
  void didUpdateWidget(_SettingDropdownRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Once polling has caught up to the optimistic pick, drop it. A
    // build follows didUpdateWidget, so no setState is needed here.
    if (_pending != null && widget.selectedWire == _pending) {
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _pending = null;
    }
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    _errorTimer?.cancel();
    super.dispose();
  }

  String _labelFor(String wire) => widget.options
      .firstWhere((o) => o.wire == wire,
          orElse: () => (wire: wire, display: wire))
      .display;

  Future<void> _onPicked(String wire) async {
    setState(() {
      _pending = wire;
      _errorText = null;
    });
    _errorTimer?.cancel();
    _pendingTimer?.cancel();
    // Fallback: drop the optimistic value after 3 s even if polling
    // never matches it (e.g. the camera clamped the request).
    _pendingTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _pending = null);
    });
    final error = await widget.onApply(wire);
    if (!mounted) return;
    if (error != null) {
      // Rejected — revert to the last polled value now and flash a
      // transient message for ~3 s.
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _errorTimer?.cancel();
      setState(() {
        _pending = null;
        _errorText = 'Camera rejected ${_labelFor(wire)} — $error';
      });
      _errorTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _errorText = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = _pending ?? widget.selectedWire;
    final safeValue =
        widget.options.any((o) => o.wire == value) ? value : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76,
                child:
                    Text(widget.label, style: theme.textTheme.bodyMedium),
              ),
              Expanded(
                child: DropdownButton<String>(
                  value: safeValue,
                  isExpanded: true,
                  hint: const Text('—'),
                  items: [
                    for (final o in widget.options)
                      DropdownMenuItem(
                          value: o.wire, child: Text(o.display)),
                  ],
                  onChanged: widget.editable
                      ? (w) {
                          if (w != null) _onPicked(w);
                        }
                      : null,
                ),
              ),
            ],
          ),
          if (_errorText != null)
            Padding(
              padding: const EdgeInsets.only(left: 76, bottom: 4),
              child: Text(
                _errorText!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// Read-only aperture row shown when `getsetting?type=focal` reports
/// the `32767/256` sentinel — a manual-aperture lens or no lens. The
/// dropdown returns automatically on the next poll if a real value
/// reappears (e.g. an electronic lens is mounted).
class _ApertureSentinelRow extends StatelessWidget {
  const _ApertureSentinelRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text('Aperture', style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(
              'No electronic aperture — set on lens',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The shutter-release button. Optimistic-disables on tap, then
/// re-enables when polling sees `<remaincapacity>` drop (the saved
/// shot — reliable for fast and long exposures alike) or when a
/// shutter-derived timeout elapses as a backstop.
class _CaptureButton extends StatefulWidget {
  const _CaptureButton({required this.conn, required this.shutterLabel});

  final CameraConnection conn;
  final String? shutterLabel;

  @override
  State<_CaptureButton> createState() => _CaptureButtonState();
}

class _CaptureButtonState extends State<_CaptureButton> {
  bool _capturing = false;
  int? _capacityAtTap;
  Timer? _timeoutTimer;
  String? _message;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    widget.conn.addListener(_onConnChanged);
  }

  @override
  void dispose() {
    widget.conn.removeListener(_onConnChanged);
    _timeoutTimer?.cancel();
    _messageTimer?.cancel();
    super.dispose();
  }

  void _onConnChanged() {
    if (!_capturing) return;
    final base = _capacityAtTap;
    final now = widget.conn.cameraState?.remainCapacity;
    if (base != null && now != null && now < base) {
      _finish(null); // a shot was saved
    }
  }

  Future<void> _onTap() async {
    setState(() {
      _capturing = true;
      _capacityAtTap = widget.conn.cameraState?.remainCapacity;
      _message = null;
    });
    _messageTimer?.cancel();
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(
      optimisticCaptureTimeout(widget.shutterLabel ?? ''),
      () => _finish('Capture may not have completed — check camera.'),
    );
    final error = await widget.conn.capture();
    if (!mounted) return;
    if (error != null) {
      _finish('Capture failed — $error');
    }
  }

  void _finish(String? message) {
    if (!_capturing) return;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    setState(() {
      _capturing = false;
      _message = message;
    });
    if (message != null) {
      _messageTimer?.cancel();
      _messageTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _message = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: _capturing ? null : _onTap,
          child: _capturing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Capture'),
        ),
        if (_message != null) ...[
          const SizedBox(height: 4),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
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
