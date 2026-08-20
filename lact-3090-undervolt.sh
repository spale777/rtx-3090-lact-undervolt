#!/usr/bin/env bash
# lact-3090-undervolt.sh
#
# Effective undervolt for RTX 3090 GPUs via LACT, without touching the power limit.
#
# Method (NVIDIA has no direct voltage control on Linux):
#   1. Apply a +200 MHz core clock offset. This shifts the whole voltage/frequency
#      curve up: every voltage point now yields 200 MHz more than stock.
#   2. Lock the clock range to 300..MAX_CLOCK MHz. The GPU now reaches MAX_CLOCK
#      while sitting on the voltage stock would have used for (MAX_CLOCK - 200) MHz.
#   With MAX_CLOCK=1700 the 3090 runs 1700 MHz at roughly the stock 1500 MHz
#   voltage point (~0.79-0.82 V), which lands around 250 W under sustained load
#   instead of ~350 W. No power cap is set - transient draw is unrestricted.
#
# The settings are written to /etc/lact/config.yaml. The LACT daemon (lactd)
# watches the config and applies it immediately, and re-applies it on every boot,
# so strictly this script only needs to run once - but it is idempotent and safe
# to run from a systemd oneshot at boot as a belt-and-braces re-apply.
#
# Requires: lactd running (systemctl enable --now lactd), run as root.

set -euo pipefail

MIN_CLOCK=300      # MHz, lower bound of the locked range (idle clocks stay low)
MAX_CLOCK=1700     # MHz, locked ceiling -> ~230-240 W on a 3090 with the offset below
CLOCK_OFFSET=200   # MHz, positive V/F curve offset = the actual undervolt
GPU_MATCH="3090"   # only touch GPUs whose name matches this
CONFIG=/etc/lact/config.yaml

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

# Wait for the LACT daemon to be up (relevant when run at boot)
for _ in $(seq 1 30); do
    if lact cli list-gpus &>/dev/null; then
        break
    fi
    sleep 1
done

# Discover matching GPU IDs. `lact cli list-gpus` prints lines like:
#   0: 10DE:2204-1458:403B-0000:0b:00.0 (NVIDIA GeForce RTX 3090) [Nvidia]
mapfile -t GPU_IDS < <(lact cli list-gpus | grep -i "$GPU_MATCH" | sed -E 's/^[0-9]+: ([^ ]+) .*/\1/')

if [[ ${#GPU_IDS[@]} -eq 0 ]]; then
    echo "no GPUs matching '$GPU_MATCH' found" >&2
    exit 1
fi
echo "found ${#GPU_IDS[@]} matching GPU(s): ${GPU_IDS[*]}"

if python3 -c 'import yaml' &>/dev/null; then
    # Merge into the existing config, preserving fan curves and other settings.
    GPU_IDS="${GPU_IDS[*]}" MIN_CLOCK=$MIN_CLOCK MAX_CLOCK=$MAX_CLOCK \
    CLOCK_OFFSET=$CLOCK_OFFSET CONFIG=$CONFIG python3 - <<'EOF'
import os, yaml

path = os.environ["CONFIG"]
try:
    with open(path) as f:
        config = yaml.safe_load(f) or {}
except FileNotFoundError:
    config = {}

gpus = config.setdefault("gpus", {})
for gpu_id in os.environ["GPU_IDS"].split():
    gpu = gpus.setdefault(gpu_id, {})
    gpu["min_core_clock"] = int(os.environ["MIN_CLOCK"])
    gpu["max_core_clock"] = int(os.environ["MAX_CLOCK"])
    offsets = gpu.setdefault("gpu_clock_offsets", {})
    # P0 = graphics load, P2 = CUDA/compute load on GeForce
    offsets[0] = int(os.environ["CLOCK_OFFSET"])
    offsets[2] = int(os.environ["CLOCK_OFFSET"])
    # make sure no power limit is configured
    gpu.pop("power_cap", None)

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    yaml.safe_dump(config, f, sort_keys=False)
print(f"updated {path}")
EOF
else
    # No PyYAML: write a fresh config (backing up any existing one).
    [[ -f $CONFIG ]] && cp "$CONFIG" "$CONFIG.bak.$(date +%s)" && echo "backed up existing config to $CONFIG.bak.*"
    mkdir -p "$(dirname "$CONFIG")"
    {
        echo "gpus:"
        for id in "${GPU_IDS[@]}"; do
            echo "  $id:"
            echo "    min_core_clock: $MIN_CLOCK"
            echo "    max_core_clock: $MAX_CLOCK"
            echo "    gpu_clock_offsets:"
            echo "      0: $CLOCK_OFFSET"
            echo "      2: $CLOCK_OFFSET"
        done
    } > "$CONFIG"
    echo "wrote fresh $CONFIG"
fi

# lactd watches the config file and applies changes automatically;
# nothing else to do. Show the result:
sleep 2
nvidia-smi --query-gpu=index,name,clocks.max.sm,power.draw --format=csv || true
