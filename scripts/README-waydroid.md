# Running the app on Waydroid (Wayland Linux Android container)

Waydroid runs the Android system inside a Linux container, displayed in
a Wayland window. Much lighter than Android Studio's AVD (~700 MB
download vs. ~10 GB), boots in seconds, and integrates with your
Wayland session.

Since the SCORP C2 demo gimbal entry (Phase 1 of the spec) doesn't
need a real BLE radio, the whole app is fully usable in Waydroid —
scan, tap "Demo Gimbal", play with pan/tilt/level, watch the 3D
visualization.

## One-time prerequisites

### 1. Wayland session

Confirm you're on Wayland:

```
echo $XDG_SESSION_TYPE
# should print: wayland
```

If it prints `x11`, log out and pick "Ubuntu on Wayland" (or your
distro's equivalent) on the login screen.

### 2. Kernel binder modules

Waydroid uses the Android `binder` IPC. On Ubuntu 22.04 with the stock
5.15 kernel, the modules ship with `linux-modules-extra`:

```
sudo apt install linux-modules-extra-$(uname -r)
sudo modprobe binder_linux num_binderfs_devices=1 || true
```

Most setups auto-load it; check with `lsmod | grep binder`.

### 3. Install Waydroid

Ubuntu 22.04:

```
sudo apt install -y curl ca-certificates
curl -s https://repo.waydro.id | sudo bash
sudo apt install -y waydroid
```

The first command adds the official Waydroid APT repo.

### 4. Initialize the Android image

```
sudo waydroid init
```

Downloads the system image (~700 MB) and the vendor image (~80 MB).
First time only.

### 5. Enable the container service

```
sudo systemctl enable --now waydroid-container
```

This starts the privileged container that runs the Android kernel
side. Keep it running across reboots.

## Daily use

### Start a session (one terminal)

A "session" is the user-facing side of Waydroid — it runs the Android
launcher and apps. Start it after the container service is up:

```
waydroid session start
```

Leaves a process running; close with Ctrl-C or `waydroid session stop`.

### Open the visible window

Separate terminal:

```
waydroid show-full-ui
```

This opens the Wayland window that displays Android. Close the window
to hide it (session keeps running and apps stay alive).

### Build + install + launch (one-shot)

```
./scripts/waydroid-run.sh
```

What it does:

1. `flutter build apk --debug`
2. Checks the Waydroid session is RUNNING; starts it if not
3. `waydroid app install build/app/outputs/flutter-apk/app-debug.apk`
4. `waydroid app launch at.sciens.gimbal_controller`

Flags:

- `--no-build` — skip the Flutter build, use the existing APK
- `--show-ui` — also pop the Waydroid window after launching

### After a code change

```
./scripts/waydroid-run.sh
```

Same command — APK is rebuilt, installed (overwriting), relaunched.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `waydroid: command not found` | Repo wasn't added; re-run the `curl ... \| sudo bash` step |
| `init` fails on kernel-module errors | `linux-modules-extra-$(uname -r)` not installed, or you're not on Wayland |
| Session stuck at `STOPPED` even after `session start` | `sudo systemctl restart waydroid-container`, then `waydroid session start` again |
| App installs but white screen | Wait 5–10 s — Android startup is slow on first boot after install |
| BLE scan stays empty | Expected — emulator has no BLE radio. Use the **Demo Gimbal** entry at the top of the device list |
| Window doesn't open on `show-full-ui` | Container service isn't running: `sudo systemctl status waydroid-container` |

## What's NOT going to work in the emulator

- Scanning for the real SCORP C2 over BLE — no radio.
- Anything camera-side (we don't trigger the camera over the demo
  transport).
- Real-device performance characteristics — Android-in-a-container is
  generally responsive but not bit-for-bit identical to a phone.

## When to use the real phone instead

Once you want to confirm:

- Real BLE connect / disconnect handling.
- Wire-protocol parity between demo bytes and real-gimbal bytes.
- Touch responsiveness and panel sizing on the actual device.
- Battery / connection stability over a long session.

The emulator gets you 80 % of the dev loop; the phone gets you the
final 20 %.
