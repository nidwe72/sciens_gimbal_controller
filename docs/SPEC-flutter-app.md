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
            8. ContentDirectory probe  (UPnP image-server probe)
            9. Review & export     (results + HTTP server)
```

**The wizard.** A linear `Stepper` with `currentStep` driven
manually; "Continue" is gated on the step's capture having run, and
steps tolerate failure (a diagnostic tool keeps partial results).
Steps 1–8 require `connected` + rec mode; step 9 works while
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

#### PR 8 — Captured-image review

After a capture the app fetches the resulting JPEG and shows it.

**UX (decided).**
- The captured still occupies the **live-preview pane**.
- Live preview **on** at capture time → the still shows for **~5 s**,
  then the live feed resumes.
- Live preview **off** → the still **stays** until the next capture.
- **Double-tap** the still → a full-screen dialog with gallery-style
  pinch-zoom + pan (`InteractiveViewer`); a close affordance leaves
  it.
- The pane uses a **medium-size** JPEG; the full-screen view fetches
  the **full-resolution** JPEG.
- Scope is the **last shot only** — not an SD-card browser.
- **JPEG is the user's responsibility** — the app does not touch the
  camera's quality setting; a RAW-only camera has no JPEG to show.

**Retrieval — UPnP/DLNA ContentDirectory (probed).** `camcmd
capture` only trips the shutter; the image lands on the card and is
fetched over the camera's UPnP MediaServer. The Step-1 probe
established the flow:

1. **SSDP M-SEARCH** → the device descriptor at
   `http://<ip>:60606/Lumix/Server0/ddd`. The MediaServer *is*
   advertised in rec/remote mode — **no `playmode` switch needed.**
2. The descriptor names the **ContentDirectory** service; its
   control URL is `http://<ip>:60606/Server0/CDS_control`.
3. **SOAP `Browse(ObjectID="0", BrowseDirectChildren)`** returns the
   image `<item>`s directly — no container nesting. The response
   carries `TotalMatches`; the list paginates via `StartingIndex` /
   `RequestedCount`, in capture order.
4. Each `<item>` carries three JPEG `<res>` resources, all served by
   a second HTTP server on **`:50001`**:
   - `JPEG_LRG` — `…:50001/DO<id>.JPG`, the full original (~9 MB) —
     used by the **full-screen** view;
   - `JPEG_SM` — `…:50001/DS<id>.JPG` (~100 KB) — used **inline**;
   - `JPEG_TN` — `…:50001/DT<id>.JPG` (~5 KB) — unused.
5. The **last shot** is the highest-indexed item — `Browse` near
   `StartingIndex = TotalMatches − 1`, picking the item with the
   highest `id` (the in-app code confirms the order rather than
   trusting it).

New transport: SOAP POST plus the plain `:50001` image GETs,
alongside the `cam.cgi` GETs. The control URL is SSDP-discovered
once per session and cached.

**As built.** `lib/camera/lumix_content.dart` holds the
ContentDirectory client: `extractSsdpLocation`, `findContentDirectory`
(descriptor → control URL, resolving `URLBase`/relative paths),
`browseSoapEnvelope` / `parseBrowseResult` (escaped DIDL-Lite →
`JPEG_SM`/`JPEG_LRG` URLs), and `LumixContent` (`discover()` caches
the SSDP-found service; `fetchLatest()` browses the list tail and
picks the highest `id`). `LumixCamera.rawGetBytes` GETs image bytes
through the FIFO queue without UTF-8 decoding; `decodeJpeg` gained a
`targetWidth` cap (full-screen decodes at ≤3000 px). `connect()`
warms discovery in the background. The pane (`_CameraPane`) shows the
still or the live feed, with the 5-s revert; double-tap opens
`_FullScreenImage` — an edge-to-edge `InteractiveViewer` with no app
bar (image centered on the whole screen, in either orientation), a
floating close button, and the system bars hidden (`immersiveSticky`,
restored on close). The capture button drives the fetch on its
success path. Tested in `test/lumix_content_test.dart`.

**Content-access recovery (on-hardware fixes).** Reading the DLNA
content server — the SOAP `Browse` and/or the `:50001` image
download — silently flips the camera into playback mode. `getstate`
still answers (so the connection looks alive), but two things break:

- `camcmd capture` is accepted without taking a photo — the *first*
  capture works, the *second* times out with "Capture may not have
  completed";
- the MJPEG live stream stops (playback mode has no live view), so
  the preview freezes on its last frame a few seconds after a shot.

`_restoreAfterContentAccess` (run in a `finally` after every fetch)
handles both: it re-asserts `recmode`, then — if live preview was
running — bounces it (`stopstream` + fresh socket + `startstream`)
since `recmode` does not restart the stream. For `fetchFullImage`
the restore runs unawaited so the full-screen viewer isn't delayed.
A `fetchInProgress` flag keeps the capture button disabled across the
whole fetch+restore, so a new capture can't land in the brief
playback window. (Discovery — SSDP + the descriptor GET — is a
harmless read and does *not* flip the camera, which is why the first
capture is unaffected.)

The mirror of this: the `:50001` image server only serves while the
camera is in **playback** mode. `fetchLastImage` gets there for free
(its `Browse` flips the camera before the download); `fetchFullImage`
has no Browse of its own, so — once `recmode` leaves the camera in
record mode — it must re-run `fetchLatest()` (a Browse) first to flip
back to playback before pulling the full-res JPEG. That download also
uses a longer `rawGetBytes` timeout (~25 s) — the default 5 s is too
tight for a ~9 MB file.

Verified on hardware (S5D): a still appears in the pane after every
capture; repeated capture, live-preview and full-screen cycles all
hold up; the full-screen viewer is centered and fills the screen in
both orientations.

#### PR 9 — Demo Lumix S5 (virtual camera)

**Goal.** Run the entire camera UX — connect, controls, capture,
image review, live preview — with **no real camera**, exactly the way
the Demo Gimbal runs the gimbal UX with no SCORP C2. For showcasing
the app, for development away from the S5D, and for emulators with no
WiFi radio.

