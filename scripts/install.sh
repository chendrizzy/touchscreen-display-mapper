#!/usr/bin/env bash
# Install touchscreen-display-mapper as a per-user launchd agent.
#
# Builds the release binary, signs it, copies it into
# ~/.touchscreen-display-mapper/bin, renders
# ~/Library/LaunchAgents/io.github.chendrizzy.touchscreen-display-mapper.plist,
# then bootstraps the agent (RunAtLoad starts it). Use --dry-run to
# validate/render without writes or launchctl side effects.
#
# Signing matters: macOS ties the Input Monitoring and Accessibility grants to
# the binary's signature. With a real identity (Developer ID, Apple
# Development, or a self-signed code-signing certificate) the grants survive
# reinstalls. With an ad-hoc signature every build is a new app to macOS, and
# the grants have to be given again after each install.

set -euo pipefail

LABEL="io.github.chendrizzy.touchscreen-display-mapper"
NAME="touchscreen-display-mapper"
DRY_RUN=0
OBSERVE=0
MULTITOUCH=0
GESTURES=0
PINCH=0
DEVICE=""
DISPLAY_SPEC=""
LIFT_TIMEOUT=""

usage() {
  cat <<USAGE
Usage: scripts/install.sh --device VID:PID --display VENDOR:MODEL[:SERIAL]
                          [--lift-timeout MS] [--multitouch] [--gestures]
                          [--pinch] [--observe] [--dry-run]

Find both values first:
  swift run $NAME list-devices
  swift run $NAME list-displays

Options:
  --device VID:PID        the touch panel, hexadecimal (e.g. 27c0:0859)
  --display V:M[:SERIAL]  the display it sits on, decimal (e.g. 19083:13107)
  --lift-timeout MS       release a held touch after MS ms without a report
                          (default 500; 0 disables)
  --multitouch            switch the panel to multi-input mode, which reports
                          each finger; put back when the agent stops
  --gestures              phone-style touch: tap clicks, a moving finger
                          scrolls, a finger resting half a second drags; two
                          fingers scroll on panels that report each finger
  --pinch                 with --gestures: double-tap then drag up or down to
                          zoom, or pinch two fingers on panels that report
                          each finger (undocumented macOS gesture events)
  --observe               open the panel shared and post nothing: touches
                          behave as they do today and the log shows where each
                          would land. Re-run without --observe to take over.
  --dry-run               print resolved paths and the rendered plist without
                          building, signing, copying, or calling launchctl

Environment:
  TSDM_SIGN_IDENTITY      code-signing identity (name or SHA-1) to sign with;
                          "-" forces ad-hoc. Default: the first Developer ID
                          Application, then Apple Development, identity found.
  TSDM_HOME               install directory (default ~/.$NAME)
USAGE
}

note() { printf '[install] %s\n' "$*"; }
fail() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) [ "$#" -ge 2 ] || fail "--device needs a value"; DEVICE="$2"; shift ;;
    --display) [ "$#" -ge 2 ] || fail "--display needs a value"; DISPLAY_SPEC="$2"; shift ;;
    --lift-timeout) [ "$#" -ge 2 ] || fail "--lift-timeout needs a value"; LIFT_TIMEOUT="$2"; shift ;;
    --multitouch) MULTITOUCH=1 ;;
    --gestures) GESTURES=1 ;;
    --pinch) PINCH=1 ;;
    --observe) OBSERVE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$DEVICE" ] || { usage >&2; fail "--device is required"; }
[ -n "$DISPLAY_SPEC" ] || { usage >&2; fail "--display is required"; }
[ "$PINCH" -eq 0 ] || [ "$GESTURES" -eq 1 ] || fail "--pinch needs --gestures"
printf '%s' "$DEVICE" | grep -Eq '^(0x)?[0-9A-Fa-f]{1,4}:(0x)?[0-9A-Fa-f]{1,4}$' \
  || fail "--device must be VID:PID in hex, e.g. 27c0:0859 (got: $DEVICE)"
