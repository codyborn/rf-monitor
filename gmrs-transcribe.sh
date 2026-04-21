#!/bin/bash
# Transcribe recorded GMRS WAVs and search for callsign IDs
# Usage: ./gmrs-transcribe.sh [directory] [--match=REGEX] [--model=base|small|medium]
#
# Requires: whisper (pip install openai-whisper), ffmpeg (brew install ffmpeg)
#
# Covers the "voice ID" case that multimon-ng can't handle: a live operator or
# synthesized announcement speaking the callsign. Writes a combined log of
# file/time/transcript and highlights regex matches.

DIR=""
# Default match: WRDH247 or phonetic variants (NATO + spelled-out digits)
MATCH='WRDH ?247|W ?R ?D ?H|whiskey.{0,5}romeo.{0,5}delta.{0,5}hotel|two.{0,3}four.{0,3}seven'
MODEL="base"
LANG="en"

for arg in "$@"; do
    case $arg in
        --match=*) MATCH="${arg#*=}" ;;
        --model=*) MODEL="${arg#*=}" ;;
        --lang=*)  LANG="${arg#*=}" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [directory] [options]
  directory         gmrs_recordings/<timestamp>/ (default: most recent)
  --match=REGEX     Highlight transcripts matching this regex (extended)
                    Default matches WRDH247 + phonetic variants
  --model=NAME      Whisper model: tiny|base|small|medium|large (default: base)
                    Smaller = faster/lower accuracy, larger = slower/better
  --lang=CODE       Language hint (default: en)

Writes <dir>/transcripts.log with lines: TIMESTAMP | FILE | TEXT
Each WAV also gets a .txt sidecar, so reruns skip already-transcribed files.
EOF
            exit 0
            ;;
        *) [ -z "$DIR" ] && DIR="$arg" ;;
    esac
done

if ! command -v whisper >/dev/null 2>&1; then
    echo "ERROR: whisper not installed."
    echo "Install:  pip install openai-whisper"
    echo "Also needs ffmpeg:  brew install ffmpeg"
    exit 1
fi

if [ -z "$DIR" ]; then
    DIR=$(ls -td gmrs_recordings/*/ 2>/dev/null | head -1)
    if [ -z "$DIR" ]; then
        echo "No recordings found in ./gmrs_recordings/"
        echo "Run: ./gmrs-morse-monitor.sh --record"
        exit 1
    fi
fi
DIR="${DIR%/}"
[ -d "$DIR" ] || { echo "Not a directory: $DIR"; exit 1; }

shopt -s nullglob
files=("$DIR"/tx*.wav)
if [ ${#files[@]} -eq 0 ]; then
    echo "No tx*.wav files in $DIR"
    exit 0
fi

OUT="$DIR/transcripts.log"
echo "=========================================="
echo " GMRS Transcription: $DIR"
echo " Whisper model: $MODEL   Match: $MATCH"
echo " Found ${#files[@]} recording(s)"
echo "=========================================="

hits=0
for wav in "${files[@]}"; do
    txt="${wav%.wav}.txt"
    base=$(basename "$wav")

    if [ ! -s "$txt" ]; then
        echo "[transcribing] $base"
        whisper "$wav" \
            --model "$MODEL" \
            --language "$LANG" \
            --output_format txt \
            --output_dir "$DIR" \
            --fp16 False \
            > /dev/null 2>&1 \
            || { echo "  (whisper failed on $base)"; continue; }
    fi

    [ -s "$txt" ] || continue
    content=$(tr '\n' ' ' < "$txt" | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$wav" 2>/dev/null \
            || stat -c "%y" "$wav" 2>/dev/null | cut -d. -f1)

    line=$(printf '%s | %s | %s' "$mtime" "$base" "$content")
    echo "$line" | tee -a "$OUT" > /dev/null
    echo "$line"

    if echo "$content" | grep -iEq "$MATCH"; then
        hits=$((hits + 1))
        printf '\a'
        echo "*** MATCH ($base): $content"
        echo "*** MATCH ($base): $content" >> "$OUT"
    fi
done

echo ""
echo "=========================================="
echo " Done. ${#files[@]} files, $hits match(es)."
echo " Log: $OUT"
[ $hits -gt 0 ] && echo " Grep matches: grep -E 'MATCH' $OUT"
echo "=========================================="