**Behavior model — observable parity, not firmware fidelity.** Same
principle as `DemoGimbalTransport`: the demo reproduces the *result
the user sees* once the app has worked around the real camera's
quirks. It does **not** re-enact the record/playback-mode hostility
(PR 8's content-access bug) — `recmode` / `playmode` / `capture` /
`Browse` are simply accepted and always behave. Capture always
shoots; the content server always serves.

**"Retain the traffic."** The demo fakes only the **transport** — no
real HTTP, UDP, SSDP or `WifiNetworkChannel`. It synthesizes the
exact `cam.cgi` XML, the DIDL-Lite SOAP, and the JPEG frame bytes a
real S5D returns, so every layer above the transport runs unchanged:
the `lumix_protocol.dart` parsers, `CameraConnection`, `LumixContent`,
`jpeg_decoder`. This mirrors `DemoGimbalTransport` speaking the AK
protocol byte-for-byte.

**The seam — `CameraTransport`.** Today `LumixCamera` *is* the
transport (HTTP client + FIFO queue + discovery + `WifiNetworkChannel`
+ the `cam.cgi` endpoints + SOAP + raw GETs + SSDP). Extract its
public surface into an abstract `CameraTransport`:

- `LumixCamera implements CameraTransport` — the real HTTP
  implementation, unchanged in behavior.
- `DemoLumixCamera implements CameraTransport` — the new simulator.

`CameraConnection`, `LumixContent` and the diagnostics delegates
retarget from `LumixCamera` to `CameraTransport`. The `_cameraFactory`
becomes `CameraTransport Function()` — tests still pass a `LumixCamera`
factory unchanged.

**Live-preview seam.** `MjpegUdpStream` is currently opened directly
by `CameraConnection`. Move that behind the transport: `CameraTransport`
owns `startStream` / `stopStream` and exposes the decoded **JPEG-frame
stream**. `LumixCamera` wraps `MjpegUdpStream` internally;
`DemoLumixCamera` emits its synthetic frames (the two alternating
variants). `CameraConnection` consumes the transport's frame stream
rather than constructing a socket.

**The virtual body.** `DemoLumixCamera` holds the state a real S5's
body and card would hold:

- **Shooting mode** — P / A / S / M; drives `getstate` and the
  `curmenu` recmode readout.
- **Battery level** — 0–5 bars; drives the battery indicator.
- **Current exposure settings** — shutter / ISO / aperture / EV-comp;
  sensible defaults, updated when the app sends `setsetting`.
- **Capability lists** — the shutter / ISO / aperture values the body
  reports via a synthesized `getinfo?type=allmenu`; hardcoded to the
  real S5D's lists (PR 5 / PR 6 verified them) or otherwise sensible.
- **SD card** — a hardcoded, always-ample free-shot count that
  decrements by one per capture (so the capture button's
  decrement-detection works). No "card full" state.
- **Captured shots** — a virtual ContentDirectory list; each capture
  appends an entry. `Browse` returns it; the `:50001` URLs resolve to
  the bundled image.

**The "Virtual Lumix S5" tab.** A tab shown **only while the demo
camera is connected** (hidden for a real camera and when
disconnected). It stands in for the camera body's physical controls,
letting the user set the **mode dial** (P / A / S / M) and the
**battery level**. Writes go to `DemoLumixCamera`'s virtual state;
the poll picks them up, so the camera tab's mode readout and battery
indicator update through the normal path — no extra wiring. So the
dial change shows promptly (rather than after ~5 s), the poll fetches
`curmenu` **every cycle in demo mode** — `_pollCycle % (isDemo ? 1 :
5)`; the real every-5th-cycle gate exists only because the real
`curmenu` is a heavy ~45 KB download, which the demo's is not.

**The synthetic image.** A bundled architectural photo
(freely-licensed, converted to **black & white**) at a resolution
that holds up under full-screen zoom — this is the captured still,
served for both the `JPEG_SM` and `JPEG_LRG` resource URLs. For the
live-preview flicker, two **downscaled** variants of the same shot
are bundled alongside it: a clean copy and one with a subtle
brightness/grain tweak. Live preview **alternates the two preview
variants** on successive frames at ~5 Hz so the feed reads as
*somewhat live* — a gentle shimmer — rather than a frozen frame. The
downscale + variant difference are baked in at asset-prep time; no
runtime image processing. Each asset is kept **≤ 2 MB** — they are
committed to the repo.

**Selecting the demo.** A **"Demo Lumix S5"** entry in the camera
tab's connect view, beside the real connect controls — analogous to
the Demo Gimbal row in the gimbal connect screen. It calls
`CameraConnection.connect(demo: true)`, which builds a
`DemoLumixCamera`. The demo's connect lifecycle fakes `bind` /
discovery / `accctrl` / `getstate` / `setsetting` / `recmode` /
`allmenu` with short phase delays, like `DemoGimbalTransport`'s
`_phaseDelay`.

**Out of scope for the demo.** No SD-card-full state; no error
injection; one architectural shot (its two preview variants aside) —
no image library.

**Implementation steps.**

1. **`CameraTransport` interface.** Extract it from `LumixCamera`;
   `LumixCamera implements` it; retarget `CameraConnection`,
   `LumixContent`, diagnostics. Pure refactor — all existing tests
   stay green.
2. **Preview-frame seam.** Move `MjpegUdpStream` ownership into
   `LumixCamera`; `CameraTransport` exposes the frame stream;
   `CameraConnection` consumes it.
3. **`DemoLumixCamera` core + connect entry.** The virtual body +
   wire-format synthesis for connect, the poll, controls and capture
   (`accctrl`, `getstate`, `getinfo allmenu`, `getsetting` /
   `setsetting`, `recmode`, `curmenu`, `camcmd capture`). Wire up
   `connect(demo: true)` and add the **"Demo Lumix S5" connect
   button** to the camera connect view — so Steps 3–5 are each
   on-device testable. Connect / controls / capture work in demo.
4. **Demo image pipeline.** Bundle the architectural JPEG; synthesize
   SSDP / descriptor / SOAP `Browse`; serve the asset bytes for the
   `:50001` URLs. Inline + full-screen review work in demo.
5. **Demo live preview.** Bundle the two downscaled preview variants;
   alternate them at ~5 Hz so the feed reads as live.
6. **UI — the "Virtual Lumix S5" tab.** A third sub-tab of the Camera
   tab (mode dial + battery), shown only in demo mode.
7. **Tests.** The demo's synthesized wire formats round-trip through
   the real parsers (`parseGetState`, `parseAllMenu`,
   `parseBrowseResult`, `parseRecmode`); capture decrements capacity;
   mode / battery changes surface on the next poll.

Verified: 113 unit tests round-trip every demo wire format through
the real parsers (`isResultOk`, `parseGetState`, `parseAllMenu`,
`parseGetSetting`, `parseRecmode`, `extractSsdpLocation`,
`findContentDirectory`, `parseBrowseResult`), plus the full
`LumixContent.fetchLatest()` chain against the demo. On-device, the
Demo Lumix S5 connects, controls + capture work, the still and the
full-screen viewer show the bundled black-and-white photo, and the
live preview shimmers. The Virtual Lumix S5 tab's mode dial and
battery slider drive the camera tab's readouts via the normal poll
path.

#### PR 10 — Capture delay + capture sounds

**Scope.** Two small camera-tab additions that finish the deferred
PR 6 self-timer piece: a software-driven capture delay, and audible
shutter / beep cues during capture.

**Capture delay (software-only).** A text field labelled
"Capture delay (s)" — accepts **non-negative integers only**,
**unbounded**, default `0`. The camera body's own self-timer is
**not** used; the delay is a software countdown inside the app, so
the count, the cancel affordance and the beep cadence are all under
our control. Tapping **Capture** with delay > 0 starts the
countdown — the button relabels to **Cancel**, and an inline
"Capturing in N…" line counts down beside it. At T = 0 the
existing `CameraConnection.capture()` runs — the same call used
today for delay = 0. Tapping **Cancel** during the countdown
aborts the firing: no shutter call, no further beeps, button
returns to **Capture**. When the app is backgrounded
mid-countdown the countdown is aborted (so the camera doesn't fire
while the user has moved on). Independent of any Phase 4 panorama
settle-delay (Phase 4 will have its own).

**Capture sounds.** Two SFX layered above the transport:

- **Shutter** — a mechanical-SLR sample, played once at T = 0 on
  **every** capture (with or without delay). The shutter sound is
  *not* gated on delay > 0 — an immediate capture is audibly
  confirmed too, so the user doesn't have to look at the screen to
  know a shot has fired.
- **Beep** — short tone played during the countdown,
  **Nikon-style** cadence:
  - **Slow phase** — one beep at the start of each remaining second
    while `seconds_remaining ≥ 3`.
  - **Fast phase** — one beep every 0.5 s during the final 2 s, at
    T = 2.0, 1.5, 1.0, 0.5.
  - At T = 0 the shutter sound plays (no beep at T = 0).

  Beep counts:
  | delay N | slow beeps | fast beeps | + shutter |
  |---:|:---:|:---:|:---:|
  | 0 | 0 | 0 | 1 |
  | 1 | 0 | 2 (T = 1.0, 0.5) | 1 |
  | 2 | 0 | 4 (T = 2.0, 1.5, 1.0, 0.5) | 1 |
  | 3 | 1 (T = 3) | 4 | 1 |
  | 10 | 8 (T = 10…3) | 4 | 1 |

A single **Mute** checkbox sits beside the delay field. Default:
**unchecked** — i.e. sounds play. When checked, neither beep nor
shutter is emitted (the camera still fires; the checkbox gates audio
only).

**Silent / ringer mode.** Sounds play through Android's
**STREAM_MUSIC** (media stream). Media volume controls level; the
device's ringer / silent mode does **not** mute them. The in-app
Mute checkbox is the only audio mute. This is deliberate — the
user opted in by leaving Mute unchecked.

**UI placement.** The **Capture options** subsection sits above the
Capture button, two compact rows:

```
Capture delay (s): [____]
Mute:              [ ]
```

**Capture button.** Plain **Capture** label; no relabel during a
countdown, no in-button spinner. The button is **disabled** while a
capture is in flight — both for the immediate-fire delay = 0 path
and for the delay > 0 path — and re-enables on completion or cancel.
The previous in-button `CircularProgressIndicator` is **removed**.

**Progress overlay (delay > 0 only).** A **screen-centred modal
overlay** appears for the duration of `captureWithDelay` calls with
a delay > 0. For **delay = 0 the overlay does not appear** —
feedback is the shutter sound (when unmuted) and the captured still
arriving in the pane.

- The overlay is a **~50 %-opacity scrim** covering the whole screen
  and intercepting taps so the UI underneath can't be driven during
  capture.
- Centred on the scrim: the dominant indicator (~120 dp diameter;
  final size at impl time), with a small **Cancel** text button
  rendered just below it.
- **Countdown phase (T = N → T = 0).** Indicator is a **thick gray
  ring** that drains from full at T = N to empty at T = 0. The
  seconds-remaining integer renders large in the centre of the ring.
  Cancel is active — tapping it invokes `cancelCountdown()` and the
  overlay dismisses immediately.
- **Firing phase (T = 0 → photo lands).** The ring + seconds number
  give way to an **iris (camera-aperture) glyph** in the same
  centred spot, **blinking at ~1 Hz** between gray
  (`Theme.of(context).colorScheme.outline`) and the theme's primary
  colour (`...colorScheme.primary`). The Cancel button is hidden —
  an in-flight camera shot can't be cancelled.
- **Dismissal triggers:** capture success (the still lands in the
  pane), capture error (the existing error messages render in their
  current location once the overlay dismisses), Cancel tap during
  the countdown, or `AppLifecycleState.paused`.

**Iris glyph.** Implemented as an SVG asset
(`assets/icons/iris.svg`, freely-licensed; sourced at impl time
alongside the audio clips) rendered with `flutter_svg`. Tint cycles
via a `ColorTween` driven by a 1 Hz `AnimationController`.
Alternative: a small `CustomPainter` 6-blade aperture if we'd
rather skip the SVG dependency — choice deferred to impl time.

**Persistence — none for this PR.** Both fields reset to defaults
(`0` and unchecked) at every app launch. Shared-prefs persistence is
a candidate for a later PR.

**Demo Lumix S5.** Sounds layer above the transport, so the Demo
Lumix S5 plays them too. No `DemoLumixCamera` changes;
`CameraConnection` already drives capture identically for real and
demo transports.

**Audio package and assets.**

- **Package:** `soundpool` — a thin wrapper around Android's
  `SoundPool` API, sized for short low-latency SFX. The Flutter
  package configures the Android stream type to **MEDIA**, satisfying
  the ringer-bypass requirement above. (Sound playback on iOS /
  desktop is out of scope; the Mute checkbox effectively no-ops
  there.)
- **Assets:** `assets/sounds/shutter.ogg` and `assets/sounds/beep.ogg`,
  sourced under an **open license** — Freesound CC0 preferred, CC-BY
  acceptable with attribution. Sized to fit comfortably inside the
  APK (a shutter clip ≤ 200 KB, a beep ≤ 30 KB).
- **Attribution:** `assets/sounds/CREDITS.txt` matches the existing
  `assets/demo/CREDITS.txt` convention — per-clip source URL, license,
  author.

**Edits.**

- `lib/camera/capture_sounds.dart` (new) — wraps `Soundpool`.
  Abstract `CaptureSounds` interface exposing `playBeep()` and
  `playShutter()`; a real `SoundpoolCaptureSounds` implementation
  that lazy-loads the two clips on first use, and a
  `NullCaptureSounds` no-op for tests. One instance per
  `CameraConnection` lifetime; disposed on disconnect. The instance
  reads `CameraConnection.muted` on each call and skips playback when
  muted.
- `lib/camera/camera_connection.dart` —
  - `captureWithDelay(int seconds)` orchestrates the countdown, the
    beep cadence, and the final `capture()` call. Replaces the
    current button-driven plain `capture()` call as the entry point
    from the UI.
  - `ValueListenable<int?> countdownSecondsLeft` — running seconds
    integer during the countdown phase; `null` once the firing phase
    starts or when no capture is active.
  - `ValueListenable<bool> overlayActive` — `true` from the moment
    a `captureWithDelay(seconds > 0)` begins until that capture
    completes (success, error, cancel, or app-paused abort). The UI
    binds the overlay's visibility to this. For
    `captureWithDelay(0)` this stays `false` throughout — the
    overlay never appears.
  - `cancelCountdown()` aborts a countdown in progress (no effect
    once the firing phase has started).
  - `ValueNotifier<bool> muted` mirrors the checkbox.
  - A `WidgetsBindingObserver` aborts the countdown on
    `AppLifecycleState.paused` (and clears `overlayActive`).
- `lib/ui/tabs/camera_tab.dart` —
  - A new `_CaptureOptions` widget (delay text field + Mute
    checkbox) sits above the existing Capture row.
  - A new `_CaptureOverlay` widget renders the scrim + the centred
    indicator (the gray countdown ring during the countdown phase;
    the animated iris glyph during firing) + the Cancel text button
    (only during the countdown phase). It is inserted at the camera
    tab's root as a `Stack` sibling, visible while
    `conn.overlayActive == true`.
  - The Capture button is simplified — no relabel, no in-button
    spinner; just a normal button that is enabled / disabled.
    Tapping it calls `conn.captureWithDelay(currentDelay)`.
  - The delay field uses
    `TextInputType.numberWithOptions(decimal: false, signed: false)`
    and a `FilteringTextInputFormatter.digitsOnly` to enforce
    non-negative-integer-only input.
- `lib/camera/demo_lumix_camera.dart` — no changes.
- `pubspec.yaml` — add `soundpool:` and `flutter_svg:` to
  dependencies (versions pinned at impl time), and `assets/sounds/`
  + `assets/icons/` entries. (`flutter_svg` drops out if the iris
  is implemented as a `CustomPainter` instead.)
- `assets/sounds/{shutter.ogg, beep.ogg, CREDITS.txt}` (new).
- `assets/icons/iris.svg` + `assets/icons/CREDITS.txt` (new — only
  if the SVG-asset path is chosen for the iris glyph).

**Tests.**

- `test/camera_connection_test.dart` extends — all under
  `FakeAsync`:
  - `captureWithDelay(0)`: transport's `capture()` called once
    immediately; one `playShutter()` (when not muted); zero
    `playBeep()`. `overlayActive` **stays false** throughout.
  - `captureWithDelay(5)`: slow beeps at T = 5, 4, 3 (3 ticks); fast
    beeps at T = 2.0, 1.5, 1.0, 0.5 (4 ticks); shutter at T = 0;
    `capture()` called exactly once. `countdownSecondsLeft` ticks
    5 → 4 → 3 → 2 → 1 → null in lockstep. `overlayActive` is
    `true` from the call until the capture completes.
  - `captureWithDelay(1)`: only the two fast beeps (T = 1.0, 0.5) +
    shutter at T = 0. `overlayActive` toggles as in the 5-s case.
  - `captureWithDelay(5)` then `cancelCountdown()` at T = 3: no
    further beeps, no shutter, transport `capture()` never called;
    `overlayActive` flips false on cancel.
  - `muted = true`: 0 beeps, 0 shutter, capture still fires at T = 0.
  - `AppLifecycleState.paused` mid-countdown: countdown aborts;
    `capture()` not called; `overlayActive` flips false.
- `test/capture_sounds_test.dart` (light) — confirms
  `NullCaptureSounds` is a no-op. The production implementation
  (now `AudioPlayersCaptureSounds`, see "As built" below) hits real
  platform audio and is covered by on-device verification rather
  than a unit test.

**Verifies on hardware (S5D)** — assuming the BT-paired Android
phone per the PR 4 note:

- Delay = 0, Mute unchecked: tap Capture → **no overlay**; the
  Capture button briefly disables; shutter sound plays immediately;
  photo lands on the card.
- Delay = 10 s, Mute unchecked: tap Capture → screen dims to the
  scrim; the gray countdown ring fills the centre with **10**
  inside; the ring drains from full → empty over 10 s as the number
  ticks 10 → 1; slow beeps for the first 8 s, fast beeps in the
  final 2 s. At T = 0 the ring / number give way to the **iris
  glyph blinking gray ↔ primary blue**; the shutter sound plays;
  the exposure fires; the overlay dismisses when the captured still
  lands in the pane.
- Cancel mid-countdown: tap the **Cancel** text under the ring →
  overlay dismisses immediately; no further beeps, no shutter, no
  firing.
- Mute checked + delay = 5: countdown overlay still appears (Mute
  gates audio only); no shutter sound; photo still fires at T = 0.
- Phone in silent / ringer-off mode: sounds still play.
- App backgrounded (home button or app switcher) mid-countdown:
  overlay dismisses; nothing fires when the app returns.

**Verifies in demo mode.** Same checks against the Demo Lumix S5 —
capture delay and sounds behave identically, since both layer above
the transport.

**As built — final shipped form.** The implementation diverged from
the plan above in several places after on-device iteration. The
shipped state:

- **UI layout (the biggest visible change).** The "Capture options"
  block specced as a single section above the Capture button got
  split into two rows that bracket the rest of the camera tab:
  - **Top of the connected view** — the **Capture** button sits
    directly under the camera header / divider.
  - **Bottom of the connected view (just above the Mute row)** — a
    single line `[☐ Delay] [ 3 ] s` row with a `Delay` checkbox
    followed by the seconds input. The checkbox **gates** whether
    the typed seconds apply (default off → no delay regardless of
    field value); the field is greyed when the checkbox is off and
    starts at `3` so once toggled on the user has a sensible
    value.
  - **Very bottom of the connected view** — a single `Mute`
    checkbox row.
- **delay = 0 path no longer skips the overlay.** The iris glyph
  still flashes briefly for the duration of the camera-firing
  window, with a **500 ms minimum-display floor** so fast shutters
  register. (The original plan called for "no overlay on delay = 0";
  in practice the brief iris flash makes every capture both
  audibly and visually confirmed.)
- **500 ms minimum iris display** for the delay > 0 path too — so
  even a fast shutter at T = 0 doesn't blink the iris on/off
  imperceptibly.
- **Iris glyph behaviour.** Solid `colorScheme.primary` fill. **No
  alpha pulse and no gray ↔ primary cycle** — the in-between
  values blended with the dark scrim and made the iris read as a
  lighter green than the header. Rendered at **255 dp** (~50 %
  larger than the 140 dp countdown ring) so the firing phase
  visually dominates the countdown phase.
- **Iris source.** The `mdi-camera-iris` glyph (6-blade aperture,
  Material Design Icons). Roughly 83 % viewBox fill, hence the
  bump to 255 dp to match the ring's apparent diameter.
- **Countdown ring colour.** Uses `colorScheme.primary` (theme
  green) — not the original gray — so the ring + iris share one
  brand colour throughout the overlay.
- **Brand colour.** Theme seed changed from the dark blue-gray
  `#263238` to a green `#2E7D32`, so the capture-active visuals
  pop on the dark scrim. To keep the rest of the tab content
  pure white (and avoid M3's default tonal-surface tinting),
  `ColorScheme.surface*` and `surfaceTint` are overridden to
  `Colors.white` / `Colors.transparent` in `main.dart`.
- **Audio package — `audioplayers ^6.0.0`** instead of `soundpool`.
  Soundpool 2.4.1 still references Flutter's deprecated
  embedding-v1 `Registrar` API and won't compile against current
  Flutter; `audioplayers` is actively maintained and supports
  configuring an Android audio context with `usageType: media` +
  `contentType: music`, so the SFX route through `STREAM_MUSIC` and
  bypass the device's ringer / silent mode (same end behaviour as
  the original spec).
- **Shutter clip.** A single MP3 sample
  (`assets/sounds/shutter.mp3`, ~1 s, SoundReality via Pixabay) is
  played from start on each capture. The original plan called for
  separate `shutter_open` + `shutter_close` clips with the close
  click scheduled by the current shutter-speed wire value; on
  audition a single full-envelope clip reads more naturally on
  common exposure speeds, and a single clip is simpler.
- **Beep clip.** Still synthesized — a 100 ms 880 Hz sine wave
  from `sox`, as planned (`assets/sounds/beep.ogg`).
- **Overlay reach.** The PR 11 follow-up that landed before PR 10
  moved the device icons into the app header and the device
  selector into a bottom `NavigationBar`. The capture overlay
  scrims only the camera-tab content area, so the header (with
  brand mark + device icons) and the bottom `NavigationBar` stay
  visible during a countdown.
- **Dropped tests.** The `test/capture_overlay_test.dart` widget
  test the original plan called for was **not implemented** — its
  assertions are visual and effectively duplicate on-device
  verification; low signal-to-effort.

Tests landed: six `FakeAsync` `captureWithDelay` cases on
`test/camera_connection_test.dart` covering the cadence
(delay = 0 / 1 / 5), Cancel, Mute, and `AppLifecycleState.paused`
paths.

#### PR 11 — Devices panel & per-device connect

**Scope.** App-shell restructure: the camera becomes usable
**without** a gimbal connection (and vice versa). The startup flow
drops `ConnectScreen`; both the gimbal and the camera are reached
via a new **Devices panel** below the app header, one icon per
device opening a modal bottom sheet for connect / disconnect.

**Motivation.** Phase 2 has made the camera a first-class peer of
the gimbal — but the launch flow still forces a gimbal connection
before any camera UI is reachable. The data layer is already
independent (`GimbalConnection` and `CameraConnection` are separate
objects); only the shell hard-codes "gimbal first". Phase 4
(panorama) will also need the two connections independently.

**Devices panel.** A new horizontal row sits **below the app
`Header`** and **above the tab strip**. Two `DeviceButton` widgets
side by side:

- **Camera** — camera glyph (starting candidate `Icons.camera_alt`,
  final choice at impl time), label `Camera` underneath.
- **Gimbal** — `Icons.joystick` (Material Icons; the vertical-stick
  silhouette reads cleanly as a gimbal handle), label `Gimbal`
  underneath.

Each `DeviceButton` reflects the **connection state** of its
device, derived from the corresponding connection object's existing
state machine:

- **Disconnected** — outlined icon at ~50 % opacity.
- **Connecting** — outlined icon with a small gray ring overlaid
  (re-use the countdown ring style from PR 10).
- **Connected** — filled icon, tinted with
  `Theme.of(context).colorScheme.primary`.

Tapping a button opens a **modal bottom sheet**
(`showModalBottomSheet`) for that device. The button stays
tappable in the **connecting** state too — opening the sheet then
surfaces the in-progress connection (spinner + status) rather
than a fresh scan list.

**Modal bottom sheets.** Two sheets, each holding the full
connect / disconnect UX for its device:

- **Gimbal sheet** (`lib/ui/sheets/gimbal_sheet.dart`, new) —
  carries today's `ConnectScreen` content: BLE scan list, Demo
  Gimbal entry, connect / cancel-scan controls. When the gimbal is
  already connected, the sheet shows a **Disconnect** button
  instead, with a summary line (device name + MAC + MTU).
- **Camera sheet** (`lib/ui/sheets/camera_sheet.dart`, new) —
  carries today's `_DisconnectedView` content from
  `camera_tab.dart`: WiFi-side scan / direct-IP connect, Demo Lumix
  S5 entry. When connected, the sheet shows a **Disconnect** button
  with the connected camera's summary line.

Both sheets dismiss when their connect attempt completes
(transitions to Connected) or when the user taps outside the sheet
/ swipes it down.

**Tab structure & naming.**

- **Gimbal** — **renamed** from the `pan/tilt/roll` tab label to
  `gimbal` (lowercase, matching the existing `camera` / `logs`
  labels). File `gimbal_tab.dart` (via `git mv` from
  `controls_tab.dart`); class `GimbalTab` (from `ControlsTab`).
  When the gimbal is connected, the tab body shows today's controls
  + 3D visualization unchanged. When disconnected, a centred
  placeholder: **"Connect a gimbal — tap the gimbal icon above."**
- **Camera** — name unchanged. When the camera is connected, the
  tab body shows today's connected-camera UI (live preview,
  controls, capture, captured-still pane, the PR 10 capture
  overlay). When disconnected, a centred placeholder:
  **"Connect a camera — tap the camera icon above."** The tab no
  longer hosts any connect controls of its own.
