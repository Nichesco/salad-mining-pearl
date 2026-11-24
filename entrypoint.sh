#!/usr/bin/env bash
set -uo pipefail

if [ -z "${POOL:-}" ] || [ -z "${WALLET:-}" ]; then
  echo "[error] POOL and WALLET environment variables are required."
  sleep 30
  exit 1
fi

WORKER="${WORKER:-${HOSTNAME:-salad}}"
PASS="${PASS:-x}"
MIN_THS="${MIN_THS:-0}"
WARMUP_SEC="${WARMUP_SEC:-240}"
REJECT_5090D="${REJECT_5090D:-1}"

reallocate() {
  local reason="$1"
  echo "[watchdog] Reallocating node: ${reason}"
  local payload
  payload=$(jq -nc --arg r "$reason" '{reason: $r}')
  curl -fsS -X POST \
    -H "Metadata: true" \
    -H "Content-Type: application/json" \
    --noproxy "*" \
    -d "$payload" \
    http://169.254.169.254/v1/reallocate || true
  sleep 30
  exit 1
}

if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_INFO=$(nvidia-smi --query-gpu=name,driver_version,power.limit --format=csv,noheader | head -n1 || true)
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || true)
  DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 || true)
  echo "[boot] Host GPU: ${GPU_INFO}"

  if [ "$REJECT_5090D" = "1" ] && echo "$GPU_NAME" | grep -qi "5090 D"; then
    reallocate "RTX 5090 D detected"
  fi

  DRIVER_MAJOR="${DRIVER%%.*}"
  if echo "$GPU_NAME" | grep -Eqi "5090|5080|5070|5060|Blackwell|H100|H200"; then
    if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && [ "$DRIVER_MAJOR" -lt 580 ]; then
      reallocate "NVIDIA driver ${DRIVER} < 580 required by OneZeroMiner on Blackwell"
    fi
  fi
fi

echo "[boot] Starting OneZeroMiner -> pool=${POOL} worker=${WORKER} min_ths=${MIN_THS}"
/miner/onezerominer \
  --disable-amd \
  -a pearlhash \
  -o "$POOL" \
  -w "$WALLET" \
  -p "$PASS" \
  --worker "$WORKER" \
  --api-host 127.0.0.1 \
  --api-port 3001 \
  --disable-telemetry &
MINER_PID=$!

trap 'kill "$MINER_PID" 2>/dev/null || true; exit 0' TERM INT

# Warmup while verifying the miner stays alive
ELAPSED=0
while [ "$ELAPSED" -lt "$WARMUP_SEC" ]; do
  if ! kill -0 "$MINER_PID" 2>/dev/null; then
    reallocate "Miner crashed during warmup"
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

LOW_STREAK=0
while true; do
  if ! kill -0 "$MINER_PID" 2>/dev/null; then
    reallocate "Miner process exited unexpectedly"
  fi

  RAW_HR=$(curl -fsS --max-time 5 --noproxy "*" http://127.0.0.1:3001/ 2>/dev/null \
    | jq -r '(.algos[0].total_hashrate // .total_hashrate // 0)' 2>/dev/null || echo "0")

  THS=$(awk -v hr="$RAW_HR" 'BEGIN { printf "%.2f", (hr + 0) / 1e12 }')
  echo "[watchdog] raw_hr=${RAW_HR} (~${THS} TH/s) | min_ths=${MIN_THS}"

  IS_LOW=$(awk -v th="$THS" -v min="$MIN_THS" 'BEGIN { print (min > 0 && th < min) ? 1 : 0 }')
  if [ "$IS_LOW" -eq 1 ]; then
    LOW_STREAK=$((LOW_STREAK + 1))
    if [ "$LOW_STREAK" -ge 3 ]; then
      kill "$MINER_PID" 2>/dev/null || true
      reallocate "Sustained low hashrate: ${THS} TH/s < ${MIN_THS} TH/s"
    fi
  else
    LOW_STREAK=0
  fi

  sleep 60
done
