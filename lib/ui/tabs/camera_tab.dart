import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Maps the camera's raw `recmode` string to a `CameraMode`, or null
/// for modes outside P/A/S/M (intelligent-auto, video, custom banks).
CameraMode? cameraModeFromRecmode(String? recmode) => switch (recmode) {
      'program_ae' => CameraMode.p,
      'aperture_ae' => CameraMode.a,
      'shutter_ae' => CameraMode.s,
      'manual_exposure' => CameraMode.m,
      _ => null,
    };

/// EV compensation is user-settable in P / A / S; read-only in M (no
/// auto-exposure offset when shutter and aperture are both user-set)
/// and when no mode is known.
bool _evEditable(CameraMode? m) =>
    m == CameraMode.p || m == CameraMode.a || m == CameraMode.s;

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
    final isDemo = ref.watch(
        cameraConnectionProvider.select((c) => c.isDemo));
    return DefaultTabController(
      length: isDemo ? 3 : 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              const Tab(text: 'Camera'),
              const Tab(text: 'Debug/Diagnostics'),
              if (isDemo) const Tab(text: 'Virtual S5'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                const _CameraControlsTab(),
                const CameraDiagnosticsView(),
                if (isDemo) const _VirtualLumixTab(),
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

    if (!conn.isConnected) {
      return const _CameraPlaceholder();
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: _ConnectedView(conn: conn),
      ),
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Connect a camera — tap the camera icon above.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _ConnectedView extends StatefulWidget {
  const _ConnectedView({required this.conn});
  final CameraConnection conn;

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
    final mode = cameraModeFromRecmode(conn.recMode);
    // Surface preview errors from the underlying connection state.
    final previewError = conn.previewError;
    final isoValues = conn.caps?.isoValues ?? const <String>[];
    final isoOptions = [
      for (final v in isoValues) (wire: v, display: v),
    ];
    final exposureValues = conn.caps?.exposureValues ?? const <String>[];
    final evOptions = [
      for (final v in exposureValues) (wire: v, display: evLabel(v)),
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
            _BatteryIcon(battery: conn.cameraState?.battery),
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
        _CameraPane(conn: conn),
        const Divider(height: 24),
        _ModeReadout(mode: mode),
        const SizedBox(height: 12),
        _SettingDropdownRow(
          label: 'Shutter',
          options: _shutterOptions,
          selectedWire: shutterWire,
          editable: _shutterEditable(mode),
          onApply: (w) => conn.applySetting('shtrspeed', w),
        ),
        _SettingDropdownRow(
          label: 'ISO',
          options: isoOptions,
          selectedWire: _snapIso(conn.isoWire, isoValues),
          editable: _isoEditable(mode) && isoValues.isNotEmpty,
          onApply: (w) => conn.applySetting('iso', w),
        ),
        if (conn.focalWire == apertureSentinelWire)
          const _ApertureSentinelRow()
        else
          _SettingDropdownRow(
            label: 'Aperture',
            options: _apertureOptions,
            selectedWire: nearestApertureWire(conn.focalWire),
            editable: _apertureEditable(mode),
            onApply: (w) => conn.applySetting('focal', w),
          ),
        _SettingDropdownRow(
          label: 'EV',
          options: evOptions,
          selectedWire:
              nearestExposureWire(conn.exposureWire, exposureValues),
          editable: _evEditable(mode) && exposureValues.isNotEmpty,
          onApply: (w) => conn.applySetting('exposure', w),
        ),
        const SizedBox(height: 20),
        _CaptureButton(conn: conn, shutterLabel: shutterLabel),
      ],
    );
  }
}

/// Read-only `P / A / S / M` mode readout — reflects the camera's dial
/// position (polled from `curmenu`). Not interactive: the S5's mode
/// dial is mechanical and exposes no setter.
class _ModeReadout extends StatelessWidget {
  const _ModeReadout({required this.mode});

  final CameraMode? mode;

