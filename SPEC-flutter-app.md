# Feiyu SCORP C2 — Custom Flutter remote app

## Goal

Build a small Flutter/Dart Android app — **"Sciens Gimbal Controller"**,
tagline *"old glass goes digital"* — that talks directly to the Feiyu
SCORP C2 gimbal over BLE, eventually replacing the stock app for one
specific use case: **Brenizer-style panorama with vintage long-focal
lenses**.

Workflow the final app must support (target, not Phase 0):

1. **Level**: button to send the gimbal to horizon (pitch = 0, roll = 0).
2. **Frame**: user mounts a wide reference lens (e.g. 24 mm), tilts the
   gimbal manually with the master control wheel, composes.
3. **Swap**: user mounts the actual capture lens (e.g. a vintage 90 mm
   Perigraphe Rapid Rectilinear with a large image circle).
4. **Configure**: user enters *frame lens focal* (24 mm) and *capture
   lens focal* (90 mm) and an overlap percentage.
5. **Start**: app reads gimbal's current orientation as the panorama
   centre, computes the grid, and runs a custom shot sequencer (rotate →
   settle → shutter → wait → next).

This spec covers **Phase 0 only**: prove we can talk to the gimbal and
provide an interactive playground for protocol exploration. Later phases
are sketched at the end.

The original `SPEC.md` (patching the stock APK to extend the focal-length
list) is preserved as a documented fallback if this project gets
shelved.

## Hardware / software

