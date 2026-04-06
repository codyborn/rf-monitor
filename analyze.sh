#!/bin/bash
# Analyze captured .cu8 signal files
# Usage: ./analyze.sh [file.cu8] or ./analyze.sh (analyzes all)

echo "=========================================="
echo " Signal File Analyzer"
echo "=========================================="

analyze_file() {
    local file="$1"
    local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    local freq_hint=""

    # Extract frequency from filename
    if [[ "$file" == *"433"* ]]; then
        freq_hint="433.92 MHz"
    elif [[ "$file" == *"915"* ]]; then
        freq_hint="915 MHz"
    fi

    echo ""
    echo "--- $file (${size} bytes, $freq_hint) ---"

    # Try known protocol decode first
    decoded=$(rtl_433 -r "$file" 2>&1 | grep -E "^{|model|id|temperature|humidity|battery|channel" | head -5)
    if [ -n "$decoded" ]; then
        echo "DECODED: $decoded"
    fi

    # Pulse analysis
    rtl_433 -r "$file" -A 2>&1 | grep -E "Detected|Total count|RSSI|SNR|Noise|Frequency offset|Guessing|Pulse width dist|Gap width dist|Level est" | while read line; do
        # Strip ANSI color codes
        clean=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')
        echo "  $clean"
    done
}

if [ $# -gt 0 ]; then
    for file in "$@"; do
        analyze_file "$file"
    done
else
    # Analyze all .cu8 files, sorted by modification time
    files=$(ls -t *.cu8 2>/dev/null)
    if [ -z "$files" ]; then
        echo "No .cu8 files found in current directory"
        exit 1
    fi
    count=$(echo "$files" | wc -l | tr -d ' ')
    echo "Found $count signal files"
    for file in $files; do
        analyze_file "$file"
    done
fi

echo ""
echo "=========================================="
echo "Tip: View pulse visualizations at triq.org/pdv"
echo "Tip: Re-run with -A on individual files for detailed timing"
echo "=========================================="
