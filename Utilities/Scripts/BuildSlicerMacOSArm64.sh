#!/bin/bash
#
# Native Apple Silicon (arm64) build of 3D Slicer using Homebrew Qt 6.
#
# Usage:
#   Utilities/Scripts/BuildSlicerMacOSArm64.sh [configure|build|all]   (default: all)
#
# Environment overrides:
#   SLICER_BUILD_DIR    superbuild directory (default: /opt/sr). Keep it short:
#                       long build paths hit the mach-o load-command size limit.
#   JOBS                parallel make jobs (default: 4, sized for 8 GB RAM)
#   DEPLOYMENT_TARGET   minimum macOS version (default: 14.0, Slicer's floor)
#   QT6_DIR             Qt6 CMake dir (default: /opt/homebrew/lib/cmake/Qt6)
#   CMAKE_BUILD_TYPE    Release (default) or Debug (needs > 20 GB disk)
#
# What it does:
#   1. Checks the host (arm64, Xcode, CMake >= 3.28, free disk).
#   2. Installs Homebrew Qt 6 (the `qt` meta formula, incl. WebEngine) if missing.
#   3. Builds a native arm64 CTKAppLauncher from source. Upstream only ships an
#      x86_64 launcher for macOS (SuperBuild/External_CTKAPPLAUNCHER.cmake), which
#      would need Rosetta 2. Predefining CTKAppLauncher_DIR makes Slicer skip the
#      download and use ours.
#   4. Configures and builds the Slicer superbuild.
#
# Afterwards, rebuild only Slicer with:  make -C "$SLICER_BUILD_DIR/Slicer-build" -j"$JOBS"
# and run it with:                       "$SLICER_BUILD_DIR/Slicer-build/Slicer"

set -euo pipefail

SLICER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLICER_BUILD_DIR="${SLICER_BUILD_DIR:-/opt/sr}"
JOBS="${JOBS:-4}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"
QT6_DIR="${QT6_DIR:-/opt/homebrew/lib/cmake/Qt6}"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
LAUNCHER_REPO="https://github.com/commontk/AppLauncher.git"
# Same commit Slicer uses for CTKAppLauncherLib (SuperBuild/External_CTKAppLauncherLib.cmake).
LAUNCHER_SHA="a37ad37c06e6fb4fc203434787f8bbffb52749bb"
LAUNCHER_SRC="$SLICER_BUILD_DIR/CTKAppLauncher-src"
LAUNCHER_BUILD="$SLICER_BUILD_DIR/CTKAppLauncher-arm64-build"
LAUNCHER_PREFIX="$SLICER_BUILD_DIR/CTKAppLauncher-arm64"
STEP="${1:-all}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
check_host() {
  log "Checking host"
  [ "$(uname -m)" = "arm64" ] || die "This script is for Apple Silicon (uname -m = arm64)."
  xcode-select -p >/dev/null 2>&1 || die "Xcode command line tools missing: run 'xcode-select --install'."
  command -v cmake >/dev/null || die "cmake not found (brew install cmake)."
  local cmake_ver
  cmake_ver="$(cmake --version | head -1 | awk '{print $3}')"
  [ "$(printf '%s\n' 3.28.0 "$cmake_ver" | sort -V | head -1)" = "3.28.0" ] \
    || die "CMake >= 3.28 required, found $cmake_ver."
  command -v brew >/dev/null || die "Homebrew not found."
  SDKROOT="$(xcrun --show-sdk-path)"
  echo "  source:     $SLICER_SRC"
  echo "  build dir:  $SLICER_BUILD_DIR"
  echo "  SDK:        $SDKROOT ($(xcrun --show-sdk-version))"
  echo "  cmake:      $cmake_ver"
  echo "  jobs:       $JOBS"

  mkdir -p "$SLICER_BUILD_DIR" || die "Cannot create $SLICER_BUILD_DIR (for /opt: sudo mkdir -p /opt/sr && sudo chown \$(whoami) /opt/sr)."
  [ -w "$SLICER_BUILD_DIR" ] || die "$SLICER_BUILD_DIR is not writable."
  local free_gb
  free_gb="$(df -g "$SLICER_BUILD_DIR" | awk 'NR==2 {print $4}')"
  echo "  free disk:  ${free_gb} GB"
  if [ "$free_gb" -lt 15 ]; then
    echo "  WARNING: a Release superbuild needs roughly 12-15 GB; a Debug build over 20 GB."
  fi
}