printf '%s' "$DISPLAY_SPEC" | grep -Eq '^[0-9]+:[0-9]+(:[0-9]+)?$' \
  || fail "--display must be VENDOR:MODEL[:SERIAL] in decimal, e.g. 19083:13107 (got: $DISPLAY_SPEC)"
if [ -n "$LIFT_TIMEOUT" ]; then
  printf '%s' "$LIFT_TIMEOUT" | grep -Eq '^[0-9]+$' || fail "--lift-timeout must be whole milliseconds (got: $LIFT_TIMEOUT)"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/scripts/launchd.plist.tmpl"
DEST="${TSDM_HOME:-$HOME/.$NAME}"
BIN_SRC="$ROOT/.build/release/$NAME"
BIN_DEST="$DEST/bin/$NAME"
LOGDIR="$DEST/log"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
TARGET="gui/$(id -u)"
SERVICE="$TARGET/$LABEL"

# launchd will not resolve a relative ProgramArguments[0].
case "$DEST" in
  /*) ;;
  *) fail "TSDM_HOME must be an absolute path, got: $DEST" ;;
esac
[ -f "$TEMPLATE" ] || fail "missing plist template: $TEMPLATE"

# The SHA-1 of the first matching identity: a name can be ambiguous when the
# keychain holds several certificates with it.
resolve_identity() {
  if [ -n "${TSDM_SIGN_IDENTITY:-}" ]; then
    printf '%s' "$TSDM_SIGN_IDENTITY"
    return
  fi
  local identities kind hash
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for kind in "Developer ID Application" "Apple Development"; do
    hash="$(printf '%s\n' "$identities" | awk -v k="\"$kind" 'index($0, k) { print $2; exit }')"
    if [ -n "$hash" ]; then
      printf '%s' "$hash"
      return
    fi
  done
  printf '%s' "-"
}

describe_identity() {
  if [ "$1" = "-" ]; then
    printf 'ad-hoc'
  else
    security find-identity -v -p codesigning 2>/dev/null | awk -v h="$1" '$2 == h { sub(/^[^"]*"/, ""); sub(/"$/, ""); print; found=1; exit } END { if (!found) print h }'
  fi
}

warn_adhoc() {
  if [ "${TSDM_SIGN_IDENTITY:-}" = "-" ]; then
    note "WARNING: signing ad-hoc (TSDM_SIGN_IDENTITY=-)."
  else
    note "WARNING: no code-signing identity found, signing ad-hoc."
  fi
  note "  macOS will treat every reinstall as a new app: after each install, re-enable"
  note "  $NAME under Input Monitoring and Accessibility (Device Control and Data"
  note "  Access on macOS 27) in System Settings."
  note "  To avoid that, create a self-signed code-signing certificate (see README)"
  note "  and pass its name in TSDM_SIGN_IDENTITY."
}

sed_escape() {
  # Escape replacement text for sed's s||| delimiter.
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

ARGS=("$BIN_DEST" run --device "$DEVICE" --display "$DISPLAY_SPEC")
[ -n "$LIFT_TIMEOUT" ] && ARGS+=(--lift-timeout "$LIFT_TIMEOUT")
[ "$MULTITOUCH" -eq 1 ] && ARGS+=(--multitouch)
[ "$GESTURES" -eq 1 ] && ARGS+=(--gestures)
[ "$PINCH" -eq 1 ] && ARGS+=(--pinch)
[ "$OBSERVE" -eq 1 ] && ARGS+=(--observe)

args_xml() {
  local arg out=""
  for arg in "${ARGS[@]}"; do
    out="$out<string>$(xml_escape "$arg")</string>"
  done
  printf '    %s' "$out"
}

render_plist() {
  sed \
    -e "s|__LABEL__|$(sed_escape "$LABEL")|g" \
    -e "s|__ARGS__|$(sed_escape "$(args_xml)")|g" \
    -e "s|__LOGDIR__|$(sed_escape "$(xml_escape "$LOGDIR")")|g" \
    "$TEMPLATE"
}

validate_rendered_plist() {
  local tmp rc
  tmp="$(mktemp)"
  render_plist > "$tmp"
  if plutil -lint "$tmp" >/dev/null; then rc=0; else rc=$?; fi
  rm -f "$tmp"
  return "$rc"
}

# Boot the agent out by service name and wait until launchd has really let go;
# bootstrapping over a job that is still tearing down fails with an opaque
# "Input/output error".
stop_agent() {
  launchctl print "$SERVICE" >/dev/null 2>&1 || return 0
  launchctl bootout "$SERVICE" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$SERVICE" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  fail "agent still loaded after bootout; run: launchctl bootout $SERVICE"
}

IDENTITY="$(resolve_identity)"

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run; no build, sign, copy, writes, or launchctl calls"
  note "label: $LABEL"
  note "device: $DEVICE   display: $DISPLAY_SPEC   mode: $([ "$OBSERVE" -eq 1 ] && echo observe || echo seize)$([ "$MULTITOUCH" -eq 1 ] && echo ', multitouch')$([ "$GESTURES" -eq 1 ] && echo ', gestures')$([ "$PINCH" -eq 1 ] && echo ', pinch')"
  note "binary: $BIN_DEST"
  note "signing identity: $(describe_identity "$IDENTITY")"
  [ "$IDENTITY" = "-" ] && warn_adhoc
  note "logdir: $LOGDIR"
  note "plist: $PLIST"
  printf '%s\n' '--- rendered plist ---'
  render_plist
  validate_rendered_plist || fail "rendered plist does not lint"
  note "plist: OK"
  exit 0
fi

for tool in swift codesign launchctl plutil security; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

# Prove the plist renders before anything is built, stopped, or replaced.
validate_rendered_plist || fail "rendered plist does not lint"

note "building release binary"
(cd "$ROOT" && swift build -c release)
[ -x "$BIN_SRC" ] || fail "release binary not found after build: $BIN_SRC"

note "signing with: $(describe_identity "$IDENTITY")"
[ "$IDENTITY" = "-" ] && warn_adhoc
codesign --force --sign "$IDENTITY" --identifier "$LABEL" --options runtime "$BIN_SRC"
codesign --verify --strict "$BIN_SRC" || fail "signature did not verify"

note "stopping any running agent"
stop_agent

note "installing binary and logs under $DEST"
mkdir -p "$DEST/bin" "$LOGDIR" "$LAUNCH_AGENTS_DIR"
# Copy beside the destination, then rename over it, so a running copy is never
# rewritten in place.
cp "$BIN_SRC" "$BIN_DEST.tmp"
chmod 755 "$BIN_DEST.tmp"
mv -f "$BIN_DEST.tmp" "$BIN_DEST"

note "writing $PLIST"
render_plist > "$PLIST.tmp"
mv -f "$PLIST.tmp" "$PLIST"

# RunAtLoad starts the agent; a kickstart here would only kill that first run.
note "bootstrapping $LABEL"
launchctl bootstrap "$TARGET" "$PLIST" || fail "bootstrap failed; check: launchctl print $SERVICE"

sleep 2
status="$(launchctl print "$SERVICE" 2>/dev/null || true)"
pid="$(printf '%s\n' "$status" | awk '$1 == "pid" { print $3; exit }')"
last_exit="$(printf '%s\n' "$status" | awk -F' = ' '/last exit code/ { print $2; exit }')"
if [ -n "$pid" ]; then
  note "running, pid $pid; logs at $LOGDIR"
else
  # The agent logs its reason before every exit; exit 75 means launchd retries.
  note "not running (last exit: ${last_exit:-unknown}); its last word:"
  note "  $(tail -n 1 "$LOGDIR/stdout.log" 2>/dev/null || echo '(no log yet)')"
  note "first install? enable $NAME under Input Monitoring$([ "$OBSERVE" -eq 1 ] || echo ' and Accessibility (Device Control and Data Access on macOS 27)')"
  note "  in System Settings > Privacy & Security; launchd retries every 30 s."
fi
note "remove with: scripts/uninstall.sh"
