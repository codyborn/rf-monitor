#!/bin/bash
# Review recorded GMRS transmissions
# Usage: ./gmrs-analyze.sh [directory]   (default: most recent recording session)

DIR="${1:-}"
if [ -z "$DIR" ]; then
    DIR=$(ls -td gmrs_recordings/*/ 2>/dev/null | head -1)
    if [ -z "$DIR" ]; then
        echo "No recordings found in ./gmrs_recordings/"
        echo "Run: ./gmrs-monitor.sh --record"
        exit 1
    fi
fi
DIR="${DIR%/}"

if [ ! -d "$DIR" ]; then
    echo "Not a directory: $DIR"
    exit 1
fi

echo "=========================================="
echo " GMRS Recording Review: $DIR"
echo "=========================================="

shopt -s nullglob
files=("$DIR"/tx*.wav)
if [ ${#files[@]} -eq 0 ]; then
    echo "No tx*.wav files found"
    exit 0
fi

# Header
printf "%-18s %10s %8s  %s\n" "File" "Bytes" "Duration" "Captured"
printf "%-18s %10s %8s  %s\n" "----" "-----" "--------" "--------"

# WAV at 22050 Hz, 16-bit mono = 44100 bytes/sec. Subtract 44-byte WAV header.
total_dur=0
for f in "${files[@]}"; do
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
    dur=$(awk "BEGIN { printf \"%.1f\", ($size - 44) / 44100 }")
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f" 2>/dev/null \
            || stat -c "%y" "$f" 2>/dev/null | cut -d. -f1)
    printf "%-18s %10s %6ss   %s\n" "$(basename "$f")" "$size" "$dur" "$mtime"
    total_dur=$(awk "BEGIN { print $total_dur + $dur }")
done

echo "---"
echo "Total: ${#files[@]} transmissions, ${total_dur}s of audio"

if [ -f "$DIR/scan.log" ]; then
    echo ""
    echo "Channel activity (from scan.log):"
    # rtl_fm prints "Tuned to <Hz>" when hopping. Filter & show frequency.
    grep -E "Tuned to|Signal" "$DIR/scan.log" 2>/dev/null \
        | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+$/ && $i > 400000000) {
                    freq = $i / 1000000
                    printf "%s %s  %.4f MHz\n", $1, $2, freq
                    next
                }
            }
            print
        }' | tail -20
fi

echo ""
echo "=========================================="
echo "Play one:     play $DIR/tx001.wav"
echo "Play all:     for f in $DIR/tx*.wav; do play -q \"\$f\"; done"
echo "Transcribe:   whisper $DIR/tx001.wav --language en --model base"
echo "  (install: pip install openai-whisper)"
echo "Bulk search:  for f in $DIR/tx*.wav; do"
echo "                whisper \"\$f\" --model base --output_format txt"
echo "              done && grep -l -iE 'WRDH|two.four.seven' $DIR/*.txt"
echo "=========================================="