- **Logs** — unchanged.
- **Virtual Lumix S5** (PR 9) — unchanged: appears only when the
  Demo Lumix S5 is the connected camera.

**Launch flow.** `main.dart` opens directly to `PlaygroundScreen`
with both devices in the **disconnected** state. No auto-popup of
any connect sheet. The user reaches a connect sheet by tapping the
matching device icon in the Devices panel.

**Connection persistence.** Switching tabs and brief app
backgrounding (`AppLifecycleState.paused`) do **not** drop either
connection. Connections drop only on explicit **Disconnect** in the
sheet, or on hardware / network loss (BLE link loss, WiFi network
change). After a drop, the device icon returns to its disconnected
state, the corresponding tab body switches to the "Connect …"
placeholder, and the other device is unaffected.

**Capture overlay interaction (PR 10).** The PR 10 capture overlay
scrims the **camera tab's content area only** — the header and the
Devices panel remain visible during a countdown. The user can still
see device state through the overlay; disconnecting either device
mid-countdown via its sheet is allowed but not a required
interaction.

**Edits.**

- `lib/ui/devices_panel.dart` (new) — the horizontal row holding
  two `DeviceButton`s; reads both connections' states.
- `lib/ui/device_button.dart` (new) — single button widget
  parameterised by icon, label, the connection-state value, and an
  `onTap` callback. Renders the three visual states.
