import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../camera/camera_connection.dart';
import '../../camera/camera_diagnostics.dart';

/// The Debug/Diagnostics sub-tab: an eight-step `Stepper` wizard that
/// captures real rec-mode camera responses and exposes them over the
/// in-app HTTP server. See SPEC Phase 2, *Pre-PR 5*.
class CameraDiagnosticsView extends ConsumerStatefulWidget {
  const CameraDiagnosticsView({super.key});

  @override
  ConsumerState<CameraDiagnosticsView> createState() =>
      _CameraDiagnosticsViewState();
}

class _CameraDiagnosticsViewState extends ConsumerState<CameraDiagnosticsView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    ref.read(cameraDiagnosticsProvider).detachView();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final diag = ref.watch(cameraDiagnosticsProvider);
    final connected = ref.watch(cameraConnectionProvider).isConnected;

    return Stepper(
      currentStep: diag.currentStep,
      onStepTapped: diag.goToStep,
      onStepContinue: () => diag.goToStep(diag.currentStep + 1),
      onStepCancel: () => diag.goToStep(diag.currentStep - 1),
      controlsBuilder: (context, details) {
        final isLast = details.stepIndex == CameraDiagnostics.kLastStep;
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            children: [
              if (!isLast)
                FilledButton(
                  onPressed: details.onStepContinue,
                  child: const Text('Next'),
                ),
              if (details.stepIndex > 0)
                TextButton(
                  onPressed: details.onStepCancel,
                  child: const Text('Back'),
                ),
            ],
          ),
        );
      },
      steps: [
        Step(
          title: const Text('Baseline capture'),
          state: _stepState(diag, 0),
          isActive: diag.currentStep == 0,
          content: _captureStep(
            instruction:
                'Captures the read-only baseline: getstate, getsetting '
                '(shutter / ISO / aperture / EV), getinfo (allmenu, '
                'curmenu) and a lens probe. The camera must be connected '
                'and in record mode.',
            step: 0,
            connected: connected,
            diag: diag,
            runLabel: 'Run baseline capture',
            onRun: () => diag.runBaseline(),
          ),
        ),
        Step(
          title: const Text('Busy field'),
          state: _stepState(diag, 1),
          isActive: diag.currentStep == 1,
          content: _captureStep(
            instruction:
                'Hunts the getstate busy/idle field. Set the camera dial '
                'to M first so a 4 s shutter is accepted. Running this '
                'sets a 4 s shutter, watches getstate for ~15 s and fires '
                'a capture mid-window — the shutter will open for ~4 s. '
                'If the shutter set is rejected, set a slow shutter on the '
                'body and run again.',
            step: 1,
            connected: connected,
            diag: diag,
            runLabel: 'Run busy watch',
            onRun: () => diag.runBusyWatch(),
          ),
        ),
        Step(
          title: const Text('setsetting round-trip'),
          state: _stepState(diag, 2),
          isActive: diag.currentStep == 2,
          content: _captureStep(
            instruction:
                'Sets shutter / ISO / aperture to known values and reads '
                'each back — to see whether the body echoes our exact '
                'wire values or a canonical form.',
            step: 2,
            connected: connected,
            diag: diag,
            runLabel: 'Run round-trip',
            onRun: () => diag.runRoundTrip(),
          ),
        ),
        Step(
          title: const Text('Invalid set'),
          state: _stepState(diag, 3),
          isActive: diag.currentStep == 3,
          content: _captureStep(
            instruction:
                'Sends three deliberately invalid setsetting calls to '
                'capture the exact err_* strings the camera returns.',
            step: 3,
            connected: connected,
            diag: diag,
            runLabel: 'Run invalid set',
            onRun: () => diag.runInvalidSet(),
          ),
        ),
        Step(
          title: const Text('Mode rejection'),
          state: _stepState(diag, 4),
          isActive: diag.currentStep == 4,
          content: _modeRejectionStep(connected: connected, diag: diag),
        ),
        Step(
          title: const Text('Shutter sweep'),
          state: _stepState(diag, 5),
          isActive: diag.currentStep == 5,
          content: _captureStep(
            instruction:
                'Sets every entry in the app\'s 19-value shutter list in '
                'turn and reads each back — a definitive accepted / '
                'rejected table. Set the dial to M first. Note whether the '
                'body\'s shutter type is mechanical or electronic — run it '
                'once for each if the slow speeds get rejected.',
            step: 5,
            connected: connected,
            diag: diag,
            runLabel: 'Run shutter sweep',
            onRun: () => diag.runShutterSweep(),
          ),
        ),
        Step(
          title: const Text('Aperture sweep'),
          state: _stepState(diag, 6),
          isActive: diag.currentStep == 6,
          content: _captureStep(
            instruction:
                'Sets every entry in the app\'s aperture list in turn and '
                'reads each back — confirms the f-stop wire encoding and '
                'which stops the mounted lens accepts. Set the dial to A '
                'or M. Out-of-range stops will err — that is expected.',
            step: 6,
            connected: connected,
            diag: diag,
            runLabel: 'Run aperture sweep',
            onRun: () => diag.runApertureSweep(),
          ),
        ),
        Step(
          title: const Text('Review & export'),
          state: diag.currentStep == 7 ? StepState.editing : StepState.indexed,
          isActive: diag.currentStep == 7,
          content: _reviewStep(diag),
        ),
      ],
    );
  }

  StepState _stepState(CameraDiagnostics diag, int step) {
    if (diag.currentStep == step) return StepState.editing;
    if (diag.snapshotsForStep(step).isNotEmpty) return StepState.complete;
    return StepState.indexed;
  }

  Widget _captureStep({
    required String instruction,
    required int step,
    required bool connected,
    required CameraDiagnostics diag,
    required String runLabel,
    required VoidCallback onRun,
  }) {
    final results = diag.snapshotsForStep(step);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(instruction),
        const SizedBox(height: 12),
        if (!connected)
          const _Hint('Connect the camera on the Camera sub-tab first.'),
        FilledButton.icon(
          onPressed: (connected && !diag.isRunning) ? onRun : null,
          icon: diag.isRunning
              ? const _Spinner()
              : const Icon(Icons.play_arrow),
          label: Text(runLabel),
        ),
        if (results.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...results.map((s) => _SnapshotTile(snapshot: s)),
        ],
      ],
    );
  }

  Widget _modeRejectionStep({
    required bool connected,
    required CameraDiagnostics diag,
  }) {
    final results = diag.snapshotsForStep(4);
    final enabled = connected && !diag.isRunning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Mode-dependent rejection. Set the dial to A and tap the first '
          'button; then set the dial to S and tap the second. Each tries '
          'a shutter and an aperture set — we want to see which the body '
          'rejects.',
        ),
        const SizedBox(height: 12),
        if (!connected)
          const _Hint('Connect the camera on the Camera sub-tab first.'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: enabled ? () => diag.runModeRejection('A') : null,
              icon: const Icon(Icons.camera),
              label: const Text('Dial is at A — run'),
            ),
            OutlinedButton.icon(
              onPressed: enabled ? () => diag.runModeRejection('S') : null,
              icon: const Icon(Icons.camera),
              label: const Text('Dial is at S — run'),
            ),
          ],
        ),
        if (results.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...results.map((s) => _SnapshotTile(snapshot: s)),
        ],
      ],
    );
  }

  Widget _reviewStep(CameraDiagnostics diag) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${diag.snapshots.length} captures collected this session '
            '(in-memory — they reset when the app restarts).'),
        const SizedBox(height: 12),
        const _Hint('Leave the camera AP and join the dev machine\'s WiFi '
            'before starting the server.'),
        if (diag.serverRunning) ...[
          Row(
            children: [
              const Icon(Icons.lan, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  diag.serverUrl ?? '—',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            diag.mdnsRegistered
                ? 'Discover from the dev machine:\n'
                    '  avahi-browse -rt _http._tcp   →   sciens-diag'
                : 'mDNS advert inactive — use the IP above.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => diag.stopServer(),
            icon: const Icon(Icons.stop),
            label: const Text('Stop server'),
          ),
        ] else
          FilledButton.icon(
            onPressed: () => diag.startServer(),
            icon: const Icon(Icons.cloud_upload),
            label: const Text('Start server'),
          ),
        if (diag.serverError != null) ...[
          const SizedBox(height: 8),
          Text(
            diag.serverError!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (diag.snapshots.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Text('All captures', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: () => diag.clearSnapshots(),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear'),
              ),
            ],
          ),
          ...diag.snapshots.map((s) => _SnapshotTile(snapshot: s)),
        ],
      ],
    );
  }
}

class _SnapshotTile extends StatelessWidget {
  const _SnapshotTile({required this.snapshot});
  final DiagnosticSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = snapshot.ok;
    final detail = snapshot.body ?? snapshot.error ?? '(empty)';
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        color: ok ? Colors.green : theme.colorScheme.error,
        size: 20,
      ),
      title: Text(snapshot.name, style: theme.textTheme.bodyMedium),
      subtitle: Text(snapshot.request, style: theme.textTheme.bodySmall),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          color: theme.colorScheme.surfaceContainerHighest,
          child: SelectableText(
            detail,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
