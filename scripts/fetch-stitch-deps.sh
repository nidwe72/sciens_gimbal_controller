#!/usr/bin/env bash
#
# Fetch the Phase 6 native-stitch dependencies (OpenPano + Eigen) into the
# CMake source tree. These third-party trees are NOT committed (see
# .gitignore) — this script reconstructs them so `libpanostitch.so` can
# build from a fresh checkout.
#
#   - OpenPano (github.com/ppwwyyxx/OpenPano), pinned commit, with our
#     local patch (cpp/openpano.patch — grid-restricted matching +
#     progress reporting) applied on top.
#   - Eigen (header-only), pinned release.
#
# Idempotent: re-running re-fetches cleanly. Pass --force to overwrite an
# existing tree. Requires: git, curl, tar, patch.
set -euo pipefail

OPENPANO_REPO="https://github.com/ppwwyyxx/OpenPano"
OPENPANO_COMMIT="f9b246945e891b67e200def47e399bf591422c9e"  # master, 2023-10-06
EIGEN_VERSION="3.4.0"
EIGEN_TARBALL="https://gitlab.com/libeigen/eigen/-/archive/${EIGEN_VERSION}/eigen-${EIGEN_VERSION}.tar.gz"

# Repo-root-relative paths (resolved from this script's location).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPP_DIR="$(cd "${SCRIPT_DIR}/../android/app/src/main/cpp" && pwd)"
OPENPANO_DIR="${CPP_DIR}/openpano"
EIGEN_DIR="${CPP_DIR}/eigen"
PATCH_FILE="${CPP_DIR}/openpano.patch"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

for tool in git curl tar patch; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found on PATH" >&2; exit 1; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- OpenPano ---------------------------------------------------------------
if [ -d "$OPENPANO_DIR" ] && [ "$FORCE" -eq 0 ]; then
  echo "openpano/ already present — skipping (use --force to refetch)."
else
  echo "Fetching OpenPano @ ${OPENPANO_COMMIT:0:9} ..."
  git clone --quiet "$OPENPANO_REPO" "$TMP_DIR/OpenPano"
  git -C "$TMP_DIR/OpenPano" checkout --quiet "$OPENPANO_COMMIT"

  rm -rf "$OPENPANO_DIR"
  # The CMake build expects upstream's src/ contents flattened up one level.
  cp -r "$TMP_DIR/OpenPano/src" "$OPENPANO_DIR"
  cp "$TMP_DIR/OpenPano/LICENSE" "$OPENPANO_DIR/LICENSE"

  echo "Applying openpano.patch ..."
  ( cd "$OPENPANO_DIR" && patch -p1 --silent < "$PATCH_FILE" )
  echo "  openpano/ ready."
fi

# --- Eigen ------------------------------------------------------------------
if [ -d "$EIGEN_DIR" ] && [ "$FORCE" -eq 0 ]; then
  echo "eigen/ already present — skipping (use --force to refetch)."
else
  echo "Fetching Eigen ${EIGEN_VERSION} ..."
  curl -fsSL "$EIGEN_TARBALL" -o "$TMP_DIR/eigen.tar.gz"
  tar -xzf "$TMP_DIR/eigen.tar.gz" -C "$TMP_DIR"

  rm -rf "$EIGEN_DIR"
  mkdir -p "$EIGEN_DIR"
  # Header-only: just the Eigen/ and unsupported/ trees (matches the
  # CMake include dir `${CMAKE_CURRENT_SOURCE_DIR}/eigen`, used as
  # `#include <Eigen/Dense>`).
  cp -r "$TMP_DIR/eigen-${EIGEN_VERSION}/Eigen" "$EIGEN_DIR/Eigen"
  cp -r "$TMP_DIR/eigen-${EIGEN_VERSION}/unsupported" "$EIGEN_DIR/unsupported"
  cp "$TMP_DIR/eigen-${EIGEN_VERSION}/COPYING.MPL2" "$EIGEN_DIR/COPYING.MPL2"
  echo "  eigen/ ready."
fi

echo "Done. Native stitch deps are in place under ${CPP_DIR}."