- `lib/ui/sheets/gimbal_sheet.dart` (new) — modal sheet content
  for the gimbal device; takes the `GimbalConnection`. Re-uses the
  existing scan-list inner widgets (`device_row.dart` etc.).
- `lib/ui/sheets/camera_sheet.dart` (new) — modal sheet content
  for the camera device; takes the `CameraConnection`. Re-uses the
  scan / direct-IP / Demo Lumix UI extracted from
  `camera_tab.dart`'s `_DisconnectedView`.
- `lib/ui/playground_screen.dart` — no longer assumes a connected
  gimbal. Inserts the Devices panel between the header and the tab
  strip. Each tab body renders either the connected content or the
  "Connect a {gimbal,camera}" placeholder, gated on the matching
  connection's state.
- `lib/ui/tabs/gimbal_tab.dart` — renamed from
  `lib/ui/tabs/controls_tab.dart` via `git mv`. Body content
  unchanged except for the disconnected-placeholder branch.
- `lib/ui/tabs/camera_tab.dart` — remove `_DisconnectedView`,
  `_ConnectingView`, the manual-IP toggle state, and the `switch`
  on `CameraStatus` in `_CameraControlsTab.build` — that logic
  moves into `camera_sheet.dart`. The tab body collapses to
  `if (isConnected) return _ConnectedView else return
  _CameraPlaceholder`. The **in-tab Disconnect button** on
  `_ConnectedView` is also removed — disconnect is now solely
  through the camera sheet.
- `lib/main.dart` — drop the `ConnectScreen` push; launch
  `PlaygroundScreen` directly. The two connection objects are
  constructed at app start and held by the root widget (today's
  pattern; no change to who owns them).
- `lib/ui/connect_screen.dart` — **deleted**. Shared inner widgets
  it used (e.g. `device_row.dart`) stay where they are.

**Implementation steps.** Eight phases, each committed independently
and leaving the build green:

1. **`DeviceButton` + `DeviceState`.** New `lib/ui/device_button.dart`
   — the enum and the widget rendering the three visual states.
   Widget tests cover all three states + tap. Unused yet.
2. **Gimbal sheet.** New `lib/ui/sheets/gimbal_sheet.dart`. Extract
   the body of `ConnectScreen` (scan lifecycle, scan-toggle, status
   row, `ListView.separated`, BLE permissions) and the
   `_DeviceRowTile` into the sheet. Add a "connected" branch
   (summary + Disconnect). `ConnectScreen` itself stays intact.
3. **Camera sheet.** New `lib/ui/sheets/camera_sheet.dart`. Extract
   `_DisconnectedView` + `_ConnectingView` from `camera_tab.dart`;
   move the manual-IP toggle state into the sheet. Add a
   "connected" branch (summary + Disconnect). Originals in
   `camera_tab.dart` remain intact.
4. **`DevicesPanel`.** New `lib/ui/devices_panel.dart`. `ConsumerWidget`
   watching both connection providers, mapping to `DeviceState`,
   rendering two `DeviceButton`s in a row. Each `onTap` opens the
   matching sheet via
   `showModalBottomSheet(isScrollControlled: true, ...)`.
5. **`PlaygroundScreen` restructure.** Drop the kick-back-to-Connect
   logic; replace `_ConnectionSummary` with `const DevicesPanel()`;
   rename the `pan/tilt/roll` tab label → `gimbal`; simplify the
   PopScope cleanup (no more `pushReplacement(ConnectScreen)`).
   `ConnectScreen` is still the launch screen at this phase.
6. **Camera tab simplification.** Delete `_DisconnectedView`,
   `_ConnectingView`, the `CameraStatus` switch, the manual-IP
   toggle state, and the in-tab Disconnect button. The tab body
   collapses to the if/else placeholder pattern.
7. **Gimbal tab rename + placeholder.** `git mv controls_tab.dart
   gimbal_tab.dart`; rename `ControlsTab` → `GimbalTab`; add the
   early `if (!isConnected) return _GimbalPlaceholder` branch.
   Update `playground_screen.dart` import + constructor name.
8. **Launch cutover + delete dead code.** Point `main.dart` at
   `PlaygroundScreen`; `git rm lib/ui/connect_screen.dart`; tidy
   imports.

**Tests.**

- `test/widget/devices_panel_test.dart` (new) — three states per
  device: disconnected icon is dimmed; connecting overlay shows the
  ring; connected icon is filled and tinted. Tap dispatches the
  callback.
- `test/widget/playground_screen_test.dart` (new) — placeholder
  text appears in each tab body when its device is disconnected
  and the connected content appears when connected. Both states
  driven by fake `GimbalConnection` / `CameraConnection`.
- Existing `camera_connection_test.dart`,
  `demo_gimbal_transport_test.dart`, `frame_codec_test.dart` etc.
  are unaffected — the data layer is untouched.

**Verifies (demo + real hardware).**

- **Cold launch.** Both devices disconnected. PlaygroundScreen
  appears immediately; tab bodies show "Connect a …" placeholders;
  the tab strip is Gimbal + Camera + Logs.
- **Connect camera first (demo).** Tap the **Camera** icon → camera
  sheet slides up. Select Demo Lumix S5 → sheet dismisses, Camera
  icon flips to filled blue; Camera tab body switches to the
  connected view; the Virtual Lumix S5 tab appears in the tab
  strip. The Gimbal icon and tab remain in their disconnected
  state.
- **Connect gimbal independently (demo).** Tap the **Gimbal** icon
  → gimbal sheet slides up. Select Demo Gimbal → Gimbal icon flips
  to filled blue; Gimbal tab body switches to the connected
  content (3D visualization etc.). The Camera connection is
  unaffected.
- **PR 10 capture from the connected camera.** Tap Capture (with or
  without a delay) → behaviour is unchanged from PR 10. The header
  + Devices panel remain visible through the capture overlay.
- **Disconnect one device.** Tap the connected **Camera** icon →
  sheet opens with Disconnect + summary; tap Disconnect → icon
  reverts to dimmed, Camera tab returns to its placeholder. The
  Gimbal connection is untouched. Same flow inverted for the
  Gimbal.
- **App background / resume.** Background the app for ~30 s, then
  resume — both connections persist; device icons stay filled.
- **Real hardware.** Same matrix against a real SCORP-C2 +
  S5D — sheets list real-device entries; connect / disconnect on
  one side does not perturb the other.

#### PR 11 — Header redesign (follow-up)

**Scope.** Follow-up to the PR 11 devices panel: re-brand the app
shell around the Panoramique identity and absorb the standalone
`DevicesPanel` row from the original PR 11 wave into the right
side of the app header. After this follow-up the header is the
only row above the tab strip.