- Gimbal: Feiyu SCORP C2 (firmware version to record once readable).
- Camera: Panasonic Lumix S5 (full-frame). Shutter is triggered by a
  **cable from the gimbal to the camera's remote port** — so `TAKE_PHOTO
  = 64` over BLE is sufficient; no camera-side protocol work needed.
- Phone: Android (developer device; specific Android version to be
  recorded). iOS out of scope.
- Host (development): Ubuntu / Linux, working dir
  `/home/nidwe72/development/feiyutech/`.
- Reference: jadx-decompiled stock app at `jadxOutput/`. This is the
  source of truth for the protocol; we reverse-engineer from this code,
  not from the gimbal directly.

## Reference: what's already known from the stock app

From `jadxOutput/sources/com/feiyutech/lib/gimbal/`:

- `protocol/RequestId.java` — ~140 numeric command IDs. Relevant for us:
  - `ROTATE_SPECIFIED_ANGLE = 95` — absolute-angle goto
  - `ROTATE_RELATIVE_ANGLE = 103` — relative-angle goto
  - `TAKE_PHOTO = 64`
  - `TIMELAPSE_PHOTOGRAPHY_CURRENT_ANGLE = 32` — read current angles
  - `FOLLOW_MODE = 54`, `INCEPTION_MODE = 115`, `USE_MODE = 55` —
    operating modes that may affect leveling behaviour
- `protocol/AkProtocol.java` — frame format (the "AK protocol").
- `request/`, `request/impl/` — packet builders.
- `parse/cellparser/` — response parsers.
- `ble/` — BLE service/characteristic UUIDs, GATT operations.
- `data/AppStatus.java`, `data/GimbalState.java` — telemetry shapes.

We treat this as a Rosetta Stone: any byte format we're unsure about,
we look up in the Java.

## Branding

- **App display name** (Android launcher label): `Sciens Gimbal
  Controller`.
- **Tagline** (printed in the in-app header, see below): `old glas goes
  digital`.
- **Header panel** on every screen, at the top:
  - Line 1 (larger): app name.
  - Line 2 (smaller): tagline.
  - Visual styling left to implementation discretion — aim for "looks
    nice"; a clean dark/light palette and a non-default typographic
    treatment (e.g. a single accent colour, generous whitespace, light
    weight for the tagline) is enough. No logo yet.
- Internal Dart package name (snake_case): `sciens_gimbal_controller`.
- Android `applicationId`: `at.sciens.gimbal_controller` (reverse-domain
  convention).

## Phase 0 — scope (this spec)

Build a single Flutter Android app — `sciens_gimbal_controller` — that
provides:

### Screen 1: Connect

- "Scan" button → list of nearby BLE devices matching SCORP-like name or
  any device exposing the service UUID we determine from
  `lib/gimbal/ble/`.
- Tap a device → connect; show connection status (scanning / connecting
  / connected / disconnected, with error if any).
- Once connected, show: device name, MAC, MTU, list of discovered
  services and characteristics (UUID, properties: read/write/notify).
- "Disconnect" button.
- Reconnect-on-tap if connection drops; no auto-reconnect loop yet.

### Screen 2: Playground

Accessible only when connected. Top pane = controls, bottom pane = log.

**Status line** — always visible at the top of the playground:

- Current orientation: yaw / pitch / roll in degrees.
- Driven by the gimbal's notify stream once a parser exists, or polled
  on a ~1 Hz timer as a fallback.
- Validates the response-parse path and gives an at-a-glance check that
  motion commands actually took effect.

**Controls**:

- **Level (home)** — single button. Sends an absolute-angle rotate to
  `yaw = 0, pitch = 0, roll = 0` (full home position). Validates the
  absolute-rotate command. *Note:* this resets yaw too — the
  framing-with-the-wheel workflow that preserves yaw belongs to a later
  phase.
- **Pan left / Pan right** — two buttons. Each press rotates yaw by
  `±step` degrees (relative rotate).
- **Tilt up / Tilt down** — two buttons. Each press rotates pitch by
  `±step` degrees (relative rotate).
- **Step size** — single number input (default 10°), shared by pan and
  tilt buttons.

These controls plus the status line validate the two protocol primitives
we need first (absolute rotate, relative rotate) and the response-parse
path.

**Deliberately deferred from Phase 0**:

- **Take photo** — postponed; will be added as a small follow-up step
  once the motion primitives are confirmed working, before any further
  app augmentation.
- **Raw hex send** — not included. If we hit an unknown command we
  can add it ad hoc; not worth the UI cost up front.

**Bottom pane — log**

- Scrollable, append-only log of every frame in and out:
  - Timestamp.
  - Direction (TX/RX).
  - Hex bytes.
  - Decoded interpretation when we have a parser; otherwise raw.
- "Clear" button. "Copy" button to grab the log for the SPEC's protocol
  notes.

### What Phase 0 deliberately does NOT do

- No panorama workflow.
- No iOS.
- No background service / auto-reconnect on phone sleep.
- No app store packaging or signing beyond debug builds.
- No persistence of last-connected device, last-used inputs, etc.
- No localisation, no error analytics. Theming limited to the header
  treatment described under Branding.

The whole point of Phase 0 is to confirm we can drive the gimbal at all
and to give us a fast feedback loop for figuring out the rest.

## Architecture sketch (Phase 0)

```
sciens_gimbal_controller/
├── lib/
│   ├── main.dart              # bootstrap, routing (2 screens)
│   ├── ble/
│   │   ├── ble_client.dart    # thin wrapper around flutter_blue_plus
│   │   └── frame_codec.dart   # AK protocol framing (encode/decode)
│   ├── protocol/
│   │   ├── request_ids.dart   # constants mirrored from RequestId.java
│   │   ├── commands.dart      # typed Dart functions per known command
│   │   └── parsers.dart       # parse known response payloads
│   ├── ui/
│   │   ├── header.dart        # shared header panel (name + tagline)
│   │   ├── connect_screen.dart
│   │   ├── playground_screen.dart
│   │   └── log_view.dart
│   └── state/
│       └── app_state.dart     # connection + log via Riverpod/Provider
├── android/                   # standard Flutter Android scaffold
├── pubspec.yaml
└── README.md
```

Package choices (subject to revision):

- BLE: **`flutter_blue_plus`** — actively maintained, broad device
  support. (`flutter_reactive_ble` is the main alternative; pick after a
  small spike.)
- State: Riverpod or `ChangeNotifier`. Start with whatever is fastest;
  refactor later.
- Hex / bytes: package `convert` or hand-rolled.

## Reverse-engineering plan

We don't need to RE blindly — the decompiled Java is the spec. Workflow
per command:

1. Read the Java path: `RequestId` → request builder in
   `lib/gimbal/request/impl/` → frame assembly in `protocol/AkProtocol`.
2. Port the framing logic verbatim to Dart (`frame_codec.dart`).
3. Mirror the command-specific builder in `commands.dart`.
4. Test in the Playground: send, observe in the log, confirm the gimbal
   does what's expected.
5. For responses, read the matching parser in `parse/cellparser/` and
   mirror in `parsers.dart`.

Order of commands to bring up (aligned with the playground controls):

1. **Connect, discover services, identify write & notify
   characteristics.** Subscribe to notify; confirm any push
   notification is received.
2. **Query / parse current orientation** (read-only, safe). Drives the
   playground's status line.
3. **Rotate by small relative angle** (e.g. yaw ±5°) — first command
   with a physical effect; powers Pan and Tilt buttons.
4. **Rotate to absolute angle** — powers the Level (home) button.

A follow-up step after Phase 0 completes will add **Take photo** before
the panorama work begins.

## Risks & open questions

- **BLE permissions on modern Android** (12+): `BLUETOOTH_SCAN`,
  `BLUETOOTH_CONNECT`, plus location permission for some scan modes.
  Flutter BLE packages handle the request flow but the manifest entries
  must be right. Cost: ~30 min on the spike.
- **Pairing / authentication handshake**: some gimbal vendors require a
  vendor handshake after GATT connect before commands are accepted.
  Whether the SCORP C2 does is unknown — confirm by reading
  `lib/gimbal/ble/` in the decompiled stock app and replicating any
  initial frames.
- **Frame integrity (CRC / checksum)**: AK protocol almost certainly
  includes a checksum; commands without it will be silently dropped.
  Read `AkProtocol.java` carefully.
- **Rate limits / pacing**: writes too fast may be dropped. Stock app's
  request queue (`request/` package) probably encodes the right pacing.
- **Angle units**: degrees vs. 0.01-degree integer units vs. signed
  16-bit — to be confirmed from the parser.
- **Multi-device flag**: parser splits behavior on device type (we saw
  `WG2_*` variants in `RequestId`). Confirm SCORP C2 uses the non-`WG2`
  set.
- **Safety**: early testing should be done with the gimbal in a stable
  cradle, away from obstacles, with light or no payload, in case a
  malformed command causes large unexpected motion.

## Build & deploy workflow

- Local build on the Linux workstation:
  ```
  flutter build apk --debug
  ```
  Output at `build/app/outputs/flutter-apk/app-debug.apk`.
- Deployment to the Android phone: the phone exposes a directory of its
  storage to the workstation via an FTP server, mounted on the
  workstation. The build script (or a manual `cp`) copies the produced
  APK into that mount.
- On the phone, the user opens the APK in a file manager and installs
  it. "Install from unknown sources" must be allowed for that file
  manager.
- For Phase 0 the APK is **debug-signed** (Flutter's default debug
  keystore). Release-signing comes later, if and when needed.
- ADB is not required for Phase 0; if it becomes convenient later we can
  add it but the spec doesn't depend on it.

## Verification checkpoints (Phase 0) — **complete**

- [x] App scans, lists the gimbal, connects.
- [x] Service / characteristic table shown on connect screen matches
      what's referenced in `lib/gimbal/ble/`.
- [x] Subscribed notifications produce visible bytes in the log.
- [x] Orientation status line updates with sensible yaw / pitch / roll
      values.
- [x] Pan and Tilt buttons produce visibly correct relative motion at
      the configured step size, in the correct direction. (~0.5–1°
      accuracy after 1° pitch coast compensation.)
- [x] Level button drives the gimbal to home (yaw = pitch = roll ≈ 0)
      via up to 4 iterative passes.
- [x] Log can be copied out and pasted as protocol notes.

Phase 0 is **done**. Adding Take Photo (`cmdId 63`) is the next
step if/when needed.

## Phase 0 — as built (deviations from the original plan)

A few significant deviations during implementation, all documented in
PROTOCOL-NOTES.md:

- **Step 6 (handshake) skipped** — `BleCommunicator.onConnectionStateChanged`
  shows no application-layer auth frames; just enable notify and
  request MTU=512.
- **Plan A for motion (use `ROTATE_SPECIFIED_ANGLE` or
  `ROTATE_RELATIVE_ANGLE`) abandoned for SCORP-C2.** The SCORP entry
  in `gimbal-properties-ble.xml` doesn't declare
  `<rotateSpecifiedAngle/>` and the gimbal ignores the command. We
  ported the stock app's closed-loop joystick pattern instead
  (PROTOCOL-NOTES §7).
- **No true Lock mode on SCORP-C2.** `SET USE_MODE = 3` puts the
  gimbal in FPV (mode label "FPV" on the OLED), not Lock — the
  AI-suggested mapping with LK at value 3 doesn't match this
  firmware. Without a Lock mode the gimbal slowly drifts back toward
  the handle pose after a move ends (~1°/25 s); accepted as small
  enough for typical panorama-shoot durations.
- **Per-move pitch coast compensation** — every tilt move overshoots
  its target by ~1°. We pre-subtract 1° from the user-requested pitch
  delta so the natural coast lands at the intended angle. Course
  doesn't show the same bias. (`GimbalConnection._pitchCoastCompensation`.)
- **Iterative leveling** — a single pass undershoots at large angles
  (>20°) due to coast variability and an earlier 5 s timeout that has
  since been replaced. `levelHome` now loops up to 4 passes,
  recomputing the residual to (0, 0) each pass and exiting early
  within 0.5°.
- **Stall detection instead of fixed timeout** — `_onMoveTick` watches
  for per-axis "no progress in 500 ms with non-zero commanded speed"
  to abort stuck moves. A coarse 60 s absolute timeout remains as a
  defence-in-depth fallback.
- **Mode indicator** — extra UI element (not in the original spec)
  added to the status bar showing the parsed `followMode` from
  GIMBAL_STATE, in case the user wants to see the current gimbal mode.
- **RX log filter** — the log got swamped by GIMBAL_STATE pushes;
  added a filter chip in the log header that toggles RX visibility.
  Default is "hide RX".

## Phase 0 — measured characteristics

- Connect → ready: ~1.5 s typical (BLE connect + MTU + discover +
  notify enable).
- Motion accuracy: **~0.5° after compensation** for moves ≥ 2°. Below
  2° the compensation skips and the move may be a no-op.
- Angular rate (across all speed shelves): **~5 °/s average**. A 20°
  move ≈ 4 s, 90° ≈ 18 s.
- Post-move drift toward handle pose: **~1° per 25 s**. Acceptable
  for typical 15–30 s panorama shoots.
- BLE rate during motion: 20 Hz joystick TX + ~10 Hz GIMBAL_STATE RX.

## Phase 0 — implementation steps (all complete ✓)

Each step is a self-contained checkpoint with its own verification.
Stop and re-evaluate if any step's verification fails before moving on.

### Step 1 ✓ — Scaffold project
**Goal:** empty Flutter app that builds.
**Deliverable:** `flutter create` invoked with the right names; pubspec
dependencies declared (`flutter_blue_plus`, a state-management package,
`permission_handler`); AndroidManifest with label `Sciens Gimbal
Controller`, `applicationId at.sciens.gimbal_controller`,
`minSdkVersion` and `targetSdkVersion` set for Android 13; permissions
declared: `BLUETOOTH_SCAN` (with `android:usesPermissionFlags="neverForLocation"`),
`BLUETOOTH_CONNECT`. Legacy `ACCESS_FINE_LOCATION` not required since
the target phone is Android 13. Default counter app removed.
**Verification:** `flutter build apk --debug` succeeds; APK installs and
launches on the phone showing an empty screen.

### Step 2 ✓ — Header + screen skeleton
**Goal:** the two-screen UI shell.
**Deliverable:** `ui/header.dart` widget (app name + tagline);
ConnectScreen and PlaygroundScreen with the header at the top and
placeholders for content; navigation: start at ConnectScreen, a debug
button navigates to PlaygroundScreen.
**Verification:** both screens display correctly on the phone; header
shows on both.

### Step 3 ✓ — BLE permissions + scanning
**Goal:** runtime BLE permissions handled, devices listed.
**Deliverable:** `permission_handler` requests
`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`/location at app start; ConnectScreen
has a Scan button that populates a list of nearby BLE devices (name +
MAC + RSSI).
**Verification:** running the app on the phone shows the SCORP C2 in the
list (with the gimbal powered on and discoverable).

### Step 4 ✓ — Read the protocol from the decompiled Java
**Goal:** understand the AK protocol *before* writing Dart.
**Deliverable:** a short notes file (`PROTOCOL-NOTES.md`) capturing:
  - BLE service UUID, write characteristic UUID, notify characteristic
    UUID, and for each characteristic: write mode used by the stock app
    (with-response vs without-response), and whether the push channel is
    `notify` or `indicate`. From
    `jadxOutput/sources/com/feiyutech/lib/gimbal/ble/`.
  - MTU: does the stock app call `requestMtu(...)` at connect time? If
    yes, with what value? (Default 23 is often too small for AK frames.)
  - Frame format (sync bytes, length, addressing, payload, checksum) from
    `protocol/AkProtocol.java`, including endianness.
  - Whether any pairing/handshake frames are exchanged at connect time.
  - Byte format for the three commands we need:
    `ROTATE_SPECIFIED_ANGLE = 95`, `ROTATE_RELATIVE_ANGLE = 103`, and the
    current-angle query / push (around `RequestId` 32). For each, record:
    field offsets, signedness, units (degrees vs 0.01° vs ...), and
    yaw wraparound convention (0..360 vs −180..180).
  - At least **one full byte-level worked example** per command — both
    TX and RX — derived by tracing the Java logic, that we can later
    compare against actual captures from the Playground.
  - Definition of "home" (yaw=0 / pitch=0 / roll=0) as the gimbal
    firmware interprets it, if discoverable from comments or constants.
**Verification:** the notes file is concrete enough that Steps 5–10 can
be implemented without re-reading the Java each time.

### Step 5 ✓ — BLE connect + service discovery
**Goal:** connect to the gimbal and see its GATT.
**Deliverable:** tapping a device in ConnectScreen connects, runs
service discovery, displays the resulting service/characteristic tree,
and navigates to PlaygroundScreen on success; subscribes to the notify
characteristic and routes raw RX bytes to the log.
**Verification:** connection succeeds; service tree matches what's
referenced in the decompiled Java; any push notification from the
gimbal (e.g. periodic status) shows up as raw bytes in the log.

### Step 6 (skipped — no handshake) — Pairing/handshake (only if Step 4 revealed one)
**Goal:** make subsequent commands accepted by the gimbal.
**Deliverable:** if the stock app exchanges an initial handshake at
connect, replicate it.
**Verification:** subsequent test frames are not silently dropped.
Skip this step entirely if no handshake is present.

### Step 7 ✓ — Frame codec
**Goal:** encode/decode AK protocol frames in Dart.
**Deliverable:** `ble/frame_codec.dart` with `encodeFrame(requestId,
payload) -> bytes` and `decodeFrames(stream) -> Stream<Frame>` (handles
fragmentation/buffering); unit tests against fixture byte sequences
derived from the Java logic.
**Verification:** unit tests pass; codec roundtrip is identity for
known-good frames.

### Step 8 ✓ — Current-orientation status line
**Goal:** read-only command working end-to-end.
**Deliverable:** Dart implementation of the current-angle query (or
subscription to the push that carries it); parser produces
`(yaw, pitch, roll)` in degrees; PlaygroundScreen displays them as a
status line updating at least 1 Hz.
**Verification:** status line shows plausible values; tilting the
gimbal by hand changes the displayed values in the correct direction
and units.

### Step 9 ✓ — Relative rotate (Pan / Tilt buttons) — implemented via Plan B (closed-loop joystick) since Plan A failed on SCORP-C2
**Goal:** first motion command.
**Deliverable:** Dart implementation of `ROTATE_RELATIVE_ANGLE`;
Pan ± and Tilt ± buttons wired to it; step-size input (default 10°).
**Safety:** for the very first test, set step size to **1–2°**, not the
default 10°, and have the gimbal in a stable cradle without a camera
mounted. Bump to 10° only after direction and units are confirmed.
**Verification:** each button press produces a single, correctly-sized,
correctly-directed gimbal motion; the status line confirms the new
orientation.

### Step 10 ✓ — Absolute rotate (Level/Home button) — implemented as iterative closed-loop levelling since absolute-goto isn't supported
**Goal:** the second motion command.
**Deliverable:** Dart implementation of `ROTATE_SPECIFIED_ANGLE`; Level
button wired to send `(0, 0, 0)`.
**Verification:** Level button drives the gimbal to home from any
starting orientation; status line reads ~0 / 0 / 0 afterwards.

### Step 11 ✓ — Log polish + Phase 0 sign-off
**Goal:** Phase 0 verification checkpoints complete.
**Deliverable:** the log view scrolls correctly, has Clear and Copy
buttons, shows a decoded summary line next to each frame's hex.
**Verification:** every checkpoint in *Verification checkpoints
(Phase 0)* passes.

When Step 11 is done, Phase 0 is complete and the take-photo follow-up
step begins.

## Phase 1 — Demo mode and 3D visualization

Two related additions, plus a small UI restructure:

1. A software-only **demo gimbal** so the app is useful without hardware
   — for showcases, for development without the gimbal in reach, for
   running on Android emulators that lack BLE radios, and so a user who
   doesn't own a SCORP C2 can still see what the app offers.
2. A **3D-ish visualization** of the current gimbal pose (wireframe
   sphere + abstract camera body + lens + axis triad), shown on the
   pan/tilt/roll controls tab. Connection-agnostic — same widget for
   real and demo gimbals, driven only by the orientation stream.
3. **Tabs under the header** on the Playground screen: the controls
   stay where they are, the log panel moves out into its own tab.

**Important — both connection paths get the same UI.** Items 2 and 3
apply unconditionally: when the user connects to a *real* SCORP C2,
they see the same tabbed Playground with the 3D visualization on top
of the controls tab. The demo isn't a separate "demo screen"; it's
an alternative *transport* feeding the same widgets.

### Demo gimbal — design

**Connect-screen entry**

- A synthetic entry shown unconditionally at the top of the device list
  in `ConnectScreen`, above any scanned BLE devices.
- Present in both **debug and release** builds — the demo is a
  user-facing feature, not a developer flag.
- Visually distinguishable (e.g. a "DEMO" badge / chip beside the name)
  so it can't be mistaken for a real gimbal.
- Metadata for the row:
  - Name: `Demo Gimbal`
  - MAC: `00:00:00:00:00:01` (a clearly-fake reserved-looking address)
  - RSSI: fixed sentinel (e.g. `—`) so the row layout doesn't shift.
- Tapping it "connects" via the same `GimbalConnection.connect(...)`
  path as a real device — the same status strings appear in sequence
  on screen, just driven by the demo transport's quick-resolving
  lifecycle methods.

**Device-list abstraction (small refactor on the Connect screen)**

`ConnectScreen` currently keeps a `List<ScanResult>` from
`flutter_blue_plus` and taps the underlying `BluetoothDevice`
directly. To mix one synthetic row in with the scanned ones we
introduce a small sealed wrapper:

```dart
sealed class DeviceRow {
  String get displayName;
  String get subtitle;        // MAC for real, '00:00:00:00:00:01' for demo
  String get rssiText;        // 'NN dBm' for real, '—' for demo
  bool   get isDemo;
}
class ScannedRow extends DeviceRow {
  final ScanResult scan;
  // displayName = scan.device.platformName, etc.
}
class DemoRow extends DeviceRow {
  // hard-coded 'Demo Gimbal', etc.
}
```

`ConnectScreen` now holds `List<DeviceRow> _rows` instead of
`List<ScanResult> _results`. Each scan refresh maps incoming
`ScanResult`s to `ScannedRow`s; a single `DemoRow` is prepended so
it always appears first in the list. Tap handler dispatches by
subtype: `ScannedRow` → BLE connect path (build a
`BleGimbalTransport(scan.device)`); `DemoRow` → demo path (build a
`DemoGimbalTransport()`). Both then go through the same
`GimbalConnection.connect(transport)` so screen navigation and
status messaging are identical.

**Where it plugs in (protocol-level mock)**

The demo simulates a **fake BLE transport**, not a higher-level mock.
Everything from `frame_codec.dart` upward — encoders, command builders,
parsers, the `GimbalConnection` state machine, the closed-loop joystick
controller, iterative leveling — runs **unchanged**. Only the byte
transport is swapped out. Rationale: keeps the AK protocol code paths
exercised in demo mode, and means the demo cannot drift out of sync
with the real protocol when the parsers/encoders evolve.

Refactor sketch:

- New abstract interface `GimbalTransport`. Exposes the BLE-shaped
  connect lifecycle as **phase-level methods** so `GimbalConnection`
  can drive the existing user-facing status message sequence
  (`Connecting…` → `Requesting MTU…` → `Discovering services…` →
  `Enabling notifications…` → `Connected`) by emitting a status
  string before each phase. The transport itself **owns no
  user-visible strings** — it is purely a byte channel + lifecycle
  primitives.

  ```dart
  abstract class GimbalTransport {
    // Lifecycle (each phase maps 1:1 to a status string in
    // GimbalConnection). Returning false aborts.
    Future<bool>  openConnection();      // BLE: GATT connect.
                                         // Demo: short artificial delay.
    Future<int?>  prepareLink();         // BLE: requestMtu(512), returns
                                         //      negotiated MTU.
                                         // Demo: returns 512 instantly.
    Future<bool>  discoverEndpoints();   // BLE: discoverServices + find
                                         //      write/notify chars.
                                         // Demo: no-op.
    Future<bool>  subscribeIncoming();   // BLE: setNotifyValue(true) and
                                         //      pipe data to `incoming`.
                                         // Demo: start the simulator's
                                         //      ~10 Hz GIMBAL_STATE pump.
    Future<void>  disconnect();

    // Byte channel.
    Future<void>  sendFrame(Uint8List bytes);
    Stream<Uint8List> get incoming;

    // Disconnect notifications (e.g. the gimbal goes out of range).
    Stream<void> get disconnected;
  }
  ```

- `BleGimbalTransport` — wraps `flutter_blue_plus` and contains
  everything BLE-specific that currently lives in
  `state/gimbal_connection.dart` (UUIDs, GATT connect, MTU request,
  service discovery, characteristic lookup, notify subscription,
  write helper).
- `DemoGimbalTransport` — pure-Dart simulator. Each lifecycle phase
  is a short `Future.delayed(...)` returning success. On
  `sendFrame`, decodes the AK frame, simulates the effect on a
  virtual gimbal state, and emits AK-formatted response frames on
  `incoming` so the existing parsers consume them unchanged (same
  sync bytes, little-endian fields, message ids, checksum — per
  PROTOCOL-NOTES §5).
- `GimbalConnection` keeps ownership of:
  - The `_setStatus(...)` calls and the status-string vocabulary
    (`'Connecting…'`, `'Requesting MTU…'`, etc.) — same strings as
    today, same order. Demo mode shows the same strings because
    GimbalConnection emits them either way; the demo transport just
    happens to satisfy each phase quickly.
  - The frame decoder (`FrameStreamDecoder` wiring) and all
    higher-level state (orientation, follow-mode, closed-loop
    motion controller, level-home loop, log buffer).
  - **Error logging.** Today `GimbalConnection.send()` does
    `try/catch` around the BLE write and emits
    `LogEntry.error('Write failed: $e')`. After the refactor the
    pattern stays the same: `transport.sendFrame(bytes)` **throws**
    on transport failure, and `GimbalConnection.send()` catches and
    logs. The transport itself stays free of UI-facing strings
    (consistent with the same rule for status messages).

**Behavior model (observable parity, not firmware fidelity)**

The real device has quirks (pitch coast, slow drift toward the handle
pose, no true Lock mode) that the existing app layer already works
around — see `_pitchCoastCompensation` and the iterative `levelHome`
loop. The demo reproduces the **observable result** the user sees after
those workarounds, not the underlying quirks:

- **Initial state on connect:** `(yaw=0°, pitch=0°, roll=0°)`.
- **No drift toward a handle pose.** The real-device drift is cancelled
  by the closed-loop workarounds at the app layer; the demo's
  externally observable behavior should match that already-cancelled
  result, so the demo simply omits drift.
- **Pitch coast IS simulated** (1° overshoot in the direction of
  motion). Reason: `GimbalConnection.moveByAngle` in
  `state/gimbal_connection.dart:236-242` pre-subtracts
  `_pitchCoastCompensation = 1°` from every pitch move
  unconditionally — it has no notion of which transport it's
  attached to and shouldn't grow one. If the demo *didn't*
  overshoot, "tilt +10°" would consistently land at +9° in demo
  mode, breaking observable parity. So the demo overshoots pitch
  by 1° (clamped: small moves below the compensation threshold are
  no-ops on both real and demo paths, matching the existing
  early-return in `moveByAngle`). Course / yaw is not affected;
  the real device shows no equivalent bias on that axis and the
  app code doesn't compensate for one.
- **Motion timing matches the real device.** When the app drives the
  closed-loop joystick (the workaround for SCORP-C2's missing
  absolute-rotate), the demo transport integrates the virtual state
  at a rate that scales with the commanded joystick speed:

  > `°/s = (|speed| / 60) × 8`

  So `speed=60` (fast shelf) → 8°/s, `speed=40` (medium) → 5.3°/s,
  `speed=25` (slow) → 3.3°/s. A typical move averages ~5–6°/s,
  matching the measured Phase 0 rate. The `8°/s` peak is a tuning
  constant in `DemoGimbalTransport` — easy to nudge after live
  comparison. GIMBAL_STATE pushes emit at **~10 Hz** during motion
  and idle alike — matching the real-device RX rate so the closed-
  loop controller's tick cadence sees no difference.
- **GIMBAL_STATE frame payload.** **17 bytes**, matching the
  real-device frame size: byte [0] = mode (low 3 bits), [1-2] =
  pitch as int16-LE in 0.01°, [3-4] = roll, [5-6] = yaw, [7-15] =
  zero, [16] = `0xFF` (no mode override). Demo frames are
  byte-indistinguishable from real GIMBAL_STATE in the log.
- **Idle pump.** The 10 Hz GIMBAL_STATE emission runs **continuously
  while connected**, not only during commanded motion. The real
  device behaves the same way and the orientation status line's
  "Nms ago" freshness indicator (`playground_screen.dart:253-266`)
  would say "waiting…" forever if pushes stopped at idle.
- **Mode reporting.** GIMBAL_STATE pushes report a fixed
  `followMode = PF` (byte [0] low 3 bits = 0). No FPV / Lock
  toggling for the demo.
- **Joystick stream semantics.** Same as the real protocol — non-zero
  speed bytes drive motion, zero bytes mean stop. The existing stall
  detection / iterative-leveling code in `GimbalConnection` keeps
  working unchanged because the transport speaks the same wire format.
- **`SET USE_MODE` (cmdId 51).** Silently accepted. No effect on
  virtual state; the demo always reports the same fixed follow mode.
- **`ROTATE_SPECIFIED_ANGLE` (cmdId 93, absolute rotate).** Silently
  accepted, **no effect** — mirrors real-device behavior on
  SCORP-C2, which doesn't declare support for this command in
  `gimbal-properties-ble.xml`. The unused `GimbalConnection.gotoAngle`
  path stays speculative; the demo doesn't make it work.
- **Take-photo command (cmdId 63).** When implemented later, the
  demo logs the shutter event (visible in the log tab) but takes no
  other action.
- **`disconnect()` cleanup.** When the user taps Disconnect (or
  pops the Playground screen), `DemoGimbalTransport.disconnect()`
  stops the 10 Hz pump (`Timer.cancel()`), clears virtual state,
  and fires its `disconnected` stream so
  `GimbalConnection._teardown()` runs the same path as for a real
  disconnect. Symmetric with `BleGimbalTransport.disconnect()`,
  which closes the GATT connection and fires the same stream.

**Connection summary — decoupling from BLE types**

Today `_ConnectionSummary` reads `conn.device.platformName`,
`conn.device.remoteId`, and `conn.mtu` directly — all
`flutter_blue_plus` types. To support demo connections (where
`conn.device` is null), the BLE-typed getters on `GimbalConnection`
are augmented with transport-agnostic strings populated by either
transport:

| New getter on `GimbalConnection` | BLE transport populates | Demo transport populates |
|---|---|---|
| `connectedName` | `target.platformName` (e.g. `FY_SCORP_C2_CD`) | `'Demo Gimbal'` |
| `connectedId`   | `target.remoteId` (the MAC) | `'00:00:00:00:00:01'` |
| `mtu`           | negotiated MTU | `512` |

`_ConnectionSummary` reads these instead of touching `BluetoothDevice`
directly. The `BluetoothDevice` reference lives entirely inside
`BleGimbalTransport`.

**Service tree — dropped**

The `_ServiceTree` widget at `playground_screen.dart:351` was a Phase 0
diagnostic showing the discovered GATT services. It's removed entirely
in Phase 1: not part of the new tabbed layout, not shown for real or
demo connections. A user who needs the GATT tree can read the log
(notify enable events are logged on connect) or use a generic BLE
explorer. Removing it also keeps the `pan/tilt/roll` tab focused on
the visualization + controls.

### Playground screen — tabs restructure

The Playground layout becomes:

```
┌─ AppHeader ──────────────────────────────────────┐
├─ ConnectionSummary  (sticky, above the tabs) ────┤
│   device name · MAC · MTU · [Disconnect]         │
├─ TabBar  [ pan/tilt/roll │ logs ] ───────────────┤
│                                                  │
│   tab body                                       │
│                                                  │
└──────────────────────────────────────────────────┘
```

The `ConnectionSummary` row stays **sticky above the `TabBar`** —
deliberately not inside the tab body — so the Disconnect button and
connection identity stay visible regardless of which tab the user is
on. (Reading the log tab shouldn't hide Disconnect.)

Two tabs, exactly:

1. **`pan/tilt/roll`** — the **3D visualization** at the top of the tab,
   then everything currently on the Playground screen below it:
   orientation status line (yaw / pitch / roll), mode indicator,
   step-size input, pan ± / tilt ± / Level buttons. Nothing about these
   controls changes. The service tree is removed (see above).
2. **`logs`** — the existing log view (`log_view.dart`) moved here
   verbatim, including the scrollable list, decoded summary line per
   frame, Clear button, Copy button, and the RX-visibility filter chip.

Each tab uses `AutomaticKeepAliveClientMixin` so its state (log scroll
position, the visualization's smoothing interpolator) survives switching
tabs.

The Connect screen is unchanged (besides the demo entry described
above).

### 3D visualization widget

A single widget — `GimbalVisualization` — rendered at the top of the
`pan/tilt/roll` tab. Connection-agnostic: it subscribes to the
orientation stream published by `GimbalConnection` and doesn't care
whether the underlying transport is BLE or the demo simulator.

**Scene contents**

- **Wireframe sphere** centred in the widget — latitude/longitude lines,
  no fill, no shading. Provides a spatial reference frame.
- **Abstract camera body** — a small rectangular box, flat fills /
  outlines only, no shading.
- **Abstract lens** — a short cylinder attached to the camera body's
  +Z face.
- **3-axis triad** attached to the camera frame — three short
  orthogonal arrows, colour-coded (suggested: X = red, Y = green,
  Z = blue, with Z pointing out of the lens).

**Camera orientation**

- Rotated by the current `(yaw, pitch, roll)` from `GimbalConnection`.
  Right-handed conventions; signs and axis mapping follow what
  PROTOCOL-NOTES already established for the real device, so that the
  visualization tracks reality when a physical gimbal is connected.
- **Initial state** (before the first GIMBAL_STATE arrives, when
  `yawDeg/pitchDeg/rollDeg` are still `null`): render the camera in
  identity orientation — Z-axis pointing out of the screen, no
  rotation. Don't show an error or empty state; the first state push
  is ~100 ms away and will animate in cleanly.
- Smoothing: GIMBAL_STATE arrives at ~10 Hz; interpolate the rendered
  orientation over ~100 ms between samples so motion looks smooth at
  ~30 fps without overshooting.

**Rendering approach**

- Pure Flutter `CustomPainter` plus matrix math from Flutter's bundled
  `vector_math_64`. No new heavyweight 3D dependency.
- Software 3D: a fixed view matrix, a simple perspective projection,
  the gimbal-state rotation applied to the camera-body vertices /
  axis-triad vectors / sphere wireframe. Draw projected edges with
  `Canvas.drawLine` / `Canvas.drawPath`.
- **Flat 2D look** — no shading, no lighting, no z-sort. Wireframe
  sphere + outlined body is enough to read the pose.
- No user interaction with the widget (no orbit / drag-to-rotate).

### Architecture sketch (delta)

```
lib/
├── ble/
│   ├── frame_codec.dart                 # existing — unchanged
│   ├── commands.dart                    # existing — unchanged
│   ├── crc.dart                         # existing — unchanged
│   └── transport/                       # NEW
│       ├── gimbal_transport.dart        # NEW: abstract interface
│       ├── ble_gimbal_transport.dart    # NEW: real impl, extracted
│       └── demo_gimbal_transport.dart   # NEW: in-memory simulator
├── state/
│   └── gimbal_connection.dart           # existing; now consumes GimbalTransport
├── ui/
│   ├── header.dart                      # existing — unchanged
│   ├── connect_screen.dart              # existing + synthetic demo row
│   ├── playground_screen.dart           # restructured: TabBar host
│   ├── tabs/                            # NEW
│   │   ├── controls_tab.dart            # NEW: pan/tilt/roll content
│   │   └── logs_tab.dart                # NEW: hosts existing log_view
│   ├── log_view.dart                    # existing — moved into logs_tab
│   └── gimbal_visualization.dart        # NEW: 3D widget (CustomPainter)
└── main.dart
```

`pubspec.yaml`: no new dependencies expected (`vector_math_64` ships
with Flutter; `flutter_blue_plus`, `permission_handler` already present).

### Verification checkpoints (Phase 1)

- [ ] Connect screen lists a "Demo Gimbal" entry at the top of the
      device list, with a DEMO badge, in both debug and release builds.
- [ ] Tapping "Demo Gimbal" produces the same connection-state
      transitions as a real connect (with a short artificial delay),
      then opens the Playground screen.
- [ ] Playground screen shows two tabs under the header:
      `pan/tilt/roll` and `logs`.
- [ ] The `logs` tab shows the existing log content (Clear, Copy, and
      the RX-visibility chip all work).
- [ ] The `pan/tilt/roll` tab shows the 3D visualization at the top,
      then the existing status line, mode indicator, step input, and
      pan/tilt/level buttons.
- [ ] With the **demo** connected: Pan ± / Tilt ± produce motion at
      ~5°/s, status line and visualization update together, Level
      returns to (0, 0, 0), and the log tab shows TX frames + simulated
      GIMBAL_STATE RX frames in correct AK format.
- [ ] With a **real** gimbal connected: no regression in pan / tilt /
      Level behavior; the visualization tracks the live gimbal
      orientation in real time.
- [ ] Demo frames in the log are byte-for-byte indistinguishable from
      real frames (same sync, same endianness, same checksum, same
      command IDs).

### Implementation steps (later)

Phase 1 lands in **two sequential PRs** so the risky transport
refactor is isolated from the new-feature changes.

**PR 1 — Transport refactor (no user-visible change)**

1. Add `lib/ble/transport/gimbal_transport.dart` with the
   `GimbalTransport` interface shown above.
2. Add `lib/ble/transport/ble_gimbal_transport.dart`. Move
   BLE-specific code out of `state/gimbal_connection.dart`: GATT
   connect, `requestMtu`, `discoverServices`, characteristic
   lookup, `setNotifyValue`, the write helper, the disconnect
   listener. The transport owns the `BluetoothDevice` reference.
3. Refactor `GimbalConnection`:
   - `connect(BluetoothDevice target)` → `connect(GimbalTransport t)`.
   - Drive the phase methods (`openConnection` → `prepareLink` →
     `discoverEndpoints` → `subscribeIncoming`) with the existing
     `_setStatus(...)` strings emitted between phases.
   - Add transport-agnostic getters: `connectedName`,
     `connectedId`, `mtu`. Stop exposing `device` and `services`.
4. Update `_ConnectionSummary` to read the new getters.
5. Drop `_ServiceTree` from the Playground.
6. Update `ConnectScreen._onDeviceTap` to wrap the tapped device in
   `BleGimbalTransport(device)` and pass that to `conn.connect`.

   *PR 1 verification:* real gimbal connect / pan / tilt / Level
   behave exactly as before. No demo entry yet. No tabs yet.
   No 3D widget yet.

**PR 2 — Demo + tabs + visualization**

7. **`DeviceRow` sealed class** + `ConnectScreen` refactor to a
   `List<DeviceRow>` with a prepended `DemoRow`. DEMO badge in the
   UI.
8. **`DemoGimbalTransport`** in
   `lib/ble/transport/demo_gimbal_transport.dart`:
   - Each lifecycle phase: short `Future.delayed` (100 ms each is
     plenty), success.
   - On `sendFrame`: decode AK frame, dispatch on `cmdId`. Update
     virtual `(yaw, pitch, roll)` and commanded joystick speeds.
   - 10 Hz timer emits 17-byte GIMBAL_STATE frames on `incoming`.
   - Speed → rate: `°/s = (|speed| / 60) × 8`.
   - 1° pitch overshoot in the direction of motion.
   - All other commands silently accepted, no effect.
9. **Tab restructure** of the Playground:
   - Sticky `ConnectionSummary` above the `TabBar`.
   - `controls_tab.dart` hosts the visualization (top), orientation
     line, controls.
   - `logs_tab.dart` hosts the existing log view.
   - Both tabs use `AutomaticKeepAliveClientMixin`.
10. **`GimbalVisualization`** in `lib/ui/gimbal_visualization.dart`.
    Wireframe sphere + abstract camera body + lens + axis triad in
    `CustomPainter`. Driven by `gimbalConnectionProvider`'s
    orientation. ~100 ms smoothing interpolator. Identity
    orientation when state is null.
11. **Sign-off.** Walk every checkpoint below; capture a screenshot
    of the demo session and one of the real-gimbal session for the
    SPEC. Confirm demo / real bytes are indistinguishable in the
    log (sync, length, checksum).

### Out of scope (Phase 1)

- Persisting "last connection was demo" across launches.
- Simulating multiple demo gimbals.
- Simulating faults, disconnections, packet loss, or out-of-range
  commands. The demo accepts everything the app sends.
- Simulating drift, pitch coast, or other firmware quirks beyond
  observable post-workaround behavior.
- 3D shading, textures, lighting, or hidden-line removal.
- Touch interaction with the 3D widget (no orbit, no drag-to-rotate,
  no pinch-zoom).
- iOS / desktop / web targets (still excluded).

### Phase 1 — as built (additions beyond the original plan)

Code-level decisions all match the spec above. The following items
shipped alongside Phase 1 but weren't called out in the original
implementation-steps list:

- **Unit tests.** `test/demo_gimbal_transport_test.dart` — 14 tests
  using `package:fake_async` for deterministic timer control. Coverage:
  identity getters, lifecycle phases, MTU=512 return, throw-on-send
  before open, GIMBAL_STATE byte layout, 10 Hz idle pump cadence,
  motion integration at the fast and slow shelves, negative-direction
  motion, +1° / −1° pitch coast on speed→0 transitions, no coast when
  pitch never moved, no coast on the yaw axis, silent acceptance of
  unknown commands, disconnect-stops-pump. Combined with the existing
  `frame_codec_test.dart`, total **25 passing tests**. `fake_async
  ^1.3.1` added as `dev_dependency`.
- **Emulator launch scripts.** `scripts/waydroid-run.sh` and
  `scripts/genymotion-run.sh` automate `flutter build apk --debug` →
  device detection → install → launch for the two Linux Android
  emulators. Both support `--no-build`. `scripts/README-waydroid.md`
  documents one-time Waydroid setup (kernel binder module, container
  service, etc.).
- **README replacement.** The Flutter-scaffold `README.md` was
  rewritten with project overview, hardware list, quick-start, demo
  explanation, project-layout tree, roadmap, and tech stack.
- **GitHub publication.** Code lives at
  `github.com/nidwe72/sciens_gimbal_controller`. Public repo. Only the
  `sciens_gimbal_controller/` directory was pushed — the parent
  `feiyutech/` directory (SPEC docs, PROTOCOL-NOTES, jadx output)
  stays local. Authenticated over SSH using the developer's existing
  `~/.ssh/id_ed25519` key.

Concrete values for fields the spec left as "TODO / tunable":

- **3D smoothing time constant** τ = **50 ms** (reaches ~95 % of
  target in ~150 ms). Within the spec's "~100 ms" intent.
- **Demo lifecycle phase delay** = **100 ms** per phase × 4 phases =
  ~400 ms total. Within "a few hundred ms".
- **3D viewing transform** = fixed `rotateX(−0.40 rad)` then
  `rotateY(+0.35 rad)` — slight over-the-shoulder angle. Within
  "slight pitch-down + slight yaw-right".
- **DEMO badge styling** — primary-tinted chip beside the title in
  `_DeviceRowTile`; demo row uses `Icons.play_circle_outline`.

The verification checkpoints above remain unchecked because they
require running on the real SCORP C2. On-emulator behaviour (demo
transport, pan/tilt/level via the closed-loop controller, 3D
visualization tracking, tab state preservation, log indistinguish-
ability) is confirmed.

## Phase 2 — Camera control over WiFi

Add a new tab `camera` to the Playground screen, between
`pan/tilt/roll` (which stays the default) and `logs`. The tab exposes
minimal remote control of
the **Panasonic Lumix S5** over WiFi — independent of the gimbal
connection — so the user can adjust shutter speed and ISO and fire the
shutter from the same screen they're already using to point the
gimbal.

The camera and gimbal are **independent transports**: gimbal over BLE,
camera over WiFi. The Playground screen is entered via a gimbal
connection (real or demo); the camera tab inside has its own
Connect / Disconnect button. Either can be active without the other.

### Goal

A small, focused remote that covers exactly the workflow needs that
the gimbal-side shutter cable doesn't:

- Change shutter speed and ISO without touching the camera body.
- Trigger captures from inside the same app the gimbal uses.
- Frame composition with a live preview when desired (toggle).

Aperture stays on the **manual lens ring** for this body; the app
only reads and displays the current f-stop the camera reports back.

### Hardware / setup

- Camera: **Panasonic Lumix S5** (full-frame; released 2020). The
  S5 uses the same `cam.cgi` WiFi-remote protocol as the broader
  G / GH / S series. The closest published "tested" reference is
  `njfdev/liblumix` on the S5IIX.
- Connection model: **camera as the access point** (only).
  - On the camera: Menu → WiFi → Smartphone / Remote operation; the
    body broadcasts an SSID like `LUMIX-NNNNNN` (open or WPA2 — the
    user joins it once with the camera-shown password).
  - On the phone: join that network in Android Settings before
    opening our app, just as the official LUMIX Sync app expects.
  - Camera's default IP on its own AP: `192.168.54.1`. The UPnP
    device descriptor sits on port `60606`.
  - Android's "this network has no internet" prompt may ask the user
    to confirm they want to stay on it; that's fine and expected.
- Camera-AP-only is a deliberate Phase 2 scope choice. Same-WiFi mode
  (where camera joins the user's home/studio AP) is straightforward
  to add later — same protocol, same endpoints, different IP — but
  we don't spec it now.
- **Bluetooth pre-pair caveat (newer firmware).** Some Lumix bodies
  on post-2023 firmware require the user to first pair the camera
  with the official **LUMIX Sync** app via Bluetooth before the
  Smartphone/Remote-operation WiFi menu becomes usable. If the user's
  S5 firmware shows this behaviour, the one-time fix is the BT
  pairing in LUMIX Sync; our app then runs against the resulting WiFi
  mode unchanged.

### Reference: the Panasonic camera WiFi protocol

The protocol is reverse-engineered (Panasonic publishes no SDK). The
intelligence below is consolidated from active open-source clients;
we'll port the relevant pieces into Dart rather than re-deriving from
packet captures.

Best porting targets:

- **`njfdev/liblumix`** — C++, modern, tested on S5IIX (closest to
  S5). Primary reference.
- **`gphoto/libgphoto2`** `camlibs/lumix/lumix.c` — most authoritative
  source for the **shutter-speed encoding table** and the SOAP /
  ContentDirectory binding (if we ever need image transfer).
- **`peci1/lumix-link-desktop`** `Control.html` — quick-reference
  inventory of every `cam.cgi` URL in plain HTML/JS.
- **`cleverfox/lumixproto`** — terse README crib-sheet.
- MJPEG-over-UDP frame-header analysis:
  [mjt.me.uk/posts/wifi-streaming-video-lumix-gx80](https://www.mjt.me.uk/posts/wifi-streaming-video-lumix-gx80/).

#### Transport summary

All commands are HTTP `GET` against
`http://192.168.54.1/cam.cgi?mode=<MODE>&...`. Responses are XML;
success is `<result>ok</result>`. One controller at a time — the
camera tracks a single "owner" device-name. No persistent token or
cookie; the camera trusts whichever app most recently called
`accctrl` + `recmode`.

