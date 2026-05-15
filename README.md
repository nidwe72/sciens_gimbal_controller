# Sciens Gimbal Controller

*old glass goes digital*

A custom Flutter Android app that talks directly to the
**Feiyu SCORP C2** gimbal over BLE. The eventual goal is a small,
focused tool for **Brenizer-style panoramas with vintage long-focal
lenses** — a workflow the stock app doesn't comfortably support.

Status: Phases 0 and 1 complete (BLE connect, motion primitives, demo
mode, 3D pose visualization). Phase 2 (panorama sequencer) is next.

![status: pre-alpha](https://img.shields.io/badge/status-pre--alpha-orange)
![platform: Android](https://img.shields.io/badge/platform-Android-3DDC84)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)

## What's in here

A two-screen Flutter app:

1. **Connect** — scans for nearby BLE devices, lists them; a synthetic
   *Demo Gimbal* entry is always at the top of the list so the app is
   usable without hardware (showcases, emulators, dev iteration).
2. **Playground** — once connected (real or demo), shows:
   - A sticky connection summary (device name, MAC, MTU, Disconnect)
   - **pan/tilt/roll tab** — a live 3D pose visualization (wireframe
     sphere + abstract camera body + RGB axis triad), the yaw/pitch/roll
     readouts, and Pan ± / Tilt ± / Level buttons.
   - **logs tab** — the AK-protocol frame log (TX + RX) with hex
     decoding, Clear/Copy, and an RX-visibility filter chip.

Both connection paths use the same UI: the demo entry plugs in at the
**transport layer**, so everything from the AK frame codec upward —
encoders, parsers, the closed-loop motion controller, iterative
leveling — runs unchanged.

## Hardware

| Component | Notes |
|---|---|
| Gimbal | Feiyu SCORP C2 (firmware as shipped, family `FY_SCORP_*`) |
| Camera body | Anything you can mount and trigger from the gimbal's shutter cable. Tested with a Panasonic Lumix S5. |
| Phone | Android 13+ with BLE. Wider testing TBD. |
| Camera ↔ gimbal | Wired shutter cable into the gimbal's remote port — the app issues `TAKE_PHOTO` to the gimbal, which clicks the cable. No camera-side protocol work. |

iOS, desktop, and web targets are out of scope.

## Quick start

Standard Flutter Android workflow.

### Build a debug APK

```bash
flutter pub get
flutter build apk --debug
# Output: build/app/outputs/flutter-apk/app-debug.apk
```

Sideload onto your phone (any file manager with "install from unknown
sources"), or use `adb install`.

### Run on an emulator (no gimbal required)

The Demo Gimbal entry works without BLE, so any emulator is enough to
develop and demo against.

Two helper scripts are bundled:

```bash
# Waydroid (Wayland Linux Android container — lightweight, requires a
# Wayland session). See scripts/README-waydroid.md for one-time setup.
./scripts/waydroid-run.sh

# Genymotion Desktop (VirtualBox-backed, works on X11):
./scripts/genymotion-run.sh
```

Both rebuild the APK, install it (replacing any prior version), and
launch the app. Pass `--no-build` to skip the rebuild if the APK is
already current.

### Run the unit tests

```bash
flutter test
```

25 tests covering the AK frame codec and the demo gimbal transport's
behaviour (motion integration, pitch coast simulation, GIMBAL_STATE byte
layout, idle pump cadence, disconnect cleanup, …).

## How the demo gimbal works

The synthetic **Demo Gimbal** entry on the Connect screen wires
`GimbalConnection` to a `DemoGimbalTransport` instead of the BLE one.
Each lifecycle phase (open / MTU / discover / subscribe) is a brief
artificial delay so the status messages flick by like a real connect,
then a 10 Hz pump emits real-format `GIMBAL_STATE` frames at the same
cadence the real device pushes.

The demo speaks the **AK protocol byte-for-byte**, so:

- The `frame_codec.dart` encoder / decoder still runs.
- The same `FrameStreamDecoder` parses the demo's pushes.
- The same closed-loop joystick controller drives motion (with stall
  detection, iterative leveling, pitch coast compensation).
- The same TX / RX log entries appear, indistinguishable from those of
  a real connection.

Motion is paced at `(|speed| / 60) × 8 °/s` to match the measured
real-device average. The real device's 1° pitch overshoot is simulated
too, so the existing app-side coast compensation lands at the
user-intended angle in both modes.

## Project layout

```
lib/
├── ble/
│   ├── crc.dart                          CRC-16 / XMODEM
│   ├── frame_codec.dart                  AK protocol encoder + streaming decoder
│   ├── commands.dart                     Typed command builders (joystick, use-mode, …)
│   └── transport/
│       ├── gimbal_transport.dart         Abstract transport interface
│       ├── ble_gimbal_transport.dart     Real implementation (flutter_blue_plus)
│       └── demo_gimbal_transport.dart    Software-only simulator
├── state/
│   └── gimbal_connection.dart            Connection state + closed-loop motion controller
└── ui/
    ├── header.dart                       Shared app header
    ├── connect_screen.dart               Device scan + tap-to-connect
    ├── device_row.dart                   Sealed scan-result wrapper (scanned vs demo)
    ├── playground_screen.dart            Sticky connection summary + tab host
    ├── tabs/
    │   ├── controls_tab.dart             3D visualization + controls
    │   └── logs_tab.dart                 Log view tab
    ├── log_view.dart                     TX/RX frame log
    └── gimbal_visualization.dart         CustomPainter 3D pose view
test/
├── frame_codec_test.dart                 Codec round-trip + decoder robustness
└── demo_gimbal_transport_test.dart       Demo lifecycle + motion + coast + protocol parity
scripts/
├── waydroid-run.sh                       Build + install + launch on Waydroid
├── genymotion-run.sh                     Build + install + launch on Genymotion
└── README-waydroid.md                    One-time Waydroid setup
```

## Roadmap

- ✅ **Phase 0** — connect, discover services, parse `GIMBAL_STATE`,
  closed-loop pan/tilt/level over BLE.
- ✅ **Phase 1** — demo gimbal transport, 3D pose visualization, tab
  restructure (pan/tilt/roll + logs).
- ⏳ **Phase 1.5** — `TAKE_PHOTO` (cmdId 63) shutter command exposed in
  the UI.
- ⏳ **Phase 2** — Brenizer panorama sequencer. Frame composition with a
  wide reference lens, capture with a long lens, automated grid shoot.
- 🔮 **Phase 3** — Promote `lib/ble/` + `lib/state/` into a standalone
  Dart package for reuse / unit testing in isolation.

## Tech

- Flutter 3 / Dart 3 (sealed classes, switch patterns)
- `flutter_blue_plus` — BLE
- `flutter_riverpod` — state
- `permission_handler` — runtime BLE permissions
- `vector_math` — 3D math for the pose visualization
- `fake_async` — deterministic timer tests
- Pure-Dart `CustomPainter` for the 3D scene (no extra renderer)

## Status & honest caveats

- Pre-alpha. APIs and on-screen flows will change.
- SCORP C2 only. Other Feiyu gimbals likely need protocol tweaks
  (different `useMode` mappings, possibly an `absoluteRotate` path).
- The Demo Gimbal is for development and showcases — it cannot
  reproduce camera-side effects or real-world reliability problems.
- Verification on the actual gimbal is a manual step per change; CI
  covers only protocol-level and demo behaviour.

## Why "Sciens"?

A working title — Latin *sciens* = "knowing, skilled". Treat as a
placeholder; the name may change before any release.