**Motivation.** Phase 4's panorama workflow is the app's reason
for existing — the brand should say so. The previous
"Sciens Gimbal Controller" title was a remnant of Phase 0 when the
gimbal was the main act. The new tagline is punchier and names the
"vintage glass on a modern body + gimbal" workflow without
spelling it out. Folding the devices panel into the header (it's
two icons; their slot is small) tightens the layout and frees the
row below the header for the tab strip alone.

**Layout.**

```
┌──────────────────────────────────────────────────────────────────┐
│ [appIcon]  Panoramique                       [cam]     [gimbal] │
│ sciens.at  old glass, wide world            Camera    Gimbal   │
└──────────────────────────────────────────────────────────────────┘
```

- **Left.** The existing Android launcher icon (from
  `android/app/src/main/res/mipmap-*/ic_launcher.png`) rendered at
  about 40–48 dp, with `sciens.at` directly underneath in small
  (~11 sp), lowercase, slightly faded text — a watermark, no
  link-out.
- **Centre-left.** `Panoramique` as the main title (Material 3
  `titleLarge` or similar), with the tagline `old glass, wide world`
  beneath in `bodySmall` and a subtle onSurface dim.
- **Right.** The two `DeviceButton`s from PR 11, side by side, with
  their `Camera` / `Gimbal` labels kept underneath each icon.
  Three visual states unchanged (dimmed outline / outline + small
  ring / filled tinted). Each opens its matching modal sheet on
  tap, exactly as today.

The `AppHeader`'s `preferredSize.height` grows to host the two-line
content + labelled device buttons — roughly **72–80 dp** of fixed
height, finalised at impl time. The `PlaygroundScreen` body Column
becomes `AppHeader → Divider → TabBar → TabBarView`; the
standalone `DevicesPanel` row introduced in PR 11 is removed.

**Identity changes.**

- **In-app title** in the header — `Sciens Gimbal Controller` →
  `Panoramique`.
- **`MaterialApp(title: …)`** in `main.dart` — `Sciens Gimbal
  Controller` → `Panoramique (Sciens)`. This is what the Android
  task switcher (recents) shows.
- **Android launcher label** — `android:label` in
  `AndroidManifest.xml` → `Panoramique (Sciens)`. The parenthetical
  keeps the `Sciens` cue on the home screen so the app remains
  recognisable.
- **Tagline** — `old glas goes digital` → `old glass, wide world`.
- **Dart package name** — stays `sciens_gimbal_controller`.
- **Android `applicationId`** — stays `at.sciens.gimbal_controller`.
  Renaming would force a reinstall and a re-pair of the gimbal;
  not worth it for a brand change.
- **App icon** — unchanged for this PR. The existing launcher
  icons are reused both on the home screen and in the header's
  left region. Can be revisited later.

**Edits.**

- `lib/ui/header.dart` — rebuild `AppHeader` end-to-end:
  - Left region: an `Image.asset` or `Image` resolving the launcher
    icon (`android/app/src/main/res/mipmap-mdpi/ic_launcher.png` or
    the highest-density variant rendered down), with `sciens.at`
    below.
  - Centre region: a `Column` with `Panoramique` (`titleLarge`) on
    top and `old glass, wide world` (`bodySmall`, dimmed)
    below. Padded with breathing room from the icon column.
  - Right region: a `Row` of two `DeviceButton`s, populated by the
    same state-mapping helpers that live in `devices_panel.dart`
    today (`_cameraState`, `_gimbalState`, `_openSheet`) — moved
    into this file.
  - `preferredSize` returns `Size.fromHeight(76)` (or the final
    chosen value).
- `lib/ui/playground_screen.dart` — drop the
  `const DevicesPanel()` child from the body Column. The Column
  becomes `[Divider, TabBar, Expanded(TabBarView)]` (or just
  `[TabBar, Expanded(TabBarView)]` if the divider also goes; final
  call at impl time).
- `lib/ui/devices_panel.dart` — **deleted** via `git rm`. Its two
  `DeviceButton` instantiations + state-mapping helpers move into
  `header.dart`.
- `lib/main.dart` — `MaterialApp(title: 'Sciens Gimbal Controller')`
  → `MaterialApp(title: 'Panoramique (Sciens)')`.
- `android/app/src/main/AndroidManifest.xml` — the application's
  `android:label` → `Panoramique (Sciens)`.
- `assets/` — no new assets in this PR; existing launcher icons
  are reused for the header.

**Tests.**

- The PR 11 `test/device_button_test.dart` widget tests stay green
  unchanged — `DeviceButton` itself is untouched.
- Light, optional addition: a `test/header_test.dart` that
  pump-tests `AppHeader` against fake connection providers and
  asserts the three regions render (icon, `Panoramique` text,
  tagline text, two `DeviceButton`s with the right states).
  Low priority; covered by manual verification.

**Verifies on device.**

- The Android launcher shows the icon labelled
  `Panoramique (Sciens)` (after reinstall — Android caches labels).
- The app header renders in one row containing: the launcher icon
  with `sciens.at` beneath, `Panoramique` as the title with
  `old glass, wide world` beneath, and the two `DeviceButton`s
  (with `Camera` / `Gimbal` labels) on the right. No
  standalone devices-panel row below the header any more.
- Tapping `Camera` / `Gimbal` icons in the header still opens the
  matching modal sheet (no functional change from PR 11).
- All connect / disconnect / placeholder behaviour from PR 11's
  verification matrix still works — this PR is purely visual.

**Implementation steps.** Two phases:

1. **Restructure the header.** Rebuild `lib/ui/header.dart` with
   the three regions and the bumped `preferredSize`. Move the
   state-mapping helpers + `DeviceButton` instantiations in from
   `devices_panel.dart`. Update `lib/main.dart`'s `MaterialApp.title`
   and the Android `android:label`. `PlaygroundScreen` still hosts
   the standalone `DevicesPanel` row at this phase — the device
   buttons appear twice (once in the header, once below it). Visual
   verification confirms the header looks right before phase 2
   removes the duplicate.
2. **Remove the old DevicesPanel.** Drop `const DevicesPanel()`
   from `playground_screen.dart`; `git rm lib/ui/devices_panel.dart`.
   Header is the sole devices surface.

**As built — additions beyond the original plan.** The header
rebrand shipped roughly as specced, but rapid on-device iteration
turned this into the larger app-shell restructure described below.
Final state:

- **Custom Sciens brand mark.** Instead of reusing the launcher
  PNG verbatim, a hand-crafted SVG (`assets/branding/sciens.svg` —
  a capital S in a rounded square border) is rendered via
  `flutter_svg` and tinted white via a `ColorFilter`.
  `flutter_svg: ^2.0.10` added to dependencies.
- **Launcher icon regenerated from the same mark.** A
  launcher-variant SVG (`assets/branding/launcher_icon.svg`) with
  a full-bleed `#263238` primary-blue background + the white S
  mark gets rasterised to PNG at the five mipmap densities
  (mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192) via
  `rsvg-convert`, overwriting the previous defaults. Home-screen
  icon and in-header mark now share a design.
- **`DeviceButton.light` variant (PR 11 widget extension).** The
  original button colours (primary-tinted for connected, dimmed
  onSurface for the others) were invisible against the header's
  `colorScheme.primary` background. Added an opt-in
  `light: true` flag that renders the three states in
  white-themed variants — solid white for connected, white-at-50 %
  for disconnected / connecting, white-at-60 % for labels, white
  spinner during connecting. The header passes `light: true`;
  default behaviour is preserved. Three new tests cover the light
  variant (eight total in `test/device_button_test.dart`).
- **Title size.** `Panoramique` shrunk from `titleLarge` to
  `titleMedium` (~16 sp) — the larger size felt over-weighted
  on-device.
- **App-shell layout shift — outer TabBar → bottom NavigationBar.**
  The original spec kept the device-selection `TabBar` directly
  below the header. On-device this stacked awkwardly with each
  device's inner sub-tabs. The final layout instead replaces the
  outer `TabBar` with a Material 3 `NavigationBar` at the bottom of
  the `Scaffold` (`bottomNavigationBar` slot), with two
  `NavigationDestination`s:
  - **Camera** — `Icons.camera_alt_outlined` / selected
    `Icons.camera_alt`.
  - **Gimbal** — `Icons.sports_esports_outlined` / selected
    `Icons.sports_esports`.
  The body is an `IndexedStack(index: _selectedIndex)` so both
  pages stay mounted (camera live preview + sub-tab selection
  survive device switching, no need for the
  `AutomaticKeepAliveClientMixin` plumbing the previous
  `TabBarView` relied on). Swipe between outer destinations is
  intentionally gone — bottom-nav destinations are tapped, not
  swiped. The top and bottom surfaces (inner `TabBar` vs bottom
  `NavigationBar`) are visually distinct M3 components, so the UI
  no longer reads as "two stacked tab bars".
