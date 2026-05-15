#!/usr/bin/env bash
#
# Build the debug APK and install + launch it on Waydroid (the Wayland
# Linux Android container). Designed for the dev loop: tweak code →
# run this → click around in the Waydroid window.
#
# Prereqs (one-time, see scripts/README-waydroid.md for details):
#   1. sudo apt install waydroid
#   2. sudo waydroid init                # downloads ~700 MB Android image
#   3. sudo systemctl enable --now waydroid-container
#
# Run-time prereqs (each session):
#   - Waydroid container service running (the one started in step 3)
#   - A Wayland session for the user (check `echo $XDG_SESSION_TYPE`)
#   - The Waydroid session itself is started lazily by this script

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APK_REL="build/app/outputs/flutter-apk/app-debug.apk"
APK="$PROJECT_DIR/$APK_REL"
PKG="at.sciens.gimbal_controller"

# Parse args.
DO_BUILD=1
SHOW_UI=0
for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --show-ui)  SHOW_UI=1 ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--no-build] [--show-ui]

  --no-build   Skip 'flutter build apk --debug' (use the existing APK).
  --show-ui    Also open the Waydroid full-UI window after launching.
               (You can run 'waydroid show-full-ui' yourself any time.)
EOF
      exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# -------------------------------------------------------------- preflight

if ! command -v waydroid >/dev/null; then
  echo "ERROR: 'waydroid' is not installed. See scripts/README-waydroid.md." >&2
  exit 1
fi

if [ "$DO_BUILD" -eq 1 ]; then
  echo "[1/4] Building debug APK..."
  cd "$PROJECT_DIR"
  flutter build apk --debug
else
  echo "[1/4] Skipping build (--no-build)."
fi

if [ ! -f "$APK" ]; then
  echo "ERROR: APK not found at $APK_REL — run without --no-build first." >&2
  exit 1
fi

# ------------------------------------------------------- waydroid session

# `waydroid status` exits 0 even if the session isn't running, so we
# have to scrape its output.
echo "[2/4] Checking Waydroid session..."
session_state="$(waydroid status 2>/dev/null | awk -F: '/^Session:/ {gsub(/^ +/,"",$2); print $2}')"
case "$session_state" in
  "RUNNING")
    echo "    Session: RUNNING."
    ;;
  "")
    echo "ERROR: 'waydroid status' returned no session info." >&2
    echo "Check that the container service is up:" >&2
    echo "    sudo systemctl status waydroid-container" >&2
    exit 1 ;;
  *)
    echo "    Session: $session_state — starting it (background)."
    setsid -f waydroid session start </dev/null >/dev/null 2>&1
    # Wait up to ~30 s for boot.
    for i in $(seq 1 30); do
      sleep 1
      if [ "$(waydroid status 2>/dev/null | awk -F: '/^Session:/ {gsub(/^ +/,"",$2); print $2}')" = "RUNNING" ]; then
        echo "    Session: RUNNING (after ${i}s)."
        break
      fi
      if [ "$i" -eq 30 ]; then
        echo "ERROR: Waydroid session did not reach RUNNING within 30s." >&2
        exit 1
      fi
    done
    ;;
esac

# ----------------------------------------------------------- install + run

echo "[3/4] Installing $APK_REL..."
waydroid app install "$APK"

echo "[4/4] Launching $PKG..."
waydroid app launch "$PKG"

if [ "$SHOW_UI" -eq 1 ]; then
  echo "Opening Waydroid full-UI window..."
  setsid -f waydroid show-full-ui </dev/null >/dev/null 2>&1
fi

cat <<EOF

Done. If no window appeared, run in another terminal:
    waydroid show-full-ui

Inside the app, tap "Demo Gimbal" at the top of the device list — no BLE
needed in the emulator. The pan/tilt/level controls and the 3D
visualization will all work against the simulated transport.
EOF