  static String _label(CameraMode m) => switch (m) {
        CameraMode.p => 'P',
        CameraMode.a => 'A',
        CameraMode.s => 'S',
        CameraMode.m => 'M',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mode (from camera)', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final m in CameraMode.values) ...[
              _ModeChip(label: _label(m), active: m == mode),
              if (m != CameraMode.values.last) const SizedBox(width: 6),
            ],
          ],
        ),
        if (mode == null) ...[
          const SizedBox(height: 6),
          Text(
            'Camera is not in P / A / S / M — controls are read-only.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }
}

/// One chip in the mode readout — filled when it is the active mode.
class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      padding: const EdgeInsets.symmetric(vertical: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? theme.colorScheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: active
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurface.withValues(alpha: 0.5),
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

/// Camera battery level as a Material icon — red at 0–1/5, amber at
/// 2/5, default above. The camera reports a 0–5 bar count, not a
/// percentage (`<batt_per>` is always -1 over WiFi).
class _BatteryIcon extends StatelessWidget {
  const _BatteryIcon({required this.battery});

  /// The `<batt>` value, e.g. "3/5", or null before the first poll.
  final String? battery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bars = batteryBars(battery);
    if (bars == null) {
      return Icon(
        Icons.battery_unknown,
        size: 22,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
      );
    }
    final icon = switch (bars) {
      <= 0 => Icons.battery_0_bar,
      1 => Icons.battery_1_bar,
      2 => Icons.battery_2_bar,
      3 => Icons.battery_3_bar,
      4 => Icons.battery_4_bar,
      _ => Icons.battery_full,
    };
    final color = switch (bars) {
      <= 1 => theme.colorScheme.error,
      2 => Colors.amber.shade800,
      _ => theme.colorScheme.onSurface,
    };
    return Icon(icon, size: 22, color: color);
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
    if (message == null) {
      // Capture succeeded — pull the JPEG into the pane (PR 8).
      widget.conn.fetchLastImage();
    } else {
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
          onPressed:
              (_capturing || widget.conn.fetchInProgress) ? null : _onTap,
          child: (_capturing || widget.conn.fetchInProgress)
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

/// The camera pane — shows the live MJPEG preview, or the most-recent
/// captured still. Per PR 8: a fresh capture is shown for ~5 s while
/// live preview runs, or until the next capture when it doesn't.
/// Renders nothing when there's neither a live stream nor a still.
class _CameraPane extends StatefulWidget {
  const _CameraPane({required this.conn});

  final CameraConnection conn;

  @override
  State<_CameraPane> createState() => _CameraPaneState();
}

class _CameraPaneState extends State<_CameraPane> {
  bool _showCapture = false;
  Timer? _revertTimer;

  @override
  void initState() {
    super.initState();
    widget.conn.addListener(_onConnChanged);
    widget.conn.capturedImage.addListener(_onCaptured);
  }

  @override
  void dispose() {
    widget.conn.removeListener(_onConnChanged);
    widget.conn.capturedImage.removeListener(_onCaptured);
    _revertTimer?.cancel();
    super.dispose();
  }

  void _onCaptured() {
    if (widget.conn.capturedImage.value == null) return;
    _revertTimer?.cancel();
    _revertTimer = null;
    setState(() => _showCapture = true);
    if (widget.conn.previewActive) _scheduleRevert();
  }

  void _onConnChanged() {
    if (!_showCapture) return;
    if (widget.conn.previewActive) {
      if (_revertTimer == null) _scheduleRevert();
    } else {
      // Live preview stopped — the still now stays.
      _revertTimer?.cancel();
      _revertTimer = null;
    }
  }

  void _scheduleRevert() {
    _revertTimer = Timer(const Duration(seconds: 5), () {
      _revertTimer = null;
      if (mounted) setState(() => _showCapture = false);
    });
  }

  void _openFullScreen() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullScreenImage(conn: widget.conn),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conn = widget.conn;
    final captured = conn.capturedImage.value;
    final showingStill = _showCapture && captured != null;

    if (!showingStill && !conn.previewActive) {
      return const SizedBox.shrink();
    }

    final Widget content;
    if (showingStill) {
      content = GestureDetector(
        onDoubleTap: _openFullScreen,
        child: RawImage(image: captured, fit: BoxFit.contain),
      );
    } else {
      content = ValueListenableBuilder<ui.Image?>(
        valueListenable: conn.previewImage,
        builder: (context, image, _) => image == null
            ? Text(
                'Waiting for frames...',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white70),
              )
            : RawImage(image: image, fit: BoxFit.contain),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: content,
        ),
      ),
    );
  }
}

/// Full-screen viewer for the captured image — fetches the full-res
/// JPEG and shows it edge-to-edge in a pinch-zoomable
/// `InteractiveViewer`. Hides the system bars while open so the image
/// uses the whole screen, in either orientation.
class _FullScreenImage extends StatefulWidget {
  const _FullScreenImage({required this.conn});

  final CameraConnection conn;

  @override
  State<_FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<_FullScreenImage> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
  }

  Future<void> _load() async {
    final image = await widget.conn.fetchFullImage();
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _image = image;
      _failed = image == null;
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final Widget content;
    if (image != null) {
      content = InteractiveViewer(
        maxScale: 6,
        child: RawImage(image: image, fit: BoxFit.contain),
      );
    } else if (_failed) {
      content = const Center(
        child: Text('Could not load the image.',
            style: TextStyle(color: Colors.white70)),
      );
    } else {
      content = const Center(child: CircularProgressIndicator());
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Virtual Lumix S5" sub-tab (PR 9 Step 6) — stands in for the
/// camera body's physical controls. Visible only when the demo
/// transport is the active connection. Writes go straight to the
/// `DemoLumixCamera`'s virtual state; the next poll cycle propagates
/// them to the camera tab's mode chip and battery indicator.
class _VirtualLumixTab extends ConsumerStatefulWidget {
  const _VirtualLumixTab();

  @override
  ConsumerState<_VirtualLumixTab> createState() =>
      _VirtualLumixTabState();
}

class _VirtualLumixTabState extends ConsumerState<_VirtualLumixTab> {
  /// Mode dial — recmode wire value paired with its dial-letter label.
  static const _modes = <(String, String)>[
    ('program_ae', 'P'),
    ('aperture_ae', 'A'),
    ('shutter_ae', 'S'),
    ('manual_exposure', 'M'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final demo = ref.read(cameraConnectionProvider).demoCamera;
    if (demo == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'These controls stand in for the camera body — set them '
              'as if you were turning the mode dial or watching the '
              'battery drain. Changes show on the Camera tab on the '
              'next poll.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            Text('Mode dial', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                segments: _modes
                    .map((m) => ButtonSegment<String>(
                          value: m.$1,
                          label: Text(m.$2),
                        ))
                    .toList(),
                selected: {demo.dialMode},
                onSelectionChanged: (s) =>
                    setState(() => demo.dialMode = s.first),
                showSelectedIcon: false,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Text('Battery', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text('${demo.batteryBars} / 5 bars',
                    style: theme.textTheme.bodyMedium),
              ],
            ),
            Slider(
              value: demo.batteryBars.toDouble(),
              min: 0,
              max: 5,
              divisions: 5,
              label: '${demo.batteryBars}',
              onChanged: (v) =>
                  setState(() => demo.batteryBars = v.round()),
            ),
          ],
        ),
      ),
    );
  }
}