- **Per-device sub-tabs and renames.** Each `NavigationDestination`
  body has its own top `TabBar`:
  - Camera body: **Capture** (the connected-camera UI, formerly
    "Camera") → **Virtual S5** (shown only while the Demo Lumix
    S5 is the connected camera; demo-only) → **Debug/Diagnostics**.
  - Gimbal body: **Control** (the 3D viz + pan/tilt/level
    controls, or the placeholder when disconnected; formerly
    "Gimbal") → **Logs** (the previously top-level `LogsTab`,
    now nested inside the gimbal destination so the bottom-nav
    isn't cluttered with a third destination).
- **Auto-switch destination on connect.** `PlaygroundScreen` now
  watches each connection provider via `ref.listen` and `setState`s
  `_selectedIndex` to the matching destination when a device
  transitions to Connected (disconnected/connecting → connected).
  Tapping a device icon in the header to connect → sheet
  auto-dismisses on success → user lands on that device's
  destination. Disconnecting does *not* change the active
  destination.
- **Camera-sheet double-pop bug fix.** The original
  `camera_sheet.dart` had a `_lastStatus`-driven belt-and-braces
  `addPostFrameCallback(maybePop)` alongside the explicit
  `Navigator.pop()` in `_connect()` — both fired on the same
  connect-success event, popping the sheet **and** the
  `PlaygroundScreen` underneath it (black screen). The
  `if (!mounted)` guard didn't save us because `mounted` only
  flips false after the pop animation completes. Fix: drop the
  belt-and-braces; `_connect()`'s direct pop is sufficient since
  the only path to Connected goes through this sheet.
- **Predictive-back fix.** Android's right-edge back gesture
  showed a black preview because `PlaygroundScreen.PopScope` was
  `canPop: false` and the eventual `Navigator.of(context).pop()`
  is a no-op at the root route. Swapped to `SystemNavigator.pop()`
  so the activity finishes (app goes to recents) when the
  cleanup completes — matches the Android "back at root → exit"
  UX expectation.

Tagline final wording (verbatim, lowercase): `old glass, wide
world`.

#### Sign-off

PR 6 (EV compensation), PR 7, PR 8, PR 9 and PR 11 (both the
original devices-panel wave and the Panoramique header /
app-shell restructure follow-up) have all landed and their
on-device verification checkpoints pass. One specified piece
remains before Phase 2 closes:

- **PR 10 — Capture delay + capture sounds** — the deferred PR 6
  single-shot self-timer, respec'd with audible cues.

Once PR 10 lands, Phase 2 is complete; next is Phase 3 (protocol
library extraction) or Phase 4 (panorama sequencer) — order
optional.

### Out of scope (Phase 2)

- Same-network mode (camera joins user's existing WiFi).
- Manual exposure mode switching (P/A/S/M selection — the dial on
  the camera body handles this).
- Video recording (`video_recstart` / `video_recstop`).
- Browsing the SD card / a photo library. PR 8 fetches only the
  *last* captured image over the ContentDirectory; a full card
  browser stays out of scope.
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

PR 5 and PR 6's EV-compensation have since landed and verified on
hardware. The PR 6 single-shot self-timer is now specified as
PR 10 (capture delay + capture sounds), pending implementation.

## Phase 3 — Gimbal motion library (extraction)

**Goal.** Lift the gimbal protocol *and* closed-loop motion logic out
of the Flutter-coupled `GimbalConnection` into a standalone, in-repo,
framework-free Dart package so Phase 4's sequencer can be built and
unit-tested without hardware and without Flutter widgets.

> **Spec correction.** The original outline said "promote
> `lib/protocol/`" — there is no such directory. The gimbal code today
> lives in `lib/ble/` (wire layer) and `lib/state/gimbal_connection.dart`
> (motion + UI state). This section supersedes that outline.

### What "framework-free package" means here

It does **not** mean "no Bluetooth". The package depends on the
**abstract `GimbalTransport`** interface (a pure byte channel:
`sendFrame`, `incoming` stream, `disconnected`, lifecycle phases) that
already exists at `lib/ble/transport/gimbal_transport.dart`. The
concrete `BleGimbalTransport` — the only thing that imports
`flutter_blue_plus` — **stays in the app** and is injected at runtime,
exactly as it is today via `connect(GimbalTransport)`. Bluetooth never
enters the package; it arrives through the interface.

The only genuinely framework-coupled aspects of `GimbalConnection`
today are that it `extends ChangeNotifier` and imports
`flutter_riverpod`. The extraction drops both: the package exposes
status as a **`Stream`** (current angles, follow-mode, move-in-progress,
errors), and the app keeps a thin riverpod/`ChangeNotifier` adapter
around it so the existing UI bindings are unchanged.

### Package shape — `packages/feiyu_gimbal/`

In-repo local package (path dependency in the app's `pubspec.yaml`),
**not** published to pub.dev. Same git history, same PRs.

Moves into the package (pure Dart, no `package:flutter`):

- The whole `lib/ble/` wire layer — `commands.dart`, `crc.dart`,
  `frame_codec.dart`.
- The `GimbalTransport` abstract interface and `DemoGimbalTransport`
  (already pure Dart).
- The motion / orientation logic currently tangled in
  `GimbalConnection`: `moveByAngle`, `levelHome`, `gotoAngle`
  (kept but still flagged speculative), `_runSinglePass`, stall
  detection, arrival-margin and coast-compensation constants, and the
  `_onFrame` orientation parser. Re-homed onto a plain `GimbalSession`
  (name TBD) class that takes a `GimbalTransport` and emits a status
  `Stream` — no `ChangeNotifier`, no `notifyListeners`.

Stays in the app:

- `BleGimbalTransport` (`flutter_blue_plus`).
- A thin `GimbalConnection` adapter: wraps `GimbalSession`, forwards
  the status `Stream` into `notifyListeners()`, preserves the current
  riverpod provider and every getter the UI reads (`yawDeg`,
  `pitchDeg`, `isConnected`, `moving`, `log`, …) so widgets don't
  change.

### Typed motion API the package exposes

Given the **relative-only** decision (Phase 4), the package does **not**
promise a working absolute goto. The contract is:

- `Future<MoveResult> moveByAngle({double courseDeg, double pitchDeg})`
  — the existing closed-loop relative move, but it now **returns a
  result** instead of only logging: final residual error per axis +
  whether it converged within tolerance. (Today it returns `void`;
  Phase 4 needs to know whether a tile move actually landed.)
- `Future<void> levelHome()` — unchanged closed-loop level-to-(0,0).
- `Stream<GimbalStatus> status` — angles, follow-mode, `moving`,
  errors.
- `gotoAngle(...)` — carried over but **kept marked speculative**;
  Phase 4 must not depend on it.

### PR breakdown

- **PR 12 — Create the package, move the wire layer.** New
  `packages/feiyu_gimbal/` with `commands`/`crc`/`frame_codec` +
  `GimbalTransport` + `DemoGimbalTransport`. App imports flip from
  `lib/ble/...` to `package:feiyu_gimbal/...`. No behaviour change.
  Existing wire-layer tests move with the code and stay green.
- **PR 13 — Extract `GimbalSession` (motion logic).** Move the motion
  + orientation logic onto the framework-free session class with a
  status `Stream`; reduce `GimbalConnection` to the adapter. Add
  `MoveResult` return to `moveByAngle`. **New unit tests** drive
  `GimbalSession` against `DemoGimbalTransport` (and/or a scripted
  fake) — convergence, residual reporting, stall/timeout, no-op
  guards — all with zero hardware and zero Flutter.

### Verification checkpoints (Phase 3)

- [ ] Real SCORP-C2: connect / pan / tilt / Level behave **identically**
      to pre-PR-12 (this is a refactor; the on-hardware feel is the
      regression test).
- [ ] Demo gimbal still connects and animates as before.
- [ ] `flutter analyze` clean; the app no longer imports anything from
      a `lib/ble/` path.
- [ ] New `GimbalSession` unit tests pass against a fake transport with
      no Flutter test binding.
- [ ] Camera tab, 3D visualization, devices panel — all unchanged
      (nothing outside the gimbal stack was touched).

### Risks & open questions (Phase 3)

- **Hidden `notifyListeners` coupling.** Some widgets may rely on the
  precise *timing* of `ChangeNotifier` rebuilds (e.g. mid-move
  repaints of the 3D view). The adapter must forward status-stream
  events synchronously enough to preserve that; verify the
  visualization still tracks live motion.
- **Log plumbing.** Motion code currently calls `appendLog(...)` on the
  `ChangeNotifier`. The package can't depend on the app's log model —
  `GimbalSession` should emit log lines onto its status/event stream
  and let the adapter fold them into the existing `LogEntry` list.
- **Test seam for closed-loop.** `_runSinglePass` uses real
  `Future.delayed` settle waits. For fast, deterministic unit tests we
  may want an injectable clock/delay; decide whether to add one in
  PR 13 or accept real-time waits in tests.

## Phase 4 — Panorama sequencer

The app's reason for existing: drive the gimbal through a Brenizer
grid and fire the shutter at each tile. Built **on top of Phase 3's
`feiyu_gimbal` package** (decision: extraction first).

### Decisions (confirmed in discussion, 2026-06-01)

- **Relative-only motion.** The sequencer never uses absolute goto. It
  steps **tile-to-tile by relative deltas** via
  `moveByAngle({courseDeg, pitchDeg})`. The speculative `gotoAngle`
  (wire cmd 93, not declared-supported on SCORP-C2) is not used. The
  demo transport already mirrors this — it simulates relative moves and
  silently ignores cmd 93.
- **Phase 3 first.** The sequencer is built against the extracted
  `GimbalSession` API, so the sequencer loop is unit-testable against a
  fake transport.
- **Grid math is a pure Dart module**, unit-tested with no hardware and
  no Flutter (`packages/feiyu_gimbal/` or a small `lib/panorama/`
  module — placement decided at impl time; it has no transport
  dependency either way).
- **Demo-first (hard gate).** The full sequence must run end-to-end
  against the demo gimbal + virtual Lumix S5 (PR 9) before pointing at
  real glass.
- **Placement — a 'Pano' sub-tab inside the Camera tab** (alongside
  Capture / [Virtual S5] / Debug-Diagnostics in the existing nested
  `TabBar` at `lib/ui/tabs/camera_tab.dart`). This **supersedes the
  earlier "dedicated screen" decision**. Rationale: panorama capture
  belongs conceptually with the camera, and the sub-tab scaffolding
  already exists.
- **Two focal inputs (Brenizer).** A *stitched-image focal* — the FOV
  the finished panorama should cover, which sets the **total span** —
  and a *taking-lens focal* — the lens actually mounted, which sets
  **one tile's FOV** — plus overlap. This is exactly what the two-focal
  grid math needs; the single-focal idea from the first sketch can't
  yield a tile count on its own.
- **First-sweep progress = coloured cells.** For the first
  implementation the tile grid is a schematic of cells; as the run
  proceeds each *captured* tile's cell is recoloured. No per-tile
  thumbnail fetch and no demo-asset tiling yet — **this supersedes the
  earlier per-tile thumbnail / contact-sheet decision** for the first
  sweep (kept as a later enhancement; see "Deferred").

### Grid math (pure module)

Sensor model: full-frame 36×24 mm → half-extents 18 mm × 12 mm. *(The
original outline used 17.5 mm half-width; impl uses the true 18 mm
unless a measured value supersedes it.)*

Inputs: `focalStitch` mm (*stitched-image focal* — the FOV the finished
panorama covers; sets total span), `focalTaking` mm (*taking-lens
focal* — the mounted lens; sets one tile's FOV), `overlap` fraction
0–0.9 (default 0.30), `centreYaw`, `centrePitch` degrees (the gimbal's
current orientation, snapshotted when "Take panorama" is pressed).

Slider ranges / defaults (confirmed 2026-06-01): taking-lens focal
**50–150 mm**, default **50 mm**; stitched-image focal **24–100 mm**,
default **24 mm**; with the constraint `focalStitch ≤ focalTaking`
(otherwise the grid collapses to 1×1).

```
H_span   = 2·atan(halfW / focalStitch)       // total horizontal extent to cover
V_span   = 2·atan(halfH / focalStitch)       // total vertical extent
tile_h   = 2·atan(halfW / focalTaking)       // one tile's horizontal FOV
tile_v   = 2·atan(halfH / focalTaking)
step_h   = tile_h · (1 − overlap)            // centre-to-centre spacing
step_v   = tile_v · (1 − overlap)
n_cols   = ceil(H_span / step_h) + 1
n_rows   = ceil(V_span / step_v) + 1
```

Grid is **symmetric** around `(centreYaw, centrePitch)`: column `i`
(0…n_cols−1) sits at `centreYaw + (i − (n_cols−1)/2)·step_h`, similarly
for rows. Output: a `List<TilePosition{yaw, pitch, row, col}>` plus
summary `{nCols, nRows, totalShots, hSpanDeg, vSpanDeg, estDuration}`.

Edge cases the module must handle: `focalTaking ≤ focalStitch` (tiles
wider than the span → 1×1 grid, not negative counts); `overlap` clamp;
`focal ≤ 0` guard; very large grids (cap + warn — see risks).

### Sequencer state machine

States: `idle → running → (paused?) → done | cancelled | aborted`.
The serpentine order (boustrophedon: row 0 left→right, row 1
right→left, …) minimises total travel and avoids a long yaw sweep-back
between rows.

Per tile, **relative** stepping (we hold the planned absolute grid but
issue the *delta from where we are*):

1. Compute `(dYaw, dPitch)` = planned tile abs − last-commanded abs.
2. `result = await session.moveByAngle(courseDeg: dYaw, pitchDeg: dPitch)`.
3. If `result` residual exceeds the **per-tile tolerance (default 2°)**
   → log a per-tile warning and continue (best-effort). No retry, no
   abort, for now.
4. **Settle delay** (let vibration die before exposure) — distinct from
   PR 10's *capture delay* (see interaction note).
5. **Capture.** Fire *without* the PR 10 countdown/sound overlay per
   tile (immediate path). On a successful return, **recolour that
   tile's cell** in the grid to mark it taken. First sweep pulls back
   **no image** per tile — the full-resolution stills stay on the
   camera's SD card for later stitching. (Per-tile thumbnails into the
   cell are a later enhancement; see "Deferred".)
6. **Inter-shot delay** before the next move.

The sequencer tracks **commanded absolute** position, not measured, to
accumulate the grid; but each move's *delta* is recomputed from the
session's **measured** current angle so closed-loop residual error
doesn't compound across the grid.

### UI — the 'Pano' sub-tab

A fourth sub-tab **'Pano'** inside the Camera tab — the nested `TabBar`
(`lib/ui/tabs/camera_tab.dart`) already hosts Capture / [Virtual S5] /
Debug-Diagnostics. Its body holds:

- **Taking-lens focal** input (slider, 50–150 mm, default 50).
- **Stitched-image focal** input (slider, 24–100 mm, default 24).
- **Overlap** slider (0–90 %, default 30 %).
- **Settle delay** input (seconds, default **3 s**) — the wait after
  each gimbal movement stops, before the shutter fires (see "Settle
  delay" below).
- **Live tile grid**: a schematic of `n_cols × n_rows` cells, redrawn
  whenever a focal or overlap value changes, with the computed **tile
  count** shown. (Span / estimated-duration readouts are optional for
  the first sweep.)
- **"Take panorama"** button — snapshots the gimbal's current
  orientation as the grid centre and starts the sequencer. Enabled only
  when both gimbal and camera are connected.
- **Cancel** button — stops a run in progress.

During a run the same grid doubles as the progress view: each captured
tile's cell is recoloured. No separate progress screen for the first
sweep. **Abort on disconnect**: if either the gimbal or the camera
drops mid-run, stop immediately, surface why, and leave the gimbal where
it is (no auto-return).

There is **no explicit "Read Framing" button** in the first sweep —
"Take panorama" uses the current gimbal orientation as the centre. (A
separate compose-then-confirm read-framing step can return later if
useful.)

### Settle delay vs. PR 10 capture delay

Two independent delays, must not be conflated:

- **PR 10 capture delay** — a user-facing self-timer with countdown UI
  + beeps, for single hand-off shots. **Not used per-tile** in a
  panorama (no countdown spam across dozens of tiles).
- **Phase 4 settle delay** — a **user-facing field in the Pano sub-tab
  (seconds, default 3 s)**: the wait after each gimbal movement stops
  and before the shutter fires, so mechanical settling doesn't smear the
  frame.

### Capture path reuse

`CameraConnection.captureWithDelay(int)` returns `Future<String?>`
(null = success). For panorama tiles the first sweep uses the fire-now
path **without** the PR 10 overlay/sound and **without** any
post-capture image fetch (neither PR 8's full-LRG fetch nor a
thumbnail) — the cell is simply recoloured on a null return. This likely
needs a thin "capture-only, no fetch" entry point on `CameraConnection`,
decided at impl time. Each tile checks the returned error string and
applies the per-tile policy above (log + continue, 2° tolerance, no
retry for now).

### Run lifecycle, preconditions & completion

A *complete* run needs more than the per-tile loop:

- **Where it lives.** The sequencer is a **riverpod-hosted controller**
  (like `GimbalConnection` / `CameraConnection`), not Pano-sub-tab
  widget state — so a run survives the user switching sub-tabs or to the
  Gimbal top-tab, and the grid/progress rebinds on return.
- **Preconditions to start.** Both gimbal and camera connected; camera
  in **record mode** (not playback — `recMode`); grid at least 1×1.
  "Take panorama" is disabled otherwise.
- **Lock-out during a run.** Manual gimbal control (Gimbal-tab pan /
  tilt / Level) and the Pano inputs (focals, overlap, settle delay) are
  **disabled** while a run is active; only Cancel stays live. Prevents a
  manual `moveByAngle` colliding with the sequencer (`moveByAngle` is a
  no-op while already `_moving`, but the planned grid would desync).
- **Live preview.** If the Capture sub-tab's MJPEG preview is running,
  the sequencer **stops it for the duration** (preview stream +
  keep-alive vs. rapid stills capture shouldn't compete); no need to
  restore it afterward.
- **Per-tile completion (decided).** `capture()` returns when the camera
  *acknowledges* the command — **not** when the exposure and SD-write
  finish. Moving the gimbal too soon smears a long exposure (likely with
  stopped-down vintage glass). After firing, the sequencer **waits for
  the camera's `sdAccess`/`isBusy` flag to go busy→idle** (with a fixed
  minimum floor, in case the busy window is too brief to observe at the
  poll rate) before the next move. Requires camera-state polling active
  during the run.
- **On completion / cancel / abort (decided).** On **clean completion**
  the gimbal **returns to the captured centre**; **Cancel** stops after
  the current tile and likewise returns to centre (the link is alive).
  **Disconnect** mid-run aborts and leaves the gimbal where it is — a
  dropped link can't be driven home.

### PR breakdown (later)

- **PR 14 — Grid math module + tests.** Pure Dart, no UI, no transport.
  Full unit-test table across focal/overlap combinations and edge
  cases. No user-visible change yet.
- **PR 15 — 'Pano' sub-tab (inputs + live tile grid).** Add the sub-tab
  to the Camera `TabBar`; the two focal sliders + overlap drive PR 14's
  math; the cell grid + tile count redraw live. No motion, no capture.
- **PR 16 — Sequencer (motion + capture + progress + cancel + abort).**
  A **riverpod-hosted `PanoramaController`** running the state machine on
  top of `GimbalSession.moveByAngle` (needs PR 13's `MoveResult`) and a
  new **capture-only, no-fetch** entry point on `CameraConnection`.
  "Take panorama" snapshots centre and runs the serpentine grid with the
  settle delay + per-tile exposure-completion wait; captured cells
  recolour; manual gimbal control + Pano inputs lock out; live preview
  stops for the duration; Cancel + abort-on-disconnect. Unit-tested
  against fake transport + demo camera; verified end-to-end on demo,
  then on hardware.

Prerequisite: **PR 13** (the `GimbalSession` extraction + `MoveResult`
return) lands before PR 16. PR 14 / PR 15 have no Phase-3 dependency and
can proceed in parallel.

### Verification checkpoints (Phase 4)

- [ ] Grid math unit tests: known focal/overlap inputs produce expected
      `n_cols`/`n_rows`/positions; symmetric around centre; degenerate
      inputs (taking ≤ stitched focal, overlap extremes) don't explode.
- [ ] Live tile grid: changing either focal or overlap redraws the cell
      grid and updates the tile count immediately.
- [ ] Demo end-to-end: connect demo gimbal + virtual Lumix → press
      **Take panorama** → gimbal animates through the serpentine grid,
      camera "fires" at each tile, the tile's cell recolours, run reaches
      `done`.
- [ ] Cancel mid-run stops promptly; no further moves or captures.
- [ ] Disconnect mid-run (gimbal or camera) → `aborted` with a clear
      reason; app stays responsive.
- [ ] Hardware: a real small grid (e.g. 3×3) on the SCORP-C2 + S5 lands
      tiles with visible overlap; residual error doesn't compound across
      the grid (closed-loop delta-from-measured holds).
- [ ] Settle delay actually reduces motion blur vs. zero-settle (bench
      observation).

### Risks & open questions (Phase 4)

- **`moveByAngle` convergence reporting.** Phase 3 must land the
  `MoveResult` return first (PR 13); the sequencer's per-tile
  best-effort/abort policy depends on it.
- **Capture-only path.** PR 10's overlay and PR 8's full-LRG fetch are
  both undesirable per-tile. Need a lean "capture-only, no fetch" entry
  point; confirm the S5 can fire fast enough back-to-back to keep the
  run brisk.
- **Camera-state polling during a run.** The per-tile completion wait
  relies on `sdAccess`/`isBusy`, so camera-state polling must run for the
  duration even though the capture path fetches nothing. Confirm the poll
  cadence reliably observes the busy window for fast shutter speeds (the
  fixed minimum floor is the backstop when it doesn't).
- **Yaw wrap / large pans.** A wide stitched-image focal + long taking
  lens can produce a big `n_cols`; cap total shots with a warning rather
  than silently launching a 200-shot run. Also confirm `_angleDiff`
  wrap-around behaves for yaw deltas crossing ±180°.
- **Pitch limits & coast compensation.** `moveByAngle` pre-subtracts a
  1° pitch coast and skips sub-1° pitch moves — a fine grid with
  `step_v < 1°` would drop every pitch step. The sequencer must account
  for the coast-compensation floor (and the gimbal's mechanical pitch
  range) when validating a grid.
### Deferred (later enhancements, not in the first sweep)

- **Per-tile thumbnails into the grid cells** (a true contact sheet),
  which would also require the demo Lumix to **tile its bundled asset
  in memory** so the demo mosaic is real rather than the same frame N
  times. Dropped from the first sweep in favour of coloured-cell
  progress.
- **Explicit Read-Framing / compose-then-confirm** step (centre is the
  current orientation at "Take panorama" time for now).
- **Span / estimated-duration readouts** in the Pano sub-tab (tile
  count only, for now).

## Phase 5 — Hand-off to a separate image-viewer app (outline)

A separate Android app — working title `panoramique_viewer`,
`applicationId` TBD, language/framework TBD — is the destination
when the user **double-taps a captured image** in Panoramique. The
receiver provides viewing now and image processing later;
Panoramique itself only owns the hand-off contract.

This phase **modifies PR 8's double-tap behavior**: instead of
opening the in-app full-screen `InteractiveViewer`, the double-tap
launches the viewer app and passes the captured JPEG by URI.

### Decisions (confirmed in discussion)

- **The viewer is a separate APK.** Not an additional Activity
  inside Panoramique. Decided so the image-processing surface can
  evolve independently and be installed in isolation.
- **Read-only hand-off for now.** No write-back to Panoramique. The
  viewer may save its own outputs to its own storage; Panoramique
  does not consume anything from the viewer.
- **The source image lives in Panoramique's private storage** —
  not in `MediaStore` / the public gallery. PR 8 already pulls the
  LRG JPEG from the camera's UPnP server; the bytes need to be
  written to disk in Panoramique's `cacheDir` (or `filesDir`) so
  that a `FileProvider` can hand out a `content://` URI to them. If
  a later phase publishes captures into the public gallery, the
  contract simplifies to a plain `MediaStore` URI with no other
  change.
- **Intent shape: custom action string** —
  `at.sciens.gimbal_controller.action.OPEN_FULL` (namespaced under
  the existing `applicationId`, which PR 11 froze at
  `at.sciens.gimbal_controller`). The viewer declares an
  `<intent-filter>` for exactly that action, so no `ACTION_VIEW`
  chooser dialog is shown. On `ActivityNotFoundException` (viewer
  not installed) Panoramique falls back to the PR 8 in-app
  full-screen route — feature still works without the viewer
  present.
- **Payload is a `content://` URI**, never the bitmap bytes. Passed
  via `Intent.setDataAndType(uri, "image/jpeg")` +
  `FLAG_GRANT_READ_URI_PERMISSION` so the viewer's process can
  `openInputStream(uri)` across the app boundary without copying
  through the Binder IPC limit (~1 MB).
- **Viewer chooses its own decode resolution.** Panoramique forwards
  the original LRG JPEG by URI; the viewer decodes at whatever size
  it wants (`BitmapFactory.Options.inSampleSize` or equivalent). No
  pre-downscaled "medium" variant is sent — Panoramique already
  caches SM + LRG locally from PR 8, but only the LRG URI is
  forwarded so the viewer is in charge of its memory budget.

### Panoramique side — what changes from PR 8

Files / artifacts added:

- `android/app/src/main/AndroidManifest.xml` — a `<provider>` entry
  for `androidx.core.content.FileProvider`, authority
  `at.sciens.gimbal_controller.fileprovider`, pointing at:
- `android/app/src/main/res/xml/file_paths.xml` — a small whitelist
  exposing the directory where PR 8's cached JPEGs are written
  (`cache-path name="captured" path="."` or similar; final dir name
  decided at impl time).
- `android/app/src/main/java/at/sciens/gimbal_controller/ImageHandoffChannel.java`
  — a `MethodChannel` named
  `at.sciens.gimbal_controller/image_handoff` (following the
  existing `WifiNetworkChannel` / `NsdChannel` pattern) exposing
  one method, `openFullSize(filePath)`:
  1. Wrap the path in a `File`.
  2. `Uri uri = FileProvider.getUriForFile(context,
     "at.sciens.gimbal_controller.fileprovider", file);`
  3. `Intent intent = new Intent("at.sciens.gimbal_controller.action.OPEN_FULL");`
     `intent.setDataAndType(uri, "image/jpeg");`
     `intent.addFlags(FLAG_GRANT_READ_URI_PERMISSION | FLAG_ACTIVITY_NEW_TASK);`
  4. `try { context.startActivity(intent); return true; } catch
     (ActivityNotFoundException e) { return false; }`

Edits to existing code:

- `lib/camera/lumix_content.dart` (or wherever PR 8 currently
  decodes the LRG JPEG): **also persist the bytes to a cache file**
  inside the directory whitelisted by `file_paths.xml`. PR 8 today
  keeps the LRG bytes in memory for `decodeJpeg`; Phase 5 needs a
  real file path because `FileProvider` serves on-disk content
  only. A single overwriting filename (`last_capture.jpg`) is
  sufficient — scope is the last shot, just like PR 8.
- `lib/ui/tabs/camera_tab.dart` — the double-tap handler in
  `_CameraPane` calls `ImageHandoffChannel.openFullSize(path)`. If
  the channel returns `false`, fall through to the existing PR 8
  push of `_FullScreenImage`. `_FullScreenImage` is **kept** as the
  graceful-degradation path, not deleted.
- `MainActivity.java` — register `ImageHandoffChannel` alongside
  the existing `WifiNetworkChannel` and `NsdChannel` in
  `configureFlutterEngine`.

Demo Lumix path (PR 9): the synthetic captured image must exist on
disk for `FileProvider` to serve it. PR 9 currently bundles it as an
asset; the hand-off path writes the asset bytes out to the same
cache directory at "capture" time so the same `openFullSize(path)`
call works in demo mode.

### Viewer app — minimum receiving contract

Whatever framework that app uses, it must declare an Activity
matching the hand-off action. In native-Android form:

```xml
<activity android:name=".ViewerActivity" android:exported="true">
  <intent-filter>
    <action android:name="at.sciens.gimbal_controller.action.OPEN_FULL"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <data android:mimeType="image/jpeg"/>
  </intent-filter>
</activity>
```

In `onCreate`, the activity reads `intent.getData()` (a
`content://` URI) and opens an `InputStream` via
`getContentResolver().openInputStream(uri)`. The read permission
granted by Panoramique stays valid for the lifetime of that
activity instance.

The viewer app's own scope — UI, decode strategy, processing
primitives, persistence, whether write-back to Panoramique ever
gets added — lives in **its own SPEC document** when that project
starts. This section only captures the contract Panoramique
relies on.

### Verification checkpoints (Phase 5)

- [ ] Capture an image in Panoramique → double-tap the still in the
      pane → the viewer app launches and shows the image in its own
      UI within ~1 s.
- [ ] With the viewer **not installed**: same double-tap →
      Panoramique falls back to the PR 8 in-app `_FullScreenImage`
      route; no crash, no error toast.
- [ ] The viewer can decode and display the image at its chosen
      resolution. It does **not** receive pixel bytes through intent
      extras — the URI grant is its only handle.
- [ ] Demo Lumix S5 path (PR 9): same hand-off works against the
      synthetic captured image (asset materialised to the cache dir
      at "capture" time).
- [ ] Killing the viewer app and re-double-tapping in Panoramique
      re-launches it with a fresh URI grant; old grants do not need
      to remain valid.
- [ ] Concurrent sessions: hand-off does not perturb the gimbal or
      camera connection — both stay connected through the
      Activity-switch.

### Risks & open questions

- **PR 8 currently keeps the LRG JPEG in memory only.** Confirm at
  impl time whether `lumix_content.dart` already touches disk; if
  not, the cache-write is real new work (small, but non-zero) and
  must be done in the same dir that `file_paths.xml` whitelists.
- **`FileProvider` requires androidx.core in the Android source
  set.** Already pulled in transitively by Flutter; verify on
  `flutter build apk --debug` after adding the provider.
- **Activity re-launch behaviour.** Without `FLAG_ACTIVITY_NEW_TASK`
  on a non-Activity context the launch fails on some Android
  versions; including it from the start. Whether the viewer
  uses `singleTask` / `singleTop` / default `standard` launch mode
  is the viewer's choice and not Panoramique's concern.
- **Custom action string discoverability.** Tools like the system
  share-sheet won't surface our action — that's intentional. The
  viewer is reached only through Panoramique's deliberate launch.

### Out of scope (Phase 5)

- Write-back from the viewer to Panoramique.
- Multi-image hand-off (sending a whole panorama batch in one go).
- A picker UI to choose between the in-app PR-8 viewer and the
  external viewer — the external viewer wins when installed; the
  in-app one is a fallback, not a presented option.
- The viewer app's own internals; specified separately when that
  project starts.
- iOS / desktop / web targets (still excluded).

## Out of scope (entire project)

- iOS / desktop / web targets.
- Camera-side control over PTP/MTP or USB tether — we use the
  camera's WiFi remote-control interface (Phase 2) and the gimbal's
  shutter cable.
- Image stitching — done in PTGui / Hugin / Lightroom after capture.
- Firmware updates to the gimbal.
- Redistribution of any decompiled or derived code.
