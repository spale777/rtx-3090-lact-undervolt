# RTX 3090 undervolt via LACT

## Goal
Effectively undervolt RTX 3090 GPUs on Linux: ~230–250 W sustained draw, +200 MHz
clock offset, **no power limit**, applied automatically at boot.

## Method
NVIDIA exposes no direct voltage control on Linux, so the undervolt is done indirectly:

1. **+200 MHz core clock offset** — shifts the voltage/frequency curve so every
   voltage point yields 200 MHz more than stock. Applied to **P0** (graphics load)
   and **P2** (CUDA/compute load — GeForce cards run compute in P2, not P0).
2. **Locked clock range 300–1700 MHz** — the card reaches 1700 MHz at the voltage
   stock used for ~1500 MHz (~0.75–0.78 V) and can't climb higher up the curve.
   Result: ~230–240 W sustained instead of ~350 W. `power_cap` is never set, so the
   power limit stays stock.

LACT implements this via NVML: `set_gpu_locked_clocks` (needs `min_core_clock` +
`max_core_clock` together) and `set_clock_offset` per pstate. Config lives in
`/etc/lact/config.yaml` under `gpus.<id>`; relevant fields: `min_core_clock`,
`max_core_clock`, `gpu_clock_offsets: {0: 200, 2: 200}`.

## Files
- `lact-3090-undervolt.sh` — idempotent root script: waits for lactd, discovers all
  GPUs matching "3090" via `lact cli list-gpus`, merges the settings into
  `/etc/lact/config.yaml` (PyYAML merge preserving fan curves; falls back to a
  backed-up fresh config), removes any `power_cap`. Tunables at the top:
  `MIN_CLOCK=300`, `MAX_CLOCK=1700`, `CLOCK_OFFSET=200`, `GPU_MATCH="3090"`.
- `lact-3090-undervolt.service` — optional systemd oneshot (After=lactd.service).

## Requirements
- [LACT](https://github.com/ilya-zlobintsev/LACT) (headless build is enough) —
  download the `.deb`/`.rpm` from the
  [releases page](https://github.com/ilya-zlobintsev/LACT/releases).
- NVIDIA proprietary driver with NVML working (`nvidia-smi` functional).
- `python3` with PyYAML recommended (preserves existing LACT config on merge).

## Install (on the 3090 server)
```bash
# 1. Install headless LACT (deb/rpm from https://github.com/ilya-zlobintsev/LACT/releases)
apt install ./lact-headless-*.deb        # move .deb out of /root to avoid _apt warning
systemctl enable --now lactd
lact cli list-gpus                       # must show the 3090s (needs NVIDIA driver/NVML)

# 2. Install the script
cp lact-3090-undervolt.sh /usr/local/bin/ && chmod +x /usr/local/bin/lact-3090-undervolt.sh
cp lact-3090-undervolt.service /etc/systemd/system/
systemctl enable --now lact-3090-undervolt.service
```
Strictly, lactd alone re-applies the config every boot once the script has run once;
the systemd unit is belt-and-braces.

## Verify / tune
```bash
nvidia-smi --query-gpu=clocks.sm,power.draw --format=csv -l 2
```
Expect ~1700 MHz steady under load at ~230–240 W. Raise `MAX_CLOCK` toward 1800 for
~250 W / more performance; lower it if unstable. If lactd logs an error applying the
P2 offset (`journalctl -u lactd`), drop the `2:` entry — the global clock lock still
covers compute.

## Notes
- Proxmox: run LACT + this script on the **PVE host**, not inside LXCs — containers
  can't set locked clocks/offsets; they inherit the host's settings.
  (`pct enter <ctid>` to shell into a container.)
