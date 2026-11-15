#!/usr/bin/env bash
set -euo pipefail

# Native macOS (Docker-free) Flexicast QUIC heartbeat receiver runner.
# Usage:
#   ./run_receiver_macos.sh [SRC_IP] [ID] [extra tfc-receiver args...]
#   ./run_receiver_macos.sh [extra tfc-receiver args...]
#
# Environment overrides:
#   SRC_IP              Source IP (default: 193.191.171.131)
#   SRC_PORT            Source UDP port: 4433 for PING (default), 4435 for FC_PING (requires fcping build)
#   ID                  Client ID used for default QLOGDIR path (default: 1)
#   LOCAL_IP            Local multicast interface IP (default: 0.0.0.0)
#   AMT_FALLBACK        1 to enable AMT fallback (default), 0 to disable
#   AMT_RELAY           AMT relay IPv4 address (default: 62.40.96.44)
#   AMT_FALLBACK_DELAY  ms without native multicast before AMT fallback (default: 750)
#   RUST_LOG            Log filter (default: warn,tfc_receiver=info,tokio_fcquiche=info)
#   RUST_BACKTRACE      Backtrace setting (default: 1)
#   QLOGDIR             Directory for .sqlog files; set empty (QLOGDIR="") to disable
#   QLOG_UPLOAD_URL     Upload endpoint on exit; set empty (QLOG_UPLOAD_URL="") to skip upload
#   TFC_RECEIVER        Path to tfc-receiver binary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFC_RECEIVER="${TFC_RECEIVER:-$SCRIPT_DIR/fcquic-beacon/target/release/tfc-receiver}"

usage() {
    cat <<'EOF'
Usage:
  ./run_receiver_macos.sh [SRC_IP] [ID] [extra tfc-receiver args...]
  ./run_receiver_macos.sh [extra tfc-receiver args...]

Defaults:
  SRC_IP=193.191.171.131  SRC_PORT=4433  LOCAL_IP=0.0.0.0
  AMT_FALLBACK=1          AMT_RELAY=62.40.96.44  AMT_FALLBACK_DELAY=750
  QLOGDIR=./out/client<ID>/qlogs
  QLOG_UPLOAD_URL=http://<SRC_IP>:8080/qlog

Disable QLOG collection: QLOGDIR="" ./run_receiver_macos.sh
Keep QLOGs local only:   QLOG_UPLOAD_URL="" ./run_receiver_macos.sh
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    if [ -x "$TFC_RECEIVER" ]; then
        echo ""
        "$TFC_RECEIVER" --help
    fi
    exit 0
fi

if [ ! -x "$TFC_RECEIVER" ]; then
    echo "Error: tfc-receiver binary not found or not executable at:" >&2
    echo "  $TFC_RECEIVER" >&2
    echo "Build it first (see HOWTO.md):" >&2
    echo "  cd \"$SCRIPT_DIR/fcquic-beacon\" && cargo build --release --bin tfc-receiver" >&2
    exit 1
fi

SRC_IP="${SRC_IP:-193.191.171.131}"
ID="${ID:-1}"
if [ $# -ge 1 ] && [[ "$1" != -* ]]; then
    SRC_IP="$1"
    shift
    if [ $# -ge 1 ] && [[ "$1" != -* ]]; then
        ID="$1"
        shift
    fi
fi

SRC_PORT="${SRC_PORT:-4433}"
LOCAL_IP="${LOCAL_IP:-0.0.0.0}"
AMT_FALLBACK="${AMT_FALLBACK:-1}"
AMT_RELAY="${AMT_RELAY:-62.40.96.44}"
AMT_FALLBACK_DELAY="${AMT_FALLBACK_DELAY:-750}"
RUST_LOG_VALUE="${RUST_LOG:-warn,tfc_receiver=info,tokio_fcquiche=info}"
RUST_BACKTRACE_VALUE="${RUST_BACKTRACE:-1}"

DEFAULT_QLOGDIR="$SCRIPT_DIR/out/client$ID/qlogs"
QLOGDIR_VALUE="${QLOGDIR-$DEFAULT_QLOGDIR}"
QLOG_UPLOAD_URL_VALUE="${QLOG_UPLOAD_URL-http://$SRC_IP:8080/qlog}"

has_local=0
has_flexicast=0
has_amt_fallback=0
has_amt_relay=0
has_amt_delay=0
for arg in "$@"; do
    case "$arg" in
        -l|-l=*|--local|--local=*) has_local=1 ;;
        --flexicast) has_flexicast=1 ;;
        --amt-fallback) has_amt_fallback=1 ;;
        --amt-relay|--amt-relay=*) has_amt_relay=1 ;;
        --amt-fallback-delay|--amt-fallback-delay=*) has_amt_delay=1 ;;
    esac
done

CMD_ARGS=("https://$SRC_IP:$SRC_PORT/heartbeat")
if [ "$has_local" -eq 0 ]; then
    CMD_ARGS+=(-l "$LOCAL_IP")
fi
if [ "$has_flexicast" -eq 0 ]; then
    CMD_ARGS+=(--flexicast)
fi

if [ "$AMT_FALLBACK" = "1" ] && [ -n "$AMT_RELAY" ]; then
    [ "$has_amt_fallback" -eq 0 ] && CMD_ARGS+=(--amt-fallback)
    [ "$has_amt_relay" -eq 0 ] && CMD_ARGS+=(--amt-relay "$AMT_RELAY")
    [ "$has_amt_delay" -eq 0 ] && CMD_ARGS+=(--amt-fallback-delay "$AMT_FALLBACK_DELAY")
fi

if [ $# -gt 0 ]; then
    CMD_ARGS+=("$@")
fi

ENV_CMD=(env "RUST_LOG=$RUST_LOG_VALUE" "RUST_BACKTRACE=$RUST_BACKTRACE_VALUE")
if [ -n "$QLOGDIR_VALUE" ]; then
    mkdir -p "$QLOGDIR_VALUE"
    ENV_CMD+=("QLOGDIR=$QLOGDIR_VALUE")
fi

echo "Starting macOS receiver ($ID) -> https://$SRC_IP:$SRC_PORT/heartbeat (AMT_FALLBACK=$AMT_FALLBACK, AMT_RELAY=${AMT_RELAY:-none})"

PID=""
trap 'if [ -n "$PID" ]; then kill -INT "$PID" 2>/dev/null || true; fi' INT TERM

"${ENV_CMD[@]}" "$TFC_RECEIVER" "${CMD_ARGS[@]}" &
PID=$!

STATUS=0
while kill -0 "$PID" 2>/dev/null; do
    if wait "$PID"; then
        STATUS=0
    else
        STATUS=$?
    fi
done

if [ -n "$QLOGDIR_VALUE" ] && [ -d "$QLOGDIR_VALUE" ]; then
    for f in "$QLOGDIR_VALUE"/*.sqlog; do
        if [ -f "$f" ]; then
            gzip -f "$f"
        fi
    done

    if [ -n "$QLOG_UPLOAD_URL_VALUE" ]; then
        UPLOAD_BASE="${QLOG_UPLOAD_URL_VALUE%/}/"
        for f in "$QLOGDIR_VALUE"/*.sqlog.gz; do
            if [ -f "$f" ]; then
                if curl -fsS -m 60 -T "$f" "$UPLOAD_BASE"; then
                    rm -f "$f"
                    echo "Uploaded $f"
                else
                    echo "Warning: failed to upload $f to $UPLOAD_BASE; kept locally" >&2
                fi
            fi
        done
    fi
fi

exit "$STATUS"