#### App identity (`accctrl`)

The first time our app contacts a particular camera body, the body
shows a prompt asking the user to confirm "Sciens" wants to connect.
Once accepted, the camera remembers the UUID + display-name pair and
silently approves later sessions. Pinned values:

| Field | Value | Notes |
|---|---|---|
| `value` (UUID) | `4D454900-1C3C-C912-CE00-FEE1FACE0001` | One-time, baked into the app. Don't change without expecting the camera to re-prompt the user. |
| `value2` (display name) | `Sciens` | Short — appears on the camera's small body screen. |

#### Endpoints we need

| Purpose | Endpoint |
|---|---|
| Register app as remote controller | `cam.cgi?mode=accctrl&type=req_acc&value=<UUID>&value2=<URL-encoded display name>` |
| Switch to stills/record mode | `cam.cgi?mode=camcmd&value=recmode` |
| Read general state | `cam.cgi?mode=getstate` |
| Enumerate all settable options | `cam.cgi?mode=getinfo&type=allmenu` (XML, contains the body-specific allowed shutter / ISO lists) |
| Get current shutter | `cam.cgi?mode=getsetting&type=shtrspeed` |
| Set shutter | `cam.cgi?mode=setsetting&type=shtrspeed&value=<N>/256` |
| Get current ISO | `cam.cgi?mode=getsetting&type=iso` |
| Set ISO | `cam.cgi?mode=setsetting&type=iso&value=<auto\|100\|200\|…>` |
| Get current aperture (read-only on this body) | `cam.cgi?mode=getsetting&type=focal` |
| Take a photo | `cam.cgi?mode=camcmd&value=capture` |
| Cancel an in-progress (e.g. bulb) capture | `cam.cgi?mode=camcmd&value=capture_cancel` |
| Start live-view stream to UDP `<PORT>` | `cam.cgi?mode=startstream&value=<PORT>` |
| Stop live-view stream | `cam.cgi?mode=stopstream` |

