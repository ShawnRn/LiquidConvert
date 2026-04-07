#!/usr/bin/env bash

# LiquidConvert Compile and Run Script
# Inspired by MotrixMac with structured logging and safety checks.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LiquidConvert"
ARCH=$(uname -m)
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}_${ARCH}.app"
# Fallback to generic if arch-specific not found (though build script creates them)
if [ ! -d "${APP_BUNDLE}" ]; then
  APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
fi
APP_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# Structured logging
log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_step() {
  local label="$1"; shift
  log "==> ${label}"
  if ! "$@"; then
    fail "${label} failed"
  fi
}

kill_all_instances() {
  log "==> Terminating all existing ${APP_NAME} instances..."
  
  # Phase 1: Try killall for exact process name (forceful right away to avoid hangs)
  killall -9 "${APP_NAME}" 2>/dev/null || true
  
  # Phase 2: Thorough check and pkill with pattern
  pkill -9 -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
  
  # Phase 3: Wait a moment for OS to clean up
  sleep 1
  
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "WARNING: Some instances might still be lingering. Trying one last time..."
    pgrep -f "${APP_PROCESS_PATTERN}" | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
}

# --- Execution ---

# 1) Build only the current architecture app bundle and skip DMG packaging for dev loops
run_step "Building ${APP_NAME} (debug)" env BUILD_ARCHS="${ARCH}" SKIP_DMG=1 "${ROOT_DIR}/scripts/build.sh" debug

# 2) Cleanup
kill_all_instances

# 3) Launch
log "==> Launching app"
open -na "${APP_BUNDLE}"
sleep 1
osascript -e "tell application \"${APP_BUNDLE}\" to activate" >/dev/null 2>&1 || true

# 4) Verify
log "==> Verifying application state"
for _ in {1..10}; do
  APP_PID=$(pgrep -n -f "${APP_EXECUTABLE}" || true)
  if [ -n "${APP_PID}" ] && ps -p "${APP_PID}" > /dev/null; then
    log "Launched ${APP_NAME} (PID: ${APP_PID})"
    log "OK: ${APP_NAME} is running"
    log "==> All development loop steps completed successfully."
    exit 0
  fi
  sleep 0.5
done

fail "App exited immediately or failed to start."
