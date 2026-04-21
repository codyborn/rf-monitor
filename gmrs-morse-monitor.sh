#!/bin/bash
# GMRS Morse (CW) + DTMF Monitor — decode and log automated IDs
# Usage: ./gmrs-morse-monitor.sh [--main|--frs|--repeaters|--all]
#                                [--record] [--match=REGEX] [--log=FILE]
#
# Requires:  rtl_fm, multimon-ng  (sox only if --record)
#
# Install multimon-ng on macOS (not in Homebrew):
#   git clone https://github.com/EliasOenal/multimon-ng.git /tmp/multimon-ng
#   cd /tmp/multimon-ng && mkdir build && cd build \
#     && cmake .. && make && sudo make install
#
# On Termux: pkg install multimon-ng

MAIN=(462.5500 462.5750 462.6000 462.6250 462.6500 462.6750 462.7000 462.7250)
FRS=(462.5625 462.5875 462.6125 462.6375 462.6625 462.6875 462.7125)
INPUTS=(467.5500 467.5750 467.6000 467.6250 467.6500 467.6750 467.7000 467.7250)

MODE="main"
RECORD=false
MATCH=""
LOGFILE="gmrs_morse.log"
SQUELCH=100
GAIN=40

for arg in "$@"; do
    case $arg in
        --main)      MODE="main" ;;
        --frs)       MODE="frs" ;;
        --repeaters) MODE="repeaters" ;;
        --all)       MODE="all" ;;
        --record)    RECORD=true ;;
        --match=*)   MATCH="${arg#*=}" ;;
        --log=*)     LOGFILE="${arg#*=}" ;;
        --squelch=*) SQUELCH="${arg#*=}" ;;
        --gain=*)    GAIN="${arg#*=}" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  --main        8 GMRS primary channels (default)
  --frs         7 FRS/GMRS interstitial channels
  --repeaters   8 repeater input freqs (467 MHz)
  --all         All 23 channels
  --record      Save audio WAVs alongside decode log
  --match=RE    Flag+beep on lines matching regex (e.g. 'WRDH ?247')
  --log=FILE    Log file path (default: gmrs_morse.log)
  --squelch=N   rtl_fm squelch (default 100; lower = more sensitive)
  --gain=N      Tuner gain dB (default 40; 0=auto)

Decoders: MORSE_CW + DTMF (both active simultaneously).
WRDH247 in Morse = .-- .-. -.. ....  ..--- ....- --...

Example: $0 --all --match='WRDH ?247' --record
EOF
            exit 0
            ;;
    esac
done

if ! command -v multimon-ng >/dev/null 2>&1; then
    echo "ERROR: multimon-ng not installed."
    echo "Install on macOS:"
    echo "  git clone https://github.com/EliasOenal/multimon-ng.git /tmp/multimon-ng"
    echo "  cd /tmp/multimon-ng && mkdir build && cd build && cmake .. && make && sudo make install"
    exit 1
fi

case $MODE in
    main)      CHANS=("${MAIN[@]}") ;;
    frs)       CHANS=("${FRS[@]}") ;;
    repeaters) CHANS=("${INPUTS[@]}") ;;
    all)       CHANS=("${MAIN[@]}" "${FRS[@]}" "${INPUTS[@]}") ;;
esac

FARGS=()
for f in "${CHANS[@]}"; do FARGS+=(-f "${f}M"); done

echo "Morse/DTMF scanner: ${#CHANS[@]} channel(s): ${CHANS[*]}"
echo "Log: $LOGFILE"
[ -n "$MATCH" ] && echo "Match regex: $MATCH"
echo "Press Ctrl+C to stop"
echo "---"

# awk filter: timestamp decoder lines, write to log, beep on match
AWK_PROG='
/^(CW:|DTMF:)/ {
    ts = strftime("%Y-%m-%d %H:%M:%S")
    line = ts " | " $0
    print line
    print line >> logfile
    fflush(logfile)
    fflush()
    if (match_re != "" && $0 ~ match_re) {
        alert = ts " *** MATCH *** " $0
        print alert
        print alert >> logfile
        fflush(logfile)
        system("printf \"\\a\"")
    }
}'

MMNG=(multimon-ng -t raw -a MORSE_CW -a DTMF -q /dev/stdin)
# rtl_fm NFM at 22050 Hz — multimon-ng's native expected rate
RTL_FM=(rtl_fm -M fm -s 22050 -l "$SQUELCH" -g "$GAIN" "${FARGS[@]}" -)

if [ "$RECORD" = true ]; then
    if ! command -v sox >/dev/null 2>&1; then
        echo "ERROR: --record requires sox (brew install sox)"; exit 1
    fi
    STAMP=$(date +%Y%m%d_%H%M%S)
    OUTDIR="gmrs_recordings/$STAMP"
    mkdir -p "$OUTDIR"
    LOGFILE="$OUTDIR/morse.log"
    echo "Audio: $OUTDIR/tx*.wav   Log: $LOGFILE"

    # tee PCM: branch to multimon-ng (decode) + sox (silence-split WAVs)
    "${RTL_FM[@]}" \
        2> >(while IFS= read -r l; do
                 printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$l"
             done > "$OUTDIR/scan.log") \
      | tee \
          >("${MMNG[@]}" 2>/dev/null \
              | awk -v logfile="$LOGFILE" -v match_re="$MATCH" "$AWK_PROG") \
          >(sox -t raw -r 22050 -e signed -b 16 -c 1 - \
                "$OUTDIR/tx.wav" \
                silence 1 0.1 1% 1 2.0 1% : newfile : restart 2>/dev/null) \
      > /dev/null
else
    "${RTL_FM[@]}" 2>/dev/null \
      | "${MMNG[@]}" 2>/dev/null \
      | awk -v logfile="$LOGFILE" -v match_re="$MATCH" "$AWK_PROG"
fi