##### Shutter-speed encoding (the awkward bit)

The shutter value over the wire is **`<numerator>/256`** as a
plaintext string. Concrete examples from `libgphoto2`'s
`shuttermap[]`:

- `3328/256` → 1/8000 s
- `3072/256` → 1/4000 s
- `0/256`    → 1 s
- `256/256`  → "B" (bulb)
- Long exposures use negative numerators.

The community has small disagreements on the long-exposure end. **We
don't hardcode the table.** Instead we read the S5's actual supported
shutter values from `getinfo?type=allmenu` at connect time and
populate the dropdown from that list, mapping the numerator to a
human-readable label via the encoding rule
`displayed_seconds = pow(2, -numerator / 256)`. This auto-adapts to
whatever the S5 firmware actually allows.

##### ISO encoding (easier)

ISO values are plain strings: `auto`, `100`, `200`, …, `51200`,
etc. The S5's allowed list comes from `getinfo?type=allmenu`.

##### Aperture read & write

`getsetting?type=focal` returns `<numerator>/256` where the displayed
f-number is approximately `pow(2, numerator / 512)`. With a native
L-mount lens that carries an electronic aperture the app both reads
*and* writes it: setter `setsetting?type=focal&value=<numerator>/256`,
same encoding as the reader. A manual-aperture lens (or no lens
mounted) instead reports the `32767/256` sentinel — the app then
shows a read-only "set on lens" line and exposes no setter for that
poll. See *Connected state → Aperture row* for the UI behaviour and
the mode-enablement matrix.

#### Discovery

Per the research, SSDP advertising is **not guaranteed** on Lumix
bodies — many community clients fall back to manual IP. Our approach
on the camera-AP network:

1. **Send SSDP M-SEARCH** to `239.255.255.250:1900` with
   `ST: ssdp:all`. For each response, fetch the URL in the
   `LOCATION:` header and parse the returned XML device descriptor.
   Accept the descriptor as ours iff:
   - `<manufacturer>` matches `Panasonic` (case-insensitive), AND
   - `<modelName>` starts with `DC-` or `DMC-` (the Lumix model
     prefixes — `DC-S5`, `DC-GH6`, etc., or older `DMC-…`).

   Window: **3 seconds**. SSDP requires the
   `CHANGE_WIFI_MULTICAST_STATE` Android permission and a runtime
   `MulticastLock` (acquired on the WiFi manager before sending
   M-SEARCH, released after the window closes); see the Risks
   section.
2. **In parallel**, probe `http://192.168.54.1/cam.cgi?mode=getstate`
   directly; if it returns a Panasonic-shaped XML response (200 OK,
   parses, contains `<state>`), that's our camera. Window:
   **3 seconds**. This is the reliable path.
3. Whichever resolves first wins; cancel the other. Surface progress
   in the UI ("searching… found at 192.168.54.1").
