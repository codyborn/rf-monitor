#!/data/data/com.termux/files/usr/bin/bash
# Multi-band RF presence scanner for a single RTL-SDR (Termux)
# Toggles through all bands of interest and logs any detected signal.
#
# Use this as a first-pass surveillance tool — when a band shows hits,
# switch to the specialized decoder for that band:
#   ism433 / ism915  -> ./monitor.sh --save + ./analyze.sh
#   gmrs             -> ./gmrs-monitor.sh or ./gmrs-morse-monitor.sh
#   swarm / iridium  -> ./sat-detect.sh (more focused dwell)
#
# Prerequisite: install-termux-satdetect.sh has been run (installs sat-detect.py).

BANDS=(
    --band=swarm:137:138            # 1 tuning step
    --band=ism433:433:435           # 1 step
    --band=gmrs:462:467.725         # 3 steps
    --band=ism915:902:928           # 13 steps (widest band)
    --band=iridium:1616:1626.5      # 5 steps
)
# Full sweep = ~23 tuning steps. At 0.1s dwell each, one cycle ~2.5s.

EXTRA=(--log=rf-scan.log)

for arg in "$@"; do
    case $arg in
        --no-ism433)   BANDS=("${BANDS[@]/--band=ism433:433:435/}") ;;
        --no-ism915)   BANDS=("${BANDS[@]/--band=ism915:902:928/}") ;;
        --no-gmrs)     BANDS=("${BANDS[@]/--band=gmrs:462:467.725/}") ;;
        --no-swarm)    BANDS=("${BANDS[@]/--band=swarm:137:138/}") ;;
        --no-iridium)  BANDS=("${BANDS[@]/--band=iridium:1616:1626.5/}") ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Band selection:
  --no-ism433       Skip 433–435 MHz (ISM sensor traffic)
  --no-ism915       Skip 902–928 MHz (widest band; biggest cycle-time win)
  --no-gmrs         Skip 462–467.725 MHz (GMRS)
  --no-swarm        Skip 137–138 MHz (Swarm sats + NOAA WX)
  --no-iridium      Skip 1616–1626.5 MHz (Iridium L-band)

Detection tuning:
  --threshold=N     dB over noise-floor median to log a detection (default 10)
  --dwell=S         Seconds per tuning step (default 0.1)
  --gain=N          Tuner gain dB (default 40; 0 = auto)
  --n-fft=N         FFT size / frequency-bin resolution (default 1024)
  --samp=N          IQ sample rate in Hz (default 2400000)

Connection:
  --host=IP         rtl_tcp host (default 127.0.0.1)
  --port=N          rtl_tcp port (default 14423)

Output:
  --log=FILE        Detection log (default rf-scan.log)
  -h, --help        This message

Default bands (23 tuning steps, ~2.5s per full cycle):
  swarm    137–138 MHz
  ism433   433–435 MHz
  gmrs     462–467.725 MHz
  ism915   902–928 MHz
  iridium  1616–1626.5 MHz

Output format:
  TIMESTAMP [band] FREQ MHz +N.N dB over noise

Requires SDR Driver app serving rtl_tcp on 127.0.0.1:14423.
EOF
            exit 0 ;;
        *) EXTRA+=("$arg") ;;
    esac
done

exec python "$HOME/radio/sat-detect.py" "${BANDS[@]}" "${EXTRA[@]}"
