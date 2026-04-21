#!/bin/bash
# GMRS Voice Monitor — listen to or record GMRS traffic
# Usage: ./gmrs-monitor.sh [--main|--frs|--repeaters|--all] [--record] [--squelch=N] [--gain=N]
#
# Requires: rtl_fm (brew install librtlsdr), sox (brew install sox)

# Main GMRS channels (simplex + repeater outputs), 25 kHz spacing
MAIN=(462.5500 462.5750 462.6000 462.6250 462.6500 462.6750 462.7000 462.7250)
# FRS/GMRS interstitial channels (shared with FRS, lower power limits apply to FRS)
FRS=(462.5625 462.5875 462.6125 462.6375 462.6625 462.6875 462.7125)
# Repeater inputs (what handhelds transmit TO a repeater on)
INPUTS=(467.5500 467.5750 467.6000 467.6250 467.6500 467.6750 467.7000 467.7250)

MODE="main"
RECORD=false
SQUELCH=100
GAIN=40

for arg in "$@"; do
    case $arg in
        --main)      MODE="main" ;;
        --frs)       MODE="frs" ;;
        --repeaters) MODE="repeaters" ;;
        --all)       MODE="all" ;;
        --record)    RECORD=true ;;
        --squelch=*) SQUELCH="${arg#*=}" ;;
        --gain=*)    GAIN="${arg#*=}" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  --main        8 GMRS primary channels (default)
  --frs         7 FRS/GMRS interstitial channels
  --repeaters   8 repeater input freqs (467 MHz) - what handhelds TX
  --all         All 23 channels
  --record      Save to ./gmrs_recordings/<timestamp>/, split per transmission
  --squelch=N   Squelch threshold (default 100; lower=more sensitive, 0=off)
  --gain=N      RF gain in dB (default 40; 0=auto)

Default mode is live-listen through speakers. Add --record to save WAVs
instead. Each transmission becomes its own file; cross-reference scan.log
to see which channel it came from.

Then analyze with: ./gmrs-analyze.sh
EOF
            exit 0
            ;;
    esac
done

case $MODE in
    main)      CHANS=("${MAIN[@]}") ;;
    frs)       CHANS=("${FRS[@]}") ;;
    repeaters) CHANS=("${INPUTS[@]}") ;;
    all)       CHANS=("${MAIN[@]}" "${FRS[@]}" "${INPUTS[@]}") ;;
esac

FARGS=()
for f in "${CHANS[@]}"; do FARGS+=(-f "${f}M"); done

echo "Monitoring ${#CHANS[@]} channel(s): ${CHANS[*]}"
echo "Squelch: $SQUELCH  Gain: $GAIN  Mode: NFM"
echo "Listening for callsigns in voice IDs (e.g. WRDH247)"

# rtl_fm scan settings: narrow FM, 12.5 kHz channel resampled to 22050 Hz audio
RTL_FM_ARGS=(-M fm -s 22050 -l "$SQUELCH" -g "$GAIN" "${FARGS[@]}" -)

if [ "$RECORD" = true ]; then
    STAMP=$(date +%Y%m%d_%H%M%S)
    OUTDIR="gmrs_recordings/$STAMP"
    mkdir -p "$OUTDIR"
    echo "Recording to: $OUTDIR/  (tx001.wav, tx002.wav, ...)"
    echo "Press Ctrl+C to stop"
    echo "---"

    rtl_fm "${RTL_FM_ARGS[@]}" \
        2> >(while IFS= read -r line; do
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
             done > "$OUTDIR/scan.log") \
        | sox -t raw -r 22050 -e signed -b 16 -c 1 - \
              "$OUTDIR/tx.wav" \
              silence 1 0.1 1% 1 2.0 1% : newfile : restart
else
    echo "Live listening — press Ctrl+C to stop"
    echo "---"
    rtl_fm "${RTL_FM_ARGS[@]}" 2>/dev/null \
        | play -q -r 22050 -t raw -e signed -b 16 -c 1 -
fi