4. **Manual-IP fallback.** If both 1 and 2 time out (e.g., the user
   is on a network where 192.168.54.1 is *not* the camera, or
   discovery is flaky over the emulator's NAT), the disconnected
   state offers a small text field labeled "Enter camera IP" with
   a Connect button next to it. Last manually-entered IP is
   remembered for the session (not persisted across launches).

#### HTTP request serialization

The Lumix protocol enforces "one controller at a time" but doesn't
document reentrancy. To avoid depending on Panasonic's undocumented
behaviour, all HTTP calls go through a **single FIFO queue inside
`lumix_camera.dart`** — at most one `cam.cgi` request in flight at any
time. The polling loop, the user's setting / capture taps, and the
connect-time sequence all enqueue here. The UDP MJPEG stream is
separate and unaffected — it runs concurrently with the HTTP queue.

**Queue cancellation on disconnect.** The queue exposes a `cancel()`
method. When the user taps Disconnect (or the Playground is being
popped) while requests are in flight, `cancel()` is called *first*:
the currently-executing request has its Future completed with an
error, all queued requests are dropped, then the polite-goodbye
sequence (below) runs as a final priority bypass. Without this,
disconnect would feel slow (up to the 5 s HTTP timeout) and the
polite-goodbye could pile up behind a doomed in-flight poll.

#### Connect-time and disconnect-time orderings

Both lifecycles have ordering requirements that aren't obvious from
the spec elsewhere — wrong order means HTTP traffic leaks over
cellular or SSDP multicast never reaches the camera.

**Connect order** (in `LumixCamera.connect()`):

```
1. bind()                            — WifiNetworkChannel: bind process
                                       to WiFi Network + acquire MulticastLock.
                                       Must precede anything else; SSDP
                                       multicast wouldn't reach us otherwise.
2. Discovery                         — SSDP M-SEARCH || GET 192.168.54.1/getstate
                                       (in parallel, first wins).
3. accctrl                           — register app; waits for body-side
                                       accept on first contact.
4. getstate                          — libgphoto2 prelude step (fatal on
                                       failure). Newer S-series firmware
                                       (S5/S5II/S5IIX/S5D) won't accept
                                       recmode without it.
5. setsetting?type=device_name       — re-affirm display name. Soft-
                                       failure: older bodies that don't
                                       support this still progress.
6. recmode                           — claim record mode.
7. getinfo?type=allmenu              — cache supported shutter/ISO lists.
8. → state = Connected.
```

Steps 4 and 5 are the **libgphoto2 prelude**, required on newer
S-series firmware. Without them, recmode returns `err_reject`.

**Disconnect order** (in `LumixCamera.disconnect()`):

```
1. queue.cancel()                    — drop pending HTTP work.
2. stopstream                        — only if a live-view stream is active.
3. camcmd?value=playmode             — the polite goodbye; returns the
                                       camera body to "waiting for connection".
4. unbind()                          — WifiNetworkChannel: release WiFi
                                       Network + MulticastLock.
5. Close HTTP client + UDP socket.
```

Steps 2–3 must precede step 4: they're HTTP calls that need the WiFi
binding in place, otherwise the OS may route them over cellular and
they'll silently fail. Step 1 must precede step 2 so the cancelled
in-flight request doesn't race the polite-goodbye writes.

#### Timeouts

| Phase / call | Timeout |
|---|---|
| SSDP M-SEARCH listen window | 3 s |
| Parallel `getstate` probe (discovery) | 3 s |
| `accctrl` (waits for user accept on camera body) | 60 s |
| Any other `cam.cgi` call | 5 s |
| Consecutive polling failures before disconnect | 3 |

`accctrl` gets its own elevated timeout because the camera may sit
on its confirmation prompt that long.

#### `recmode` and other connect-step failures

Any non-`<result>ok</result>` response in the connect lifecycle
(`accctrl` → `recmode` → `getinfo?type=allmenu`) aborts the connect:
the tab returns to Disconnected and surfaces the camera's response
text as the error message. Same for HTTP-level errors (timeout,
non-200, parse failure).

#### Live preview (MJPEG over UDP)

When the user toggles the live-preview checkbox on:

1. App binds a UDP socket on a local port (suggested **49199**,
   matching libgphoto2).
2. App sends `cam.cgi?mode=startstream&value=49199`.
3. Camera streams MJPEG-over-UDP — **one video frame per datagram**,
   ~20–30 KB each, at 640×480 / ~30 fps. (IP fragmentation will
   occur; rely on the OS-level reassembly into a single recvfrom.)
4. Each datagram begins with a Panasonic-specific header:
   - Read a **16-bit big-endian integer at byte offset 30**.
   - Add **32** to that value.
   - The result is the byte offset of the JPEG SOI marker
     (`0xFF 0xD8`) in the datagram.
   - The JPEG ends at the standard EOI marker (`0xFF 0xD9`).
   - The bytes between offset 32 and the JPEG SOI encode overlay
     metadata (AF rectangles, face-detection boxes); the app
     ignores these initially.
5. **Decode pipeline.** Each extracted JPEG is decoded in a worker
   `Isolate` (via `Isolate.run` for a one-shot decode per frame, or a
   long-lived isolate with a port if profiling shows spawn overhead
   matters) and rendered via `RawImage` / `Image.memory` on the UI
   isolate. Keeps the main isolate free of JPEG decode jitter.
6. **Frame rate cap = ~5 fps (default).** Even though the camera
   pushes ~30 fps, we drop frames at the receive boundary to keep CPU
   / battery sane on a phone running the gimbal at the same time.
   Implementation: read every datagram (you must, to keep the UDP
   buffer drained), but skip-the-decode for all but the most recent
   frame seen in a ~200 ms window. The fps target is a constant in
   the live-view code, easy to nudge upward (10 / 15 / 30) if the
   user wants smoother preview and the phone copes.

When the user toggles live-preview off:
1. App sends `cam.cgi?mode=stopstream`.
2. App closes the UDP socket.

**Camera tab not visible (user switched to pan/tilt/roll or logs).**
Keep the UDP socket open and the stream running on the camera side,
but **stop decoding incoming datagrams** — read-and-discard so the
OS UDP buffer stays drained. Resume decoding when the tab becomes
visible again. Avoids the cost of decoding frames nobody sees and
sidesteps stream renegotiation overhead on quick tab-switches.

### Camera tab — UI

Second tab in the Playground's `TabBar`, between `pan/tilt/roll` and
`logs`. Selecting the tab does **not** automatically connect — the
user explicitly taps Connect.

#### States

```
[ Disconnected ]
   |
   |  user taps Connect
   v
[ Discovering ]    ── status: "searching for camera…"
   |
   v
[ Registering ]    ── status: "registering with camera (confirm on body if prompted)…"
   |
   v
[ Loading caps  ]  ── status: "reading supported settings…"
   |
   v
[ Connected ]      ── controls visible
   |
   |  user taps Disconnect, leaves Playground, or transport error
   v
[ Disconnected ]
```

An error in any phase returns to Disconnected with the error text
visible above the Connect button.

#### Disconnected state

```
┌─ camera tab ────────────────────────────────────┐
│                                                  │
│   [  Connect to camera  ]                        │
│                                                  │
│   Status: Disconnected                           │
│   (or: error text from the last attempt)         │
│                                                  │
│   Make sure the camera is in WiFi → Smartphone   │
│   mode and your phone is joined to the LUMIX-…   │
│   network.                                       │
│                                                  │
│   ── if discovery fails ──────────────────────   │
│   Enter camera IP: [ 192.168.54.1   ] [Connect]  │
│                                                  │
└──────────────────────────────────────────────────┘
```

The "Enter camera IP" row is collapsed by default; it appears
inline when the first auto-discovery attempt times out, defaulted
to `192.168.54.1`. Manual-entered IPs are remembered only for the
current session (no persistence across launches).

#### Connected state

```
┌─ camera tab ────────────────────────────────────┐
│  Lumix S5  [▰▰▰▱▱]   [ Disconnect ]              │
│  ──────────────────────────────────────────────  │
│  ☐ Live preview                                  │
│  ┌────────────────────────────────────────────┐  │
│  │                                            │  │
│  │  [ live preview image — when toggled on ]  │  │
│  │                                            │  │
│  └────────────────────────────────────────────┘  │
│  ──────────────────────────────────────────────  │
│  Mode (from camera): [ P ] [ A ] [ S ] [ M ]     │
│  ──────────────────────────────────────────────  │
│  Shutter:  [ 1/125  ▼ ]                          │
│  ISO:      [ 400    ▼ ]                          │
│  Aperture: [ f/2.8  ▼ ]                          │
│                                                  │
│           [        Capture        ]              │
│                                                  │
└──────────────────────────────────────────────────┘
```

- **Live-preview checkbox** at the top of the connected view. Default
  **off** to avoid bandwidth surprises. Toggling on starts the UDP
  stream + opens the preview pane; toggling off stops the stream and
  collapses the pane. The checkbox is the only functional control in
  PR 4; everything below it (mode hint, shutter / ISO / aperture
  rows, Capture button) lands in PR 5.
- **Mode readout — `P / A / S / M`** (read-only). The camera's
  shooting mode *is* readable — `curmenu` reports it as
  `menu_item_id_recmode`'s `value` attribute, and a lighter
  `getsetting?type=recmode` path is to be confirmed (PR 7). The
  polling loop reads it and lights the matching chip; the segmented
  control is a **read-only display, not a selector** — the S5's mode
  dial is mechanical and exposes no setter. The mode drives the
  control-enablement matrix below. A camera mode outside `P/A/S/M`
  (intelligent-auto, video, a custom bank) lights no chip and leaves
  every control read-only. *(PR 5 shipped this as a manual,
  session-only hint; PR 7 turns it into the live readout.)*

  Mode → control enablement matrix (combines with the aperture
  sentinel below):

  | Mode | Shutter   | Aperture                  | ISO      | EV comp (PR 6) |
  |------|-----------|---------------------------|----------|----------------|
  | P    | read-only | read-only                 | editable | editable       |
  | A    | read-only | editable (sentinel-aware) | editable | editable       |
  | S    | editable  | read-only                 | editable | editable       |
  | M    | editable  | editable (sentinel-aware) | editable | read-only      |

  **Bench finding (Pre-PR 5):** the camera does *not* enforce this
  matrix — `setsetting` for shutter or aperture returns `ok`
  regardless of the dial position. The matrix is therefore a pure
  client-side UX convention (grey-out for the user's benefit); the
  body pushes back only via `err_*` on individual values it can't
  honour.

  P and S are not exercised by the panorama workflow (only A and M
  are). The matrix entries for P/S are best-effort; if real-world
  use surfaces issues, refine at that point. No UI banner about this
  — the user discovers if needed.
- **Shutter and ISO dropdowns.** ISO populates from
  `getinfo?type=allmenu` at connect time (~37 deduped entries on the
  S5D, including `auto`). Stills shutter populates from a hardcoded
  19-entry list (per PR 3's "as built" finding — `allmenu` does not
  enumerate stills shutter; only the video `shtrspeed_angle` form is
  there). Selecting a value fires the matching `setsetting`.

  **On success** (`<result>ok</result>` or the CSV `ok_*` variant
  from PR 3's findings): dropdown shows the new value.

  **On failure** (HTTP error or `<result>err_*</result>` — e.g. the
  camera rejecting a shutter value not legal in the current mode):
  the dropdown **reverts to the last-known-good polled value** and a
  transient red message appears below it for ~3 s before fading
  ("Camera rejected: <value>"). The user doesn't lose their place
  in the list.

  **Dropdown ↔ polling race.** While a dropdown is open, the
  background polling loop continues to fetch values but **does not
  update the open dropdown's selection** — the user's pending pick
  wins. On dropdown close (with or without a pick), polling state
  applies again. Rationale: concurrent edits on the body and the
  app are rare; the user has the app in front of them and their
  input takes precedence.
- **Aperture row.** Behavior depends on what `getsetting?type=focal`
  reports on the most recent poll:
  - **Real value** (e.g. `512/256` = f/2.0, with a native L-mount
    lens like the 24 mm framing lens): rendered as a dropdown.
    Editable when the current mode hint allows (A or M); read-only
    otherwise. Setter:
    `cam.cgi?mode=setsetting&type=focal&value=<numerator>/256`.
    Same encoding as the reader.
  - **Sentinel `32767/256`** (no electronic aperture — e.g. the
    vintage 90 mm Perigraphe panorama capture lens, or no lens
    mounted): the row flips to a read-only line **"No electronic
    aperture — set on lens"** with no current f-stop shown. The
    control re-enables automatically on the next poll if a real
    value appears (e.g. the user swaps lenses mid-session).
- **Capture button** issues `camcmd?value=capture`. The button uses
  **optimistic disable**: the moment the tap is dispatched, the
  button shows a spinner and goes disabled, so a double-tap can't
  fire a second capture before the camera's busy state appears in
  polling. The button re-enables when either (a) polling reports
  `busy → idle`, or (b) a generous timeout elapses, computed as
  follows from the *displayed label* of the currently-selected
  shutter dropdown:

  | Label form           | Timeout                       |
  |---|---|
  | `"B"` or `"Bulb"`    | static **60 s**                |
  | `"1/<N>"`            | `10 s + 1/N s` (i.e. ~10 s)    |
  | `"<N>"` or `"<N>s"`  | `10 s + N s` (e.g. 30 s → 40 s)|
  | Anything else        | fall back to 60 s              |

  **If the timeout fires before `busy → idle` is seen**, the button
  re-enables and a transient inline message appears below it —
  *"Capture may not have completed — check camera."* The user isn't
  left staring at a frozen spinner. No bulb / long-press behaviour
  in Phase 2 — Capture is a single tap. A self-timer delay is
  added in PR 6.
- **Disconnect button** in the tab header (not the screen-level
  sticky `ConnectionSummary`, which stays gimbal-specific) follows a
  best-effort release sequence: if a live-view stream is active, send
  `cam.cgi?mode=stopstream` first; then send
  `cam.cgi?mode=camcmd&value=playmode` to switch the camera out of
  remote-record mode (this releases the on-body "remote control"
  indicator); finally close the HTTP client. The protocol has no
  explicit deauth — the steps above are what other community clients
  do as a "polite goodbye". The same sequence runs when the user
  leaves the Playground screen entirely (back button).

#### Polling cadence while connected

A single 1 Hz polling loop runs while connected:

- `cam.cgi?mode=getstate` — battery, record/playback state, and the
  `<sd_access>` flag (`on` during the card write, `off` when idle — a
  Pre-PR 5 bench finding; this is what re-enables the Capture button
  after a shot).
- `cam.cgi?mode=getsetting&type=shtrspeed` — picks up shutter changes
  made on the camera body (e.g., user spins the wheel).
- `cam.cgi?mode=getsetting&type=iso` — same.
- `cam.cgi?mode=getsetting&type=focal` — picks up aperture-ring
  changes.

1 Hz is enough for the user-perceived UI (~1 s lag on body-side
changes is acceptable). If polling fails three consecutive times the
connection is treated as lost and the tab returns to Disconnected.

#### WiFi drop / reconnection

If the connection drops mid-session (polling failures, capture
returns a network error, etc.) the tab returns to Disconnected with
an error message. **No automatic reconnect attempts** in Phase 2 —
the user taps Connect again to retry. Matches the gimbal-side
behaviour.

### Architecture sketch (delta)

```
lib/
├── ble/                                # unchanged
├── camera/                             # NEW
│   ├── lumix_protocol.dart             # URL builders, shutter encoding,
│   │                                   # XML response parsers
│   ├── lumix_camera.dart               # HTTP client + SSDP discovery
│   ├── mjpeg_udp_stream.dart           # UDP receiver, frame-header
│   │                                   # parser, JPEG payload extractor
│   └── camera_connection.dart          # state machine (ChangeNotifier,
│                                       # Riverpod-exposed)
├── state/
│   └── gimbal_connection.dart          # unchanged
└── ui/
    └── tabs/
        ├── controls_tab.dart           # unchanged
        ├── logs_tab.dart               # unchanged
        └── camera_tab.dart             # NEW
```

`pubspec.yaml` additions (expected — exact versions decided during
implementation):

- `http` — for `cam.cgi` HTTP GETs.
- `xml` — for parsing the XML responses (`getinfo`, `getstate`,
  `getsetting`).
- Built-in `dart:io` `RawDatagramSocket` covers UDP and SSDP — no
  extra package needed for either.

No abstract `CameraTransport` interface in Phase 2 — we ship one
concrete implementation against the real camera. The same
transport-layer split we did for the gimbal will be introduced later
**if and when** a demo camera is added (the demo was explicitly
postponed; see Phase 2 out-of-scope below).

### Risks & open questions

- **Bluetooth pre-pair requirement on newer firmware.** Recent S5
  firmwares may require LUMIX Sync's BT pairing before the WiFi
  Smartphone mode unlocks. The fix is a one-time pairing in LUMIX
  Sync; out of scope to automate. The connect screen should surface
  a hint when discovery times out.
- **One-controller-at-a-time.** The camera locks remote control to
  the most recent `accctrl` device-name. If LUMIX Sync grabbed it
  last, our `accctrl` will steal control — fine for now, but worth
  noting in the UI (no recovery flow yet).
- **Shutter-speed encoding edge cases.** Community sources disagree
  on long-exposure encoding (`16384/256` vs `-1365/256` for ~30 s).
  Mitigated by sourcing the actual list from
  `getinfo?type=allmenu` at runtime rather than hardcoding.
- **MJPEG decode performance.** 30 fps × 640 × 480 JPEG decoding on
  the UI isolate could jank Flutter. Mitigation: decode in an
  `Isolate.run` per frame, capped at 5 fps by default (drop the rest
  at the receive boundary). Profile on the real phone before lifting
  the cap.
- **Android "no internet" prompt.** When the phone is on the camera's
  AP, Android may show a notification offering to leave the network.
  No app-side fix; the user must say "stay connected" (one-time).
- **Bandwidth in scan / playback / record.** While the camera is on
  its own AP, the phone has no internet — calls / messages may queue.
  Inherent to camera-AP mode; documented in the README rather than
  worked around.
- **Android: `CHANGE_WIFI_MULTICAST_STATE` + runtime
  `MulticastLock`.** SSDP relies on multicast; without the
  permission declared in `AndroidManifest.xml` AND a `MulticastLock`
  acquired on the WiFi manager at runtime, M-SEARCH responses won't
  reach our process. Easy to miss; PR 3 must include both. The
  manual-IP fallback works without these (it's plain TCP/HTTP), so
  shipping is possible even if multicast turns out to be a fight.
- **Android: WiFi-vs-cellular routing.** On Android 10+, if the
  phone has cellular *and* the camera's AP attached simultaneously,
  the OS may route `http://192.168.54.1/` over cellular by default
  — failing immediately, or burning mobile data on Panasonic-shaped
  XML that goes nowhere. Mitigation: bind the camera HTTP client's
  sockets to the WiFi `Network` explicitly via
  `ConnectivityManager.bindProcessToNetwork(...)` or by issuing a
  `NetworkRequest` for `TRANSPORT_WIFI` and using its returned
  `Network` to open sockets. This is a real implementation cost in
  PR 3 — the "hope the IP is non-routable" path mostly works but
  not reliably, and using paid cellular data is unacceptable.

### Verification checkpoints (Phase 2)

- [ ] On the camera tab, the Connect button is visible when no camera
      is connected; the panel above shows a "Disconnected" status with
      no error.
- [ ] Tapping Connect cycles through the documented states
      (Discovering → Registering → Loading caps → Connected) with
      visible status updates.
- [ ] First-time connect prompts the user on the camera body to
      accept; once accepted, subsequent connects from the same
      device-name pass through without a prompt.
- [ ] ISO dropdown populates from the camera (`getinfo?type=allmenu`,
      ~37 entries on the S5D including `auto`); shutter dropdown
      populates from the hardcoded 19-entry stills list (allmenu
      does not expose stills shutter — confirmed in PR 3).
- [ ] Mode-hint selector visible; on first connect, all of shutter
      / ISO / aperture are read-only until the user taps one of P /
      A / S / M. Resets to "no selection" on reconnect.
- [ ] With mode hint = **A**: shutter dropdown is read-only;
      aperture editable (subject to sentinel); ISO editable.
- [ ] With mode hint = **M**: shutter and aperture both editable
      (aperture subject to sentinel); ISO editable.
- [ ] Selecting a new shutter value: the camera body's display
      updates to match within ~1 s.
- [ ] Selecting a new ISO value: same.
- [ ] Selecting a new aperture value with a native L-mount lens
      mounted: body's display updates within ~1 s.
- [ ] Setting a value the camera rejects (`err_*` response): the
      dropdown reverts to the last-known-good value and a transient
      red inline message appears for ~3 s.
- [ ] Aperture sentinel: with a manual-aperture (vintage) lens
      mounted, the aperture row reads "No electronic aperture — set
      on lens" and is non-interactive. Swapping to a native lens
      restores the dropdown on the next poll.
- [ ] Aperture readout updates within ~1 s when the user rotates
      the lens ring on a native L-mount lens.
- [ ] Tapping Capture fires the shutter (audible click on the camera
      body, or recorded image visible in playback).
- [ ] Stuck-capture: if `busy → idle` is not observed within the
      computed timeout, the Capture button re-enables and shows
      "Capture may not have completed — check camera" inline.
- [ ] Toggling Live preview on: the preview pane appears and shows a
      moving frame from the camera within ~2 s of toggling.
- [ ] Toggling Live preview off: stream stops, preview pane
      collapses; the camera body's live-view indicator goes idle.
- [ ] Disconnect (or leaving the Playground): the camera body
      releases remote-control mode (its screen returns to the
      "waiting for connection" view).
- [ ] Connecting the gimbal (real or demo) and the camera at the same
      time: both work independently; gimbal motion has no effect on
      camera state and vice versa.

### Test strategy

Most of Phase 2 is testable without a camera:

- **Shutter-speed encoding round-trip** — pure function on
  `<numerator>/256` strings → seconds → labels and back. Pin known
  values from the libgphoto2 reference table.
- **XML response parsers** — `getstate`, `getsetting/{shtrspeed,iso,
  focal}`, `getinfo?type=allmenu`. Test against XML fixtures
  captured from the real S5 (one-time curl session) and committed
  under `test/fixtures/lumix/`.
- **MJPEG frame-header parser** — extract JPEG payload from the
  Panasonic UDP wrapper. Test against a binary fixture of one or
  two captured datagrams (committed under `test/fixtures/lumix/`).
- **State-machine transitions** — `CameraConnection` driven by a
  mocked HTTP client returning canned responses for each endpoint;
  `fake_async` to drive the 1 Hz polling cadence deterministically.
- **JPEG decoder isolate round-trip** — JPEG bytes in → `ui.Image`
  out. Validates the decode pipeline without the network.

What **can't** be tested without hardware: SSDP discovery (multicast
behaviour), `accctrl` handshake (camera-side prompt), capture timing,
live-preview end-to-end latency, WiFi-binding actually selecting
the camera network on a phone with cellular.

### Implementation steps (later)

Four sequential PRs, each independently shippable and on-hardware
verifiable. Sized for bisectability: PR 3 ~600–800 lines (shipped),
PR 4 ~500 (live preview + decoder), PR 5 ~500 (controls + polling +
mode hint + aperture sentinel), PR 6 ~250 (EV compensation +
self-timer delay).

The original ordering had PR 4 = controls and PR 5 = live preview;
they were swapped during specification so the first post-PR-3
milestone is "see something move" rather than "operate dropdowns".
Both PRs depend on PR 3 only — there is no dependency between
them in either direction, so the swap is free.

#### Pre-PR 3 — Capture real-S5 fixtures (one-time bench step)

> **Superseded (post-PR-4).** The curl-from-a-workstation recipe
> below is blocked by the hardened-firmware auth wall (see *Phase 2
> — known limitation*): only a phone carrying LUMIX Sync's BT-pair
> context reaches the camera. A partial, **playback-mode** fixture
> set was captured anyway (committed under `test/fixtures/lumix/`);
> the complete rec-mode set is captured by the in-app diagnostics
> wizard instead — see *Pre-PR 5* below. The recipe is kept for
> reference and for any future non-hardened body.

Before any code is written, capture XML responses from the actual
camera so the parsers in PR 3 have realistic inputs to test against.
~30 min on the bench. With the S5 on its own AP and a workstation (or
the dev phone via a tool like Termux / HTTP Shortcuts) joined to the
camera's WiFi:

```bash
# Register, accept on the camera body, then claim record mode.
curl 'http://192.168.54.1/cam.cgi?mode=accctrl&type=req_acc&value=4D454900-1C3C-C912-CE00-FEE1FACE0001&value2=Sciens'
curl 'http://192.168.54.1/cam.cgi?mode=camcmd&value=recmode'

# Capture fixtures.
mkdir -p sciens_gimbal_controller/test/fixtures/lumix
cd sciens_gimbal_controller/test/fixtures/lumix
curl 'http://192.168.54.1/cam.cgi?mode=getstate'                  > getstate.xml
curl 'http://192.168.54.1/cam.cgi?mode=getsetting&type=shtrspeed' > getsetting_shtrspeed.xml
curl 'http://192.168.54.1/cam.cgi?mode=getsetting&type=iso'       > getsetting_iso.xml
curl 'http://192.168.54.1/cam.cgi?mode=getsetting&type=focal'     > getsetting_focal.xml
curl 'http://192.168.54.1/cam.cgi?mode=getinfo&type=allmenu'      > getinfo_allmenu.xml

# Also capture the UPnP device descriptor for SSDP-recognition testing.
# (LOCATION URL discovered from an SSDP M-SEARCH probe; usually port 60606.)
curl 'http://192.168.54.1:60606/Server0/ddd' > upnp_device_descriptor.xml

# Polite goodbye (optional for fixture capture, mandatory for the app).
curl 'http://192.168.54.1/cam.cgi?mode=camcmd&value=playmode'
```

The fixture files commit into git as part of PR 3.

For PR 4 (live preview) we'll additionally need a handful of **raw
MJPEG datagrams** captured with e.g. `tcpdump -i wlan0 -s 65535
-w mjpeg.pcap udp port 49199` while the stream is active; extract a
few representative datagrams to `test/fixtures/lumix/mjpeg_frame_*.bin`.
Can be done at fixture-capture time or deferred to the start of PR 4.

#### PR 3 — Camera tab skeleton + connect lifecycle

**Scope.** Reach Connected against the real S5; no usable controls
yet.

Files added:
- `lib/camera/lumix_protocol.dart` — URL builders, shutter-speed
  encode/decode, XML response parsers, App-identity constants
  (UUID + display name).
- `lib/camera/lumix_camera.dart` — HTTP client + serial-request
  FIFO queue + SSDP discovery + manual-IP probe + the polite-goodbye
  disconnect sequence (`stopstream` if streaming → `camcmd&value=playmode`
  → close).
- `lib/camera/camera_connection.dart` — state machine
  (`ChangeNotifier` + Riverpod provider), connect / disconnect
  orchestration, capability cache.
- `lib/ui/tabs/camera_tab.dart` — Disconnected (with manual-IP
  fallback row), Connecting / Registering / Loading-caps statuses,
  Connected placeholder.
- `android/app/src/main/java/at/sciens/gimbal_controller/WifiNetworkChannel.java`
  — Java class exposing two methods over Flutter's `MethodChannel`
  named **`at.sciens.gimbal_controller/wifi_network`**:

  - `bind()` —
    1. Acquires a `WifiManager.MulticastLock` so SSDP M-SEARCH
       replies reach our process,
    2. Issues a `NetworkRequest` for `TRANSPORT_WIFI`, awaits the
       `Network` callback,
    3. Calls `ConnectivityManager.bindProcessToNetwork(network)` so
       every subsequent socket in our process routes over the
       camera's WiFi (not cellular).
    Replies via `MethodChannel.Result.success(null)` on availability,
    `error("unavailable", …)` on `NetworkCallback.onUnavailable()`.

  - `unbind()` — performs three things, in order, and is
    idempotent:
    1. `cm.bindProcessToNetwork(null)` — restore default OS routing.
    2. `cm.unregisterNetworkCallback(networkCallback)` — release the
       WiFi listener (otherwise it leaks across connect/disconnect
       cycles and accumulates).
    3. `multicastLock.release()` if held.

  Callbacks fire on a background thread; `Result.success/error`
  calls are marshaled to the main thread via
  `new Handler(Looper.getMainLooper()).post(...)`.

  Wired up by `MainActivity.java` overriding `configureFlutterEngine`:

  ```java
  @Override
  public void configureFlutterEngine(@NonNull FlutterEngine engine) {
      super.configureFlutterEngine(engine);
      new WifiNetworkChannel(this).register(engine);
  }
  ```

  `LumixCamera.connect()` invokes `bind()` before its first socket
  op; `disconnect()` invokes `unbind()`. Without this binding the
  OS may route `192.168.54.1` over cellular (and burn paid data) or
  drop the SSDP multicast replies entirely.

**Project language: full Kotlin → Java migration.** Phase 0
scaffolding put `MainActivity.kt` and the `android/app/src/main/kotlin/`
source set in place. PR 3 migrates the Android-side source language
to Java end-to-end (decision per Phase 2 spec author preference). The
mechanics:
- Create `android/app/src/main/java/at/sciens/gimbal_controller/MainActivity.java`
  as a one-line translation of the existing Kotlin
  (`public class MainActivity extends FlutterActivity {}`).
- Delete `android/app/src/main/kotlin/` (the old Kotlin source set)
  after the Java equivalent compiles.
- Edit `android/app/build.gradle.kts`:
  - Remove `id("kotlin-android")` from `plugins { }`.
  - Remove the `kotlinOptions { jvmTarget = ... }` block.
  - (The `build.gradle.kts` file itself stays in Kotlin DSL — that's
    the Gradle build script language and is separate from the app's
    source language. No need to convert to Groovy.)
- The Kotlin runtime still appears in the APK as a *transitive*
  dependency of `flutter_blue_plus` (and possibly others). Migration
  doesn't shrink APK size — it removes the "two languages to read"
  tax from our own code.

Edits:
- `lib/ui/playground_screen.dart` — third `TabBar` entry placed
  between `pan/tilt/roll` and `logs`, `TabController(length: 3)`.
  PopScope disconnects camera alongside gimbal on Playground exit.
- `android/app/src/main/AndroidManifest.xml` — add `INTERNET`,
  `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`,
  `CHANGE_NETWORK_STATE` permissions if not already present.
- `android/app/build.gradle.kts` — Kotlin plugin / kotlinOptions
  removal (see "Project language" note above).

Tests:
- `test/lumix_protocol_test.dart` — shutter encoding round-trip;
  XML parsing of captured `getstate` / `getsetting` / UPnP descriptor
  fixtures; SSDP descriptor-recognition rule
  (`<manufacturer>Panasonic</manufacturer>` + `<modelName>` prefix).

Verifies on hardware:
- Tap Connect → SSDP fires or the 192.168.54.1 probe wins →
  Registering shown → first-time prompt appears on camera body →
  user taps Accept → app shows Connected → user taps Disconnect →
  camera body returns to "waiting for connection".
- Repeat on a phone with cellular concurrently active: no traffic
  on the cellular leg (confirms WiFi binding).
- Re-Connect after the first successful connect: no body-side prompt
  this time (camera remembers the UUID).
- **Regression check (Kotlin → Java migration):** real-gimbal
  Phase 0 / Phase 1 behaviour is unaffected. Connect to the SCORP C2
  via the existing flow, run pan / tilt / Level — same accuracy and
  timing as before PR 3. The demo gimbal also still works (tap
  "Demo Gimbal", verify pan / tilt / Level and the 3D visualization
  unchanged). The migration touches `MainActivity` and
  `build.gradle.kts` only; nothing in the BLE path should regress,
  but the check catches accidental coupling (e.g., a Flutter plugin
  initialization that depended on the old Kotlin MainActivity).

#### PR 4 — Live preview

**Scope.** MJPEG-over-UDP end-to-end. The camera tab gains a
live-preview toggle and pane; everything else on the tab stays as
the PR 3 Connected placeholder. No polling, no controls, no mode
logic in this PR — the goal is "see something move" as a fast,
satisfying milestone.

The Connected tab body stays deliberately sparse in PR 4: header +
Disconnect + live-preview checkbox + preview pane (when toggled
on). No "controls coming soon" placeholder.

Connection-health detection (poll-fail-3 → Disconnected) lands in
PR 5 with the polling loop. In PR 4, if WiFi drops while a stream
is active the preview pane freezes on the last decoded frame; the
user must tap Disconnect manually. Acceptable for this intermediate
milestone.

Files added:
- `lib/camera/mjpeg_udp_stream.dart` — UDP receiver, Panasonic
  frame-header parser (BE-16 at offset 30, +32 → JPEG SOI), JPEG
  payload extractor, drop-rate-limit to ~5 fps default.
- `lib/camera/jpeg_decoder_isolate.dart` — `Isolate.run`-based
  JPEG → `ui.Image` decoder; long-lived isolate if profiling shows
  per-decode spawn overhead matters.

Edits:
- `lib/ui/tabs/camera_tab.dart` — Live-preview checkbox (default
  **off**) + collapsible preview pane below it;
  pause-decode-when-tab-hidden hook via `TickerMode.of(context)` or
  a `VisibilityDetector`.
- `lib/camera/camera_connection.dart` — `startStream(udpPort)` /
  `stopStream()` exposed on the connection; wired to the checkbox.

Tests:
- `test/mjpeg_frame_test.dart` — frame-header parser against a
  captured datagram fixture (one binary file with a few real
  frames committed under `test/fixtures/lumix/`).
- `test/jpeg_decoder_test.dart` — round-trip a known JPEG through
  the isolate, verify dimensions / pixel values at a few points.

Verifies on hardware:
- Toggle on → preview pane shows moving frames within ~2 s.
- Toggle off → stream stops, camera body live-view indicator goes
  idle.
- Switching to another tab while streaming → decode pauses
  (no obvious CPU/battery hit), UDP socket stays open.
- Switching back → decode resumes within one or two frames.

#### Pre-PR 5 — In-app diagnostics wizard

**Why.** PR 5's controls need realistic *rec-mode* camera responses
to build and test against. The curl-based *Pre-PR 3* capture is dead
(auth wall), and every fixture captured so far is **playback-mode**
(`getstate` shows `<cammode>play</cammode>`, so `getsetting?type=focal`
reads the `32767/256` sentinel, etc.). The phone *can* reach the
camera, so the app captures the diagnostics itself and exposes them
over an in-app HTTP server for retrieval onto the dev machine. Built
**before PR 5** so the PR 5 design and test fixtures reference real
data.

Two PR 5 blockers were already resolved by inspecting the existing
allmenu fixture and need no capture: the **aperture value list**
(allmenu has no enumerable aperture — it is a
`func_type="sp_embeded_aperture"` special control, so PR 5 hardcodes
a standard f-stop list like the shutter list and relies on `err_*`
rejection for out-of-range stops); and the **shutter value-mismatch**
(PR 5 snaps a polled wire value to the nearest list entry). What
still needs real data:
- The `getstate` **busy/idle field** — which tag toggles during a
  capture/card-write (candidate: `<sd_access>`). Drives the Capture
  button's `busy → idle` re-enable.
- `setsetting` **round-trip** — whether the body echoes our exact
  `<n>/256` value on the next `getsetting` or a canonical one, plus
  the `setsetting` response shape.
- The exact `err_*` **string** an invalid `setsetting` returns.
- Whether **mode-dependent rejection** is real (does
  `setsetting?type=shtrspeed` `err_*` with the dial in A?) — the
  premise of the mode-enablement matrix.

**UI shape.** The Camera tab gains a two-entry `TabBar`
`[ Camera | Debug/Diagnostics ]`. No third tab level — a third
stacked `TabBar` costs too much vertical space on a phone; a future
second diagnostic tool would be a `SegmentedButton` instead. The
Debug/Diagnostics sub-tab hosts one `Stepper`-based wizard and is
visible in production (internal tool, no debug gate).

```
Playground
└─ TabBar: [ pan/tilt/roll | Camera | Logs ]
   └─ Camera
      └─ TabBar: [ Camera | Debug/Diagnostics ]
         ├─ Camera             — connect / preview / (PR 5) controls
         └─ Debug/Diagnostics  — Stepper wizard:
            1. Baseline capture    (passive batch, one tap)
            2. Busy field          (watch getstate + capture)
            3. setsetting round-trip
            4. Invalid set         (capture the err_* string)
            5. Mode rejection      (dial to A / S, guided)
            6. Shutter sweep       (set+read every shutter entry)
            7. Aperture sweep      (set+read every aperture entry)
            8. Review & export     (results + HTTP server)
```

**The wizard.** A linear `Stepper` with `currentStep` driven
manually; "Continue" is gated on the step's capture having run, and
steps tolerate failure (a diagnostic tool keeps partial results).
Steps 1–7 require `connected` + rec mode; step 8 works while
disconnected. Each step shows its instruction, a Run button, and the
raw result inline.

- **Step 2 is app-orchestrated**, not "press the body shutter": the
  app sets a multi-second shutter, starts a ~300 ms × ~15 s
  `getstate` watch, fires `camcmd?value=capture` at a known offset,
  then keeps watching. A fast shot's card-write completes well
  inside one 300 ms sample — only a timestamped capture against a
  wide busy window reliably catches the toggle. If the slow-shutter
  `setsetting` is rejected, the step falls back to instructing the
  user to set a slow shutter on the body.
- **Step 5** trusts the user for the dial position — the protocol
  exposes no dial-position reader (confirmed in PR 3).

**Keep-alive caveat.** PR 5's polling loop does not exist yet and
PR 4's keep-alive runs only during live preview, so a user reading a
wizard step for >~10 s would let the Lumix session time out. The
diagnostics tool therefore runs its own **1 Hz `getstate`
keep-alive while a wizard run is in progress** — a wizard-scoped
mini version of what PR 5's polling loop later generalises (just as
PR 4's `_previewKeepAlive` is generalised). Live preview should be
**off** during a wizard run for clean `getstate` readings; the
wizard stops it at the start of a run.

**Retrieval — in-app HTTP server.** No cable. Captured snapshots are
**transient and in-memory** — no file persistence, they are
throwaway. A `dart:io` `HttpServer` on `0.0.0.0:8080` serves `GET /`
(index), `GET /<name>` (one raw response), and `GET /all.json`
(everything: name / URL / timestamp / body). Lifecycle is an
explicit **Start/Stop** toggle, *not* auto-start: the server must
bind *after* the phone leaves the camera AP and joins the dev WLAN
(while connected the process is bound to the camera AP via
`WifiNetworkChannel`; a socket bound before the network change may
not survive it). The sub-tab shows the phone's current WLAN IP and
port, refreshed when the server starts; a bind failure (port in use)
surfaces in the UI with a retry.

**Discovery — mDNS / DNS-SD.** So the dev machine needn't be told the
phone's DHCP IP each session, the app advertises the running HTTP
server as an mDNS service. Native side: Android
`NsdManager.registerService` with an `NsdServiceInfo` of type
`_http._tcp`, instance name `sciens-diag`, port 8080 — driven from
Dart through a Java platform channel in the existing
`WifiNetworkChannel` pattern. Register on server **Start** (after
`HttpServer.bind` succeeds), unregister on **Stop**, so the advert
exists only while there is something to serve and only on the
network the phone is then joined to (the dev WLAN). The dev machine
finds it with `avahi-browse -rt _http._tcp` (or any DNS-SD browser),
yielding the current `IP:8080` with no manual transcription. Caveat:
`NsdManager` advertises the *service*; the SRV target is the
device's system-assigned `.local` hostname, not an arbitrary
`sciens-diag.local` — a directly bookmarkable hostname would need a
host-record responder (jmDNS-class) and is out of scope. The
on-screen IP display stays as the always-available fallback.

Files added:
- `lib/camera/camera_diagnostics.dart` — `ChangeNotifier` + Riverpod
  provider: in-memory snapshot store, the capture / watch routines,
  the wizard-scoped keep-alive, the `HttpServer`, and the mDNS
  register / unregister calls.
- `lib/ui/tabs/camera_diagnostics_view.dart` — the `Stepper` wizard
  + review/export UI.
- `android/app/src/main/java/at/sciens/gimbal_controller/NsdChannel.java`
  — Java platform channel wrapping `NsdManager.registerService` /
  `unregisterService`; `RegistrationListener` callbacks marshalled to
  the main thread, as `WifiNetworkChannel` already does.

Edits:
- `lib/ui/tabs/camera_tab.dart` — wrap the existing body in a
  `[ Camera | Debug/Diagnostics ]` `TabBar`; the status-switch UI
  moves into the Camera sub-tab with `AutomaticKeepAliveClientMixin`
  preserved, so the live-preview toggle (and PR 5's mode hint)
  survive sub-tab switches.
- `lib/camera/lumix_camera.dart` — a generic
  `rawGet(Map<String,String> query)` that builds a `cam.cgi` URL and
  goes through the FIFO queue, so the wizard can probe endpoints
  (`curmenu`, lens info, …) the typed API doesn't cover.
- `lib/camera/camera_connection.dart` — expose a path for the
  diagnostics provider to issue requests on the live `LumixCamera`
  handle (`_camera` is otherwise private).
- `android/app/src/main/java/at/sciens/gimbal_controller/MainActivity.java`
  — register `NsdChannel` in `configureFlutterEngine`, alongside the
  existing `WifiNetworkChannel`.

Tests: bench tool, verified on-device, not unit-tested. The one
testable seam — `rawGet` URL building — folds into
`test/lumix_protocol_test.dart` if cheap.

Verifies on hardware:
- Mount the Lumix S 50 mm f/1.8 (AF L-mount — exercises the real
  electronic-aperture path). Connect, open Debug/Diagnostics, run the
  wizard end to end; each step shows a result.
- Step 2's watch series contains a tag that flips while the capture
  fires.
- Disconnect, join the dev-machine WLAN, Start server. From the dev
  machine, `avahi-browse -rt _http._tcp` lists `sciens-diag` and
  resolves its `IP:8080`; download `all.json`. The on-screen IP
  works as a fallback.
- The captured rec-mode responses augment the playback-mode fixtures
  under `test/fixtures/lumix/`.

After this step, fold the findings into the PR 5 sections and add a
*Pre-PR 5 — as built* note, then proceed to PR 5.

#### Pre-PR 5 — as built

Shipped and verified on the S5D with a Lumix S 50 mm f/1.8. Files as
planned — `camera_diagnostics.dart`, `camera_diagnostics_view.dart`,
`NsdChannel.java` — plus `urlRaw` / `rawGet` / `diagnosticRawGet`, the
nested `[ Camera | Debug/Diagnostics ]` sub-tabs, and the
`MainActivity` wiring.

Deviations from the plan:
- **HTTP server: port range + defensive unbind.** The first bench run
  hit `SocketException … "Machine is not on the network" (ENONET)`:
  the process stays pinned to the camera's WiFi
  (`bindProcessToNetwork`) until something unbinds it. The server now
  (a) calls `WifiNetworkChannel.unbind()` unconditionally before
  binding — idempotent, and by export time the capture phase is over
  — and (b) tries ports 8080–8089, using the first free one.
- **Keep-alive scope.** Tied to the diagnostics view's
  `initState`/`dispose` rather than literally "a wizard run in
  progress" — simpler, and it no-ops while disconnected anyway.

Bench findings (these feed PR 5):

- **Busy field = `<sd_access>`.** It flips `off`→`on` for the ~1.2 s
  card-write window after a capture, then back. `getstate` in rec
  mode is far richer than the playback-mode fixture — it also carries
  `<rec>` and `<remaincapacity>` (stills count, decremented per
  shot). At 1 Hz a ~1.2 s `sd_access` window is caught by 1–2 polls;
  the optimistic-disable timeout stays as the backstop.
- **Aperture is fully controllable.** With the AF lens,
  `getsetting?type=focal` returns a real value (`1024/256` = f/4) and
  `setsetting?type=focal` round-trips exactly. The `32767/256`
  sentinel in the old fixture was purely a *playback-mode* artifact.
- **`setsetting` echoes our exact wire value.** Shutter `1792/256`,
  ISO `400`, aperture `1024/256` each set→get returned verbatim — so
  PR 5's snap-to-nearest is needed only for values set on the *body*,
  never for app-set ones.
- **The mode matrix is not camera-enforced** — see the note under
  *Connected state → Mode hint*.
- **Error vocabulary:** `err_param` (malformed value or unknown
  type), `err_reject` (recognised but refused), `err_critical`
  (`getsetting?type=lens` — no such type; there is no lens-info
  endpoint). `isResultOk` already treats all three as failure.
- **The camera does not validate shutter values.**
  `setsetting?type=shtrspeed&value=99999/256` returned `ok`. An
  out-of-range shutter is silently swallowed — PR 5's
  revert-on-`err_*` UX will *not* fire for a bad shutter; only the
  next poll reveals what the body actually did.
- **Shutter list — verified** (shutter-sweep step 6; dial on M,
  mechanical shutter). All 19 `defaultShutterValues` entries are
  accepted; the `-512/256` `err_reject` from the first run was a
  transient mode/state artifact (the dial was not on M then), not a
  bad value. **Quirk:** the camera reports negative numerators as an
  unsigned int16 — set `-256/256` (2 s) and `getsetting` returns
  `65280/256` (= 65536 − 256); likewise `-512/256`→`65024/256`, …,
  `-1280/256`→`64256/256`. The signed and unsigned strings are the
  same 16-bit pattern. **PR 5 must fix `shutterWireToSeconds`** to
  read the numerator as int16 (`if (n > 32767) n -= 65536`) —
  otherwise a slow shutter polled back from the body decodes to ~0 s.
  Positive values and `0/256` / `256/256` (Bulb) round-trip verbatim.
- **Aperture list — verified** (aperture-sweep step 7; 50 mm f/1.8,
  dial on A). `allmenu`/`curmenu` carry no aperture list, so PR 5
  hardcodes `defaultApertureValues` (1/3-stop f/1.4–f/22). The sweep
  confirms it: all 25 entries accepted (`ok`, zero `err_*`); f/2.0–
  f/22 round-trip verbatim — the 1/3-stop encoding works. Anything
  wider than the lens maximum is **clamped, not rejected** — f/1.4 /
  f/1.6 / f/1.8 all read back as `428/256` (the 50 mm's true f/1.8).
  So, like shutter, the camera is permissive: PR 5's revert-on-`err_*`
  UX never fires for aperture, and the dropdown snaps the polled
  (possibly clamped) value to the nearest list entry.

Captured data lives at the repo root — `diagnostics_all.json`
(steps 1–5), `diagnostics_sweep.json` (shutter sweep),
`diagnostics_apsweep.json` (aperture sweep). Their rec-mode XML
responses can replace the playback-mode fixtures under
`test/fixtures/lumix/` when PR 5 wants real test inputs.

#### PR 5 — Controls, capture, polling, mode hint

**Scope.** Make the Connected state fully functional (minus EV
compensation and self-timer, which go to PR 6).

Edits:
- `lib/ui/tabs/camera_tab.dart` —
  - **Mode-hint segmented selector** (`P / A / S / M`), pure
    client-side; no default selection on connect; session-only
    state.
  - **Shutter / ISO dropdowns** — ISO from cached
    `getinfo?type=allmenu`, shutter from the hardcoded 19-entry
    stills list. Gated read-only/editable by the mode hint per
    the enablement matrix in *Connected state*.
  - **Aperture dropdown** when `getsetting?type=focal` reports a
    real value; flips to read-only **"No electronic aperture —
    set on lens"** line when the `32767/256` sentinel is
    observed. Re-enables on next poll if a real value reappears.
  - **`setsetting` failure UX** — on HTTP error or
    `<result>err_*</result>`, the dropdown reverts to the
    last-known-good polled value and shows a transient red
    inline message ("Camera rejected: <value>") for ~3 s.
  - **Capture button** with optimistic disable; on timeout
    without `busy → idle`, re-enable + inline "Capture may not
    have completed — check camera" message.
  - **Dropdown ↔ polling race** — while a dropdown is open,
    poll-driven value updates are suppressed; the user's pending
    pick wins. Polling state applies again on close.
- `lib/camera/camera_connection.dart` — 1 Hz polling loop (single
  `getstate` + 3× `getsetting` for `shtrspeed` / `iso` / `focal`),
  `setSetting` for shutter / ISO / aperture, `capture` with
  optimistic-disable timeout, polling-failure → Disconnected
  transition after 3 consecutive failures. The polite-goodbye
  sequence already lives in `lumix_camera.dart` from PR 3.

Tests:
- `test/camera_connection_test.dart` — state-machine transitions
  driven by a mocked HTTP client (canned `accctrl` / `recmode` /
  `getinfo` / `getsetting` / set / `capture` responses).
  `fake_async` for polling cadence. Cover: shutter / ISO /
  aperture set on success and on `err_*` (revert + inline error);
  aperture sentinel `32767/256` → row read-only; sentinel-clears
  → row editable again on next poll; Capture optimistic-disable +
  timeout fallback path; polling-failure → Disconnected after
  3 consecutive failures.

Verifies on hardware:
- With **no mode hint** selected: all of shutter / ISO / aperture
  dropdowns are read-only — visible but not interactive.
- With mode hint = **A**: shutter dropdown is greyed; setting
  aperture from the app updates the body within ~1 s; ISO setting
  works.
- With mode hint = **M**: shutter and aperture both editable;
  both update the body within ~1 s.
- Lens swap mid-session: with an e-aperture lens, the aperture
  dropdown is active; swap to a manual lens (or remove the lens),
  next poll surfaces the `32767/256` sentinel and the row
  collapses to the read-only "No electronic aperture — set on
  lens" line. Swap back: dropdown returns within ~1 s.
- Setting a value the camera rejects (`err_*`): the dropdown
  reverts to the last-known-good value and a transient red
  message appears below it.
- Rotating the lens ring on a native L-mount lens updates the
  aperture readout within ~1 s.
- Single Capture fires; the button stays disabled until busy →
  idle observed, or the `10 s + shutter` timeout elapses (in
  which case the "Capture may not have completed" inline message
  appears).
- Disconnect: camera body's "remote control" indicator goes idle;
  camera screen returns to "waiting for connection".

#### PR 5 — as built

Shipped: the Connected camera tab is fully functional — `P/A/S/M`
mode hint, shutter / ISO / aperture dropdowns, capture button, and a
1 Hz polling loop. Files: `camera_connection.dart` (polling loop,
`applySetting`, `capture`), `camera_tab.dart` (all the controls),
`lumix_protocol.dart` (decoder fix + snap helpers); new
`test/camera_connection_test.dart`.

Deviations from the plan:
- **Capture re-enable uses `<remaincapacity>`, not the `sd_access`
  busy→idle transition.** A fast shot's `sd_access=on` window
  (~1.2 s) can fall entirely between two 1 Hz polls, which would
  wrongly trigger the "may not have completed" timeout on the common
  case. `<remaincapacity>` decrements once per saved shot regardless
  of shutter speed, so it is always caught; the shutter-derived
  timeout remains the backstop.
- **The dropdown↔polling race uses a pending-value pattern**, not
  menu open/close detection — `DropdownButton` exposes no "menu
  closed" callback. The optimistic pick is held until polling
  confirms it (or a 3 s fallback elapses), which also makes the
  revert-on-error trivial.
- **Snap-to-nearest** (`nearestShutterWire` / `nearestApertureWire`):
  a polled value is matched to a dropdown entry by decoded duration /
  f-number, so the uint16 long-exposure form and any body-set or
  clamped value resolve cleanly.
- **PR 4's preview keep-alive and the diagnostics tool's keep-alive
  were both removed** — the always-on polling loop is the single
  session keep-alive whenever connected.
- The `setsetting` failure UX rarely fires in practice: the camera
  is permissive (it accepts or clamps rather than rejecting), so the
  revert + transient message mostly catches transport errors.

Test seam: `LumixCamera` takes an injectable `http.Client`, and
`CameraConnection` an injectable `LumixCamera` factory and
`pollInterval` — so `camera_connection_test.dart` drives the state
machine against a `MockClient` with no real I/O.

On-hardware verification: Steps 2–7 were each verified on the S5D as
they landed — preview keep-alive, the mode selector, the dropdowns
with mode gating, body-side change pickup, and capture for fast and
long exposures.

#### PR 6 — EV compensation + single-shot self-timer

**Scope.** Two small camera-tab additions on top of PR 5.

Edits:
- `lib/ui/tabs/camera_tab.dart` —
  - **EV compensation dropdown.** Sourced from `cmd_type="exposure"`
    in the cached `getinfo?type=allmenu` (~31 entries: −5 EV
    through +5 EV in 1/3-stop increments, values like `-14/3`,
    `0`, `+11/3`, `5`). Setter:
    `cam.cgi?mode=setsetting&type=exposure&value=<v>`. Editable in
    P / A / S; read-only in M (no auto-exposure offset when both
    shutter and aperture are user-set).
  - **Self-timer delay** — a small number input (default `0` s).
    When > 0, tapping Capture starts a countdown displayed inline
    next to the button; on countdown end, fires
    `camcmd?value=capture`. The button relabels to "Cancel"
    during the countdown — tapping it aborts the firing.
    Independent of any panorama-phase settle-delay (Phase 4 will
    have its own).
- `lib/camera/camera_connection.dart` — EV is applied through the
  existing `applySetting('exposure', …)`; and, unlike the original
  plan, the poll loop **does** read it (a 4th `getsetting` in the
  1 Hz cycle) so the dropdown tracks the body's EV dial.

Tests:
- `test/camera_connection_test.dart` extends — EV setter calls the
  correct URL; M mode disables the EV control.

Verifies on hardware:
- In A mode: changing EV from app updates body display within
  ~1 s and visibly affects metering.
- In M mode: EV control is read-only.
- Setting self-timer = 5 s, tapping Capture: countdown visible,
  shutter fires after 5 s. Tapping Cancel during countdown:
  no shot fires.

#### PR 6 — as built (EV compensation)

The EV-compensation half shipped; the single-shot self-timer is the
remaining PR 6 piece.

Deviations from the plan:
- **EV is polled.** The plan said the poll loop needn't read EV. It
  does — a 4th `getsetting` in the 1 Hz cycle — so the dropdown
  tracks EV dialled on the body, consistent with shutter / ISO /
  aperture.
- **No `setEvCompensation` helper** — EV is applied via the generic
  `applySetting('exposure', …)` and the row is a plain
  `_SettingDropdownRow` (pending-value + error UX reused).
- `parseAllMenu` was extended to also collect `cmd_type="exposure"`,
  sorted ascending; `evThirds` / `evLabel` / `nearestExposureWire`
  helpers added. Labels use the conventional 1/3-stop form
  ("−4⅔", "0", "+1⅓"). `nearestExposureWire` matches by EV value,
  so the integer and `n/3` wire forms resolve either way.

Verified on hardware: EV editable in P/A/S, read-only in M, and the
dropdown tracks the body's EV dial.

#### PR 7 — Mode readout + battery indicator

Two camera-tab refinements found after PR 5 shipped. Independent of
PR 6 — they can land in either order.

**Reading the mode.** The mode is available from `curmenu` as
`menu_item_id_recmode`'s `value` attribute (`program_ae` /
`aperture_ae` / `shutter_ae` / `manual_exposure` / `ia` /
`creative_movie` / `slow_quick` / `c1`…`c12`). A lighter
`getsetting?type=recmode` was probed on the bench and returned
`err_critical` (like `type=lens`) — there is no lightweight getter.
`curmenu` is ~45 KB, so it is read on a **slow cadence** — every
~5 s (every 5th poll cycle), not at 1 Hz — and only the
`menu_item_id_recmode` value is extracted from it.

**Mode readout.** The `P/A/S/M` segmented control becomes a
**read-only readout** — no longer tappable. The polling loop reads
the mode and lights the matching chip; a camera mode outside
`P/A/S/M` (IA / video / custom bank) lights no chip and leaves every
control read-only. The enablement matrix is now driven by the
camera's actual mode, not a manual guess. There is no mode *setter*
— the S5's dial is mechanical (confirmed). This replaces PR 5's
manual session-only hint.

**Battery indicator.** A Material battery icon in the Connected-view
header, beside the camera name, filled to the `<batt>` level —
`getstate` reports a **0–5 bar count**, and `<batt_per>` is always
`-1` over WiFi, so there is no true percentage. Colour by level:
**1/5 or lower → red, 2/5 → amber, 3/5 and up → default**. The value
is already parsed (`CameraState.battery`).

Edits: `lumix_protocol.dart` (recmode parse + `CameraMode` mapping,
`<batt>` level parse), `camera_connection.dart` (poll the mode),
`camera_tab.dart` (selector → readout, header battery icon),
`camera_diagnostics.dart` (the `recmode` probe in the baseline
batch).

Verifies on hardware:
- Turn the mode dial through P / A / S / M — the readout chip
  follows within ~5 s (the `curmenu` read cadence), and shutter /
  aperture editability changes with it.
- A non-P/A/S/M dial position (IA, a custom bank) lights no chip.
- The battery icon reflects the on-body bar level and goes red at
  the last bar.

#### PR 7 — as built

Shipped and verified on the S5D.

- **Mode readout.** `getsetting?type=recmode` was probed and returned
  `err_critical`, so the mode is read from `curmenu` instead — every
  5th poll cycle (~5 s), `parseRecmode` regex-extracts the
  `menu_item_id_recmode` value. The `P/A/S/M` control is now
  `_ModeReadout`, a read-only 4-chip row driven by `conn.recMode`
  via `cameraModeFromRecmode`; the manual selector and `_modeHint`
  state are gone. A non-P/A/S/M mode lights no chip and leaves the
  controls read-only.
- **Battery indicator.** A Material battery icon in the
  Connected-view header, filled to the `<batt>` bar level
  (`batteryBars`), coloured red ≤1/5 / amber 2/5 / default above.
  No percentage — `<batt_per>` is always `-1` over WiFi.

Verified on hardware: the readout chip follows the mode dial, and
shutter / aperture editability changes with it.

#### Sign-off

After PR 6 and PR 7 land and all on-hardware verification
checkpoints above pass, Phase 2 is complete. Move to Phase 3 (protocol library
extraction) or Phase 4 (panorama sequencer) — order optional.

### Out of scope (Phase 2)

- **Demo camera transport.** Explicitly postponed. If/when added, it
  will follow the same transport-interface pattern we used for the
  gimbal (`GimbalTransport` / `BleGimbalTransport` /
  `DemoGimbalTransport`), introducing a `CameraTransport` abstract
  interface at that time.
- Same-network mode (camera joins user's existing WiFi).
- Manual exposure mode switching (P/A/S/M selection — the dial on
  the camera body handles this).
- Video recording (`video_recstart` / `video_recstop`).
- Image transfer / browsing the SD card (the SOAP /
  ContentDirectory binding documented in `libgphoto2` is unused).
- Long-press capture / bulb timing UI. Capture is a single press;
  the camera handles its own bulb duration.
- Multi-camera support.
- Saving the last-connected camera across launches.
- iOS / desktop / web targets (still excluded).

### Phase 2 — as built (PR 3)

PR 3 shipped on hardware against a **Panasonic S5D, firmware VD4.30**.
Three protocol quirks required code beyond the original plan; four
schema findings came from the captured fixtures.

**Protocol quirks observed on hardware:**

1. **`accctrl` returns a CSV success response, not plain `ok` or XML.**
   The S5D body returns
   `ok_under_research_no_msg,S5D-FB94FA,remote_encrypted`. The first
   comma-separated field is the result code; anything starting with
   `ok` indicates success. `isResultOk` updated to accept the
   CSV-with-`ok_*`-prefix form in addition to bare `ok` and XML
   `<result>ok</result>`.

2. **Newer firmware needs the libgphoto2 prelude between `accctrl`
   and `recmode`.** As originally specced (`accctrl → recmode →
   getinfo`), the S5D returns `err_reject` at recmode. Adding
   `getstate` + `setsetting?type=device_name&value=Sciens` between
   the two — copying libgphoto2's sequence — unblocks recmode. The
   `setsetting` is wrapped in try/catch so older bodies that don't
   support `device_name` still progress. Reflected in the
   "Connect order" table above.

3. **Some endpoints return a malformed `Content-Type` header** —
   literally `xml` instead of `text/xml`. Dart's `http` package's
   `Response.body` getter throws `FormatException("invalid media
   type: expected '/'")` before we ever see the body. Mitigation:
   all response reads use `bodyBytes` + manual UTF-8 decode in a
   `_decodeBody` helper, bypassing the Content-Type sniffing.

**Schema findings from fixtures:**

4. **`getsetting?type=<T>` returns the value as an XML attribute on
   `<settingvalue>`, not as inner text.**

   ```xml
   <settingvalue shtrspeed="2048/256"></settingvalue>
   ```

   The original scaffold parsed inner text — wrong. Refined to read
   the attribute matching the requested type.

5. **`getsetting?type=focal` returns `32767/256` as a "no aperture
   data" sentinel** — observed when the camera is in playback mode
   or no lens is mounted. `32767` is `0x7FFF`, the int16 max ("no
   value" marker). The aperture decoder returns null on the
   sentinel rather than computing the absurd `pow(2, 32767/512)`.

6. **`getinfo?type=allmenu` enumerates ISO but NOT stills shutter
   speed.** 307 KB menu hierarchy; ISO appears as 44 `<item
   cmd_mode="setsetting" cmd_type="iso" cmd_value="…">` entries
   (with duplicates like `100` / `L100` that get deduped). Stills
   shutter is dynamic on the body — only `shtrspeed_angle` (video
   angle mode) is in allmenu. Worked around by shipping a hardcoded
   `defaultShutterValues` list — **19 entries**, wire values
   `3328/256` (≈1/8000 s) through `-1280/256` (≈30 s) plus the Bulb
   sentinel `256/256`. The camera will reject any value it doesn't
   actually support, with the error surfaced in the UI.

**Pre-PR 3 fixture capture:**

Committed under `test/fixtures/lumix/`:

- `getstate.xml`
- `getsetting_shtrspeed.xml`
- `getsetting_iso.xml`
- `getsetting_focal.xml`
- `getinfo_allmenu.xml` (307 KB)

The UPnP device descriptor was not captured — discovery succeeded
via the `192.168.54.1` probe path on this body, so the SSDP code
path is currently unexercised in tests. Capture if/when SSDP
becomes the active discovery winner.

**On-hardware verification status (PR 3):**

- ✓ Connect lifecycle reaches "Connected" end-to-end.
- ✓ Polite-goodbye disconnect runs (camera body returns to
  "waiting for connection").
- ✓ Capability cache populates: **19 shutter / 44 ISO** values on
  the S5D.
- ✓ Phase 0 / Phase 1 gimbal behaviour unaffected by the
  Kotlin → Java migration.

PR 4 and PR 5 remain TBD on hardware — live preview and controls +
capture + polling respectively (post-swap, see Implementation steps).

### Phase 2 — known limitation: hardened-firmware auth wall (discovered post-PR-3)

**Symptom.** On a re-test session after PR 3 shipped, the S5D body
running firmware `2.80` (per UPnP `<pana:X_FirmVersion>`) rejects
every state-changing `cam.cgi` call from the Linux bench:
`accctrl` returns the partial-success CSV
`ok_under_research_no_msg,S5D-FB94FA,remote,encrypted` (a slot is
reserved), but `getstate` / `setsetting` / `camcmd&value=recmode` /
`startstream` / `stopstream` all return `<result>err_reject</result>`.
Only the read-only `getinfo?type=allmenu` still works.

The `remote,encrypted` form is **two separate flags** (vs. the
`remote_encrypted` single-token form that liblumix's S5II target
produces). The `encrypted` flag signals that the camera expects an
authenticated session for any operational command.

**What we tried (probe scripts under `scripts/probe_lumix_auth*.py`):**

- All UDN/name encoding variants of liblumix's `req_acc_e` form
  (hex of camera UDN, lower/upper case, with/without hyphens, raw
  16-byte UUID form) → all return `err_param`. `req_acc_e` does not
  exist on this firmware.
- `req_acc_g` probe with and without params → `err_param`.
- `X-SESSION_ID`, `Cookie`, `Authorization: Bearer`, `X-Session`,
  `X-CAM-SESSION`, `X-PANA-SESSION-ID` headers on `getstate` → all
  `err_reject` regardless of value.
- Speculative `value3=clear`, `encryption=off`, `mode=getinfo&type=session`
  variants → no useful response.
- PTP/IP fallback port `15740` (from UPnP descriptor) is
  **TCP-refused** — not available as a fallback.
- Camera in playback mode (suggested by the PR-3-time
  `<cammode>play</cammode>` in `getstate.xml`) made no difference;
  same `err_reject` wall.

**Conclusion.** The auth shape is almost certainly the
**Bluetooth-LE-mediated handshake** that LUMIX Sync uses to
provision a shared secret before WiFi commands are accepted. We
can't reverse-engineer it without Wireshark captures of LUMIX
Sync's traffic.

**How PR 3 reached "Connected" in May 2026 despite this wall:**
unknown for sure. The fixture `getstate.xml` from that session
reports `<version>VD4.30</version>` (body firmware) — possibly the
body firmware updated itself silently over a paired session, or
some prior LUMIX-Sync BT pairing left transient state that the
PR-3 sequence rode on. Not reproducible from a cold Linux bench
today.

**Tracked as a separate task — "PR 3.5 — auth handshake for
hardened firmware"** (parked, no ETA). Attack plan when picked up:

1. Install LUMIX Sync on the dev Android phone (or an emulator).
2. Run a `tcpdump` capture on the workstation acting as a router
   between the phone's WiFi and the camera's AP, OR install a
   Wireshark TLS-key-logging proxy on the phone.
3. BT-pair the camera with LUMIX Sync, start a remote-control
   session, capture the first ~30 s of traffic on port 80.
4. Diff against our `cam.cgi?mode=accctrl…` sequence; identify
   the additional auth step (likely an extra `cam.cgi` mode or a
   custom HTTP header derived from the BT-shared secret).
5. Implement it in `LumixCamera` and re-test.

### Phase 2 — as built (PR 4)

Shipped: MJPEG-over-UDP live preview, ~5 fps default rate cap,
pause-decode-when-tab-hidden via `TickerMode`. Files added:

- `lib/camera/mjpeg_udp_stream.dart` — `extractJpegPayload` (pure
  function: reads BE-16 at offset 30, computes SOI = +32, validates
  SOI/EOI markers, returns a `Uint8List` view) and `MjpegUdpStream`
  (`RawDatagramSocket` + 200 ms emit gap). Always drains every
  datagram so the kernel UDP buffer doesn't back up; drops surplus
  before downstream decode.
- `lib/camera/jpeg_decoder.dart` — `decodeJpeg(Uint8List)` via
  `ui.instantiateImageCodec`. **No manual `Isolate.run`** despite
  the original spec wording: Flutter's image codec already
  dispatches the heavy work to a native worker thread, so the
  Dart main isolate isn't blocked; adding a Dart isolate would
  add per-frame spawn cost and force a pixel roundtrip (a
  `ui.Image` can't cross isolate boundaries). The filename in the
  spec was `jpeg_decoder_isolate.dart`; renamed to `jpeg_decoder.dart`
  to avoid lying.

Edits:

- `lib/camera/camera_connection.dart` — `startLivePreview()` /
  `stopLivePreview()` orchestrate the HTTP `startstream` →
  `MjpegUdpStream.open` → decoder pipeline. A `ValueListenable<ui.Image?>`
  (`previewImage`) lets the preview widget subscribe directly
  without rebuilding the whole tab at ~5 Hz. `setPreviewPaused(bool)`
  gates the decoder when the tab is hidden (datagrams keep
  draining; only decode is skipped). Also runs a **1 Hz `getstate`
  keep-alive** during preview — added after on-phone testing showed
  the preview freezing after ~10 s without it. Lumix bodies time
  out the session if no cam.cgi command is sent for ~10 s; liblumix's
  protocol notes call this out explicitly. PR 5's full polling loop
  will replace this single-call heartbeat with the same 1 Hz cadence
  carrying more reads.
- `lib/ui/tabs/camera_tab.dart` — `SwitchListTile` for live preview
  (default off), 4:3 `_PreviewPane` with `ValueListenableBuilder` +
  `RawImage`, error surfacing via `conn.previewError`, pause-decode
  via `TickerMode.valuesOf(context).enabled`. PR-3 placeholders
  ("Connected — controls land in PR 4" / "Capabilities cached")
  removed per the spec's "sparse tab" requirement.

Tests:

- `test/mjpeg_frame_test.dart` — 7 tests against synth fixtures
  (`mjpeg_frame_synth_01..03.bin`) + malformed inputs. Fixture 03
  in particular verifies the parser uses the length field, not
  a marker scan: its metadata block deliberately contains
  `FF D8` and `FF D9` decoys before the real JPEG.
- `test/jpeg_decoder_test.dart` — 2 tests. Round-trip decode of
  the fixture-embedded 64×48 JPEG, pixel-sample assertion on the
  two-tone red/blue pattern, and a malformed-input error case.

**Fixture is synthesized, not camera-captured.** Real-camera MJPEG
capture is blocked by the auth wall above. The Panasonic wire
format is fully documented in this spec, so the synth datagrams
(produced by `scripts/synth_mjpeg_fixture.py` from a Pillow-generated
JPEG) exercise the parser logic completely. A real-camera fixture
can replace the synth one when the auth wall is solved; the test
file paths and assertions stay the same.

**On-hardware verification status (PR 4): ✓ verified on Android
phone against the S5D.** The phone reaches Connected end-to-end and
`startStream` is accepted — the auth wall observed on the Linux
bench is *workstation-specific*, very likely down to the phone
holding LUMIX Sync's prior BT-pair context that satisfies the
camera's authenticated-session requirement. Live preview renders
smoothly at ~5 fps, freeze-free thanks to the 1 Hz keep-alive.
The "PR 3.5 — auth handshake for hardened firmware" task is now
**only** needed if/when we want the Sciens app to work on a
device that has *not* been BT-paired via LUMIX Sync.

PR 5 (controls + polling + mode hint + aperture sentinel) and PR 6
(EV compensation + self-timer) remain TBD on hardware.

## Phase 3 — protocol library (outline only)

Promote `lib/protocol/` into a standalone Dart package
(`packages/feiyu_protocol/`). Typed command API:
`gimbal.rotateAbsolute(yaw: …, pitch: …, roll: …)` etc.
Stream-based status push (current angles, mode, errors). Unit tests
with recorded frame fixtures from the Playground.

## Phase 4 — panorama app (outline only)

Add a third screen with the Brenizer workflow:

- Level button → `rotateAbsolute(0, 0, 0)`.
- Frame-lens focal input (default 24 mm).
- Capture-lens focal input (default 90 mm).
- Overlap slider (default 30 %).
- "Read framing" button → reads current gimbal yaw / pitch as panorama
  centre and remembers it.
- Computed preview: total H/V span, grid dimensions, total shot count,
  estimated duration.
- Start → sequencer: for each (yaw_i, pitch_j), rotateAbsolute → settle
  delay → takePhoto → inter-shot delay → next.
- Progress UI, cancel button, abort on disconnect.

Math:
- `H_span = 2·atan(17.5 / focal_frame)`, `V_span = 2·atan(12 /
  focal_frame)`.
- `step_h = 2·atan(17.5 / focal_capture) · (1 − overlap)`, similarly
  `step_v`.
- `n_cols = ceil(H_span / step_h) + 1`, `n_rows = ceil(V_span / step_v)
  + 1`.
- Grid is symmetric around the captured `(centre_yaw, centre_pitch)`.

## Out of scope (entire project)

- iOS / desktop / web targets.
- Camera-side control (PTP/MTP, USB tether, Wi-Fi shutter, image
  preview).
- Image stitching — done in PTGui / Hugin / Lightroom after capture.
- Firmware updates to the gimbal.
- Redistribution of any decompiled or derived code.