# ---------------------------------------------------------------------------
ensure_qt6() {
  log "Checking Homebrew Qt 6"
  if [ ! -f "$QT6_DIR/Qt6Config.cmake" ]; then
    echo "  Qt6 not found at $QT6_DIR, installing with Homebrew (large download)..."
    brew install qt
  fi
  [ -f "$QT6_DIR/Qt6Config.cmake" ] || die "Qt6Config.cmake still missing at $QT6_DIR."
  local comp
  for comp in Qt6WebEngineWidgets Qt6Core5Compat Qt6LinguistTools Qt6StateMachine Qt6Svg Qt6Multimedia Qt6UiTools; do
    [ -d "$(dirname "$QT6_DIR")/$comp" ] || die "Qt component $comp missing under $(dirname "$QT6_DIR"); 'brew install qt' should provide it."
  done
  echo "  Qt $(grep -m1 -o 'PACKAGE_VERSION "[^"]*"' "$QT6_DIR/Qt6ConfigVersion.cmake" | cut -d'"' -f2) at $QT6_DIR"
}

# ---------------------------------------------------------------------------
build_launcher() {
  log "Building native arm64 CTKAppLauncher"
  if [ -x "$LAUNCHER_PREFIX/bin/CTKAppLauncher" ] && [ -f "$LAUNCHER_PREFIX/CTKAppLauncherConfig.cmake" ]; then
    echo "  already built: $LAUNCHER_PREFIX"
  else
    if [ ! -d "$LAUNCHER_SRC/.git" ]; then
      git clone "$LAUNCHER_REPO" "$LAUNCHER_SRC"
    fi
    git -C "$LAUNCHER_SRC" fetch --quiet origin
    git -C "$LAUNCHER_SRC" checkout --quiet "$LAUNCHER_SHA"
    cmake -S "$LAUNCHER_SRC" -B "$LAUNCHER_BUILD" -G "Unix Makefiles" \
      -DCMAKE_BUILD_TYPE:STRING=Release \
      -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="$DEPLOYMENT_TARGET" \
      -DCMAKE_OSX_SYSROOT:PATH="$SDKROOT" \
      -DCTKAppLauncher_QT_VERSION:STRING=6 \
      -DQt6_DIR:PATH="$QT6_DIR" \
      -DBUILD_TESTING:BOOL=OFF \
      -DCMAKE_INSTALL_PREFIX:PATH="$LAUNCHER_PREFIX"
    cmake --build "$LAUNCHER_BUILD" -j"$JOBS"
    cmake --install "$LAUNCHER_BUILD"
  fi
  file "$LAUNCHER_PREFIX/bin/CTKAppLauncher" | grep -q arm64 || die "CTKAppLauncher is not an arm64 binary."
  [ -f "$LAUNCHER_PREFIX/CTKAppLauncherConfig.cmake" ] || die "CTKAppLauncherConfig.cmake missing in $LAUNCHER_PREFIX."
  [ -f "$LAUNCHER_PREFIX/bin/CTKAppLauncherSettings.ini.in" ] || die "CTKAppLauncherSettings.ini.in missing in $LAUNCHER_PREFIX."
  echo "  $(file "$LAUNCHER_PREFIX/bin/CTKAppLauncher")"
}

# ---------------------------------------------------------------------------
configure_slicer() {
  log "Configuring Slicer superbuild ($CMAKE_BUILD_TYPE)"
  cmake -S "$SLICER_SRC" -B "$SLICER_BUILD_DIR" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE:STRING="$CMAKE_BUILD_TYPE" \
    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT:PATH="$SDKROOT" \
    -DQt6_DIR:PATH="$QT6_DIR" \
    -DSlicer_USE_SYSTEM_QT:BOOL=ON \
    -DCTKAppLauncher_DIR:PATH="$LAUNCHER_PREFIX" \
    -DBUILD_TESTING:BOOL=ON
}

# ---------------------------------------------------------------------------
build_slicer() {
  log "Building Slicer superbuild with make -j$JOBS (this takes hours)"
  cd "$SLICER_BUILD_DIR"
  # -k keeps going so independent projects finish; the plain make afterwards
  # stops at the first real error and makes it easy to find in the log.
  make -j"$JOBS" -k 2>&1 | tee "$SLICER_BUILD_DIR/build.log" || true
  make 2>&1 | tee -a "$SLICER_BUILD_DIR/build.log"
  log "Done"
  echo "  Run:      $SLICER_BUILD_DIR/Slicer-build/Slicer"
  echo "  Rebuild:  make -C $SLICER_BUILD_DIR/Slicer-build -j$JOBS"
  echo "  Tests:    (cd $SLICER_BUILD_DIR/Slicer-build && ctest -j$JOBS)"
}

# ---------------------------------------------------------------------------
case "$STEP" in
  configure) check_host; ensure_qt6; build_launcher; configure_slicer ;;
  build)     check_host; build_slicer ;;
  all)       check_host; ensure_qt6; build_launcher; configure_slicer; build_slicer ;;
  *)         die "Unknown step '$STEP' (configure|build|all)" ;;
esac
