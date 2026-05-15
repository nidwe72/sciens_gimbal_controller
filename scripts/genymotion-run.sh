#!/usr/bin/env bash
#
# Build the debug APK and install + launch it on a running Genymotion
# device. Assumes:
#   - Genymotion Desktop is already running and the virtual device is
#     started (boot to homescreen). Start it from the Genymotion UI.
#   - `adb` is on PATH (from Android Studio's platform-tools, or
#     `sudo apt install adb`).
#
# Genymotion exposes its devices to adb over a host-only IPv4 network,
# so serials look like `192.168.56.101:5555` (the colon is the giveaway
# for the auto-detect below).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APK_REL="build/app/outputs/flutter-apk/app-debug.apk"
APK="$PROJECT_DIR/$APK_REL"
PKG="at.sciens.gimbal_controller"
ACTIVITY=".MainActivity"

DO_BUILD=1
EXPLICIT_SERIAL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--no-build] [--serial <id>]

Build the debug APK, install it on a running Genymotion device, and
launch the app. Start the device from the Genymotion Desktop UI first.

  --no-build         Skip 'flutter build apk --debug' (reuse existing APK).
  --serial <id>      adb serial of the device to use (e.g.
                     192.168.56.101:5555). Default: auto-detect the
                     unique Genymotion-shaped (IP:port) device.
  -s <id>            Short form of --serial.
  -h, --help         Show this.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)    DO_BUILD=0;                       shift ;;
    --serial)      EXPLICIT_SERIAL="$2";             shift 2 ;;
    --serial=*)    EXPLICIT_SERIAL="${1#--serial=}"; shift ;;
    -s)            EXPLICIT_SERIAL="$2";             shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# -------------------------------------------------------------- preflight

if ! command -v adb >/dev/null; then
  echo "ERROR: 'adb' not found. Install Android platform-tools:" >&2
  echo "  sudo apt install adb" >&2
  echo "or use the one bundled with Android Studio." >&2
  exit 1
fi

# ----------------------------------------------------------------- build

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

# ----------------------------------------------------- find the device

echo "[2/4] Locating Genymotion device..."
if [ -n "$EXPLICIT_SERIAL" ]; then
  SERIAL="$EXPLICIT_SERIAL"
  state=$(adb -s "$SERIAL" get-state 2>/dev/null || true)
  if [ "$state" != "device" ]; then
    echo "ERROR: device '$SERIAL' is not connected (state='$state')." >&2
    echo "Devices currently visible to adb:" >&2
    adb devices >&2
    exit 1
  fi
else
  # Genymotion serials are IP:port (contain a colon). Filter on that
  # plus the 'device' state to skip 'offline' / 'unauthorized' rows.
  mapfile -t found < <(
    adb devices | awk 'NR>1 && $2 == "device" && $1 ~ /:/ {print $1}'
  )
  if [ "${#found[@]}" -eq 0 ]; then
    echo "ERROR: no Genymotion-shaped (IP:port) device in 'adb devices'." >&2
    echo "Devices currently visible to adb:" >&2
    adb devices >&2
    echo >&2
    echo "Start the device from the Genymotion Desktop UI, wait for the" >&2
    echo "homescreen, then retry. Or pass --serial <id>." >&2
    exit 1
  fi
  if [ "${#found[@]}" -gt 1 ]; then
    echo "ERROR: multiple Genymotion-shaped devices found:" >&2
    printf '    %s\n' "${found[@]}" >&2
    echo "Disambiguate with --serial <id>." >&2
    exit 1
  fi
  SERIAL="${found[0]}"
fi
echo "    Using device: $SERIAL"

# ------------------------------------------------------ install + launch

echo "[3/4] Installing $APK_REL..."
adb -s "$SERIAL" install -r "$APK"

echo "[4/4] Launching $PKG..."
adb -s "$SERIAL" shell am start -n "$PKG/$ACTIVITY" >/dev/null

cat <<EOF

Done. The app should be running on $SERIAL.

Inside the app, tap "Demo Gimbal" at the top of the device list — BLE
isn't available in the emulator, but the demo transport provides full
pan/tilt/level + 3D visualization without hardware.

To stream the app's logs:
    adb -s $SERIAL logcat -v color flutter:V \*:S
EOF
