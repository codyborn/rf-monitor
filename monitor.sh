#!/bin/bash
# RTL-SDR 433/915 MHz Signal Monitor
# Usage: ./monitor.sh [--433] [--915] [--log] [--save]

FREQS="-f 433.92M -f 915M"
EXTRA=""

for arg in "$@"; do
    case $arg in
        --433)  FREQS="-f 433.92M" ;;
        --915)  FREQS="-f 915M" ;;
        --log)  EXTRA="$EXTRA -F json:sensor_log.jsonl" ;;
        --save) EXTRA="$EXTRA -S all" ;;
        -h|--help)
            echo "Usage: $0 [--433] [--915] [--log] [--save]"
            echo "  --433   433.92 MHz only"
            echo "  --915   915 MHz only"
            echo "  --log   Append decoded JSON to sensor_log.jsonl"
            echo "  --save  Save raw .cu8 signal files"
            exit 0
            ;;
    esac
done

echo "Monitoring: $FREQS"
echo "Press Ctrl+C to stop"
echo "---"

rtl_433 $FREQS \
    -H 10 \
    -M level \
    -M time:iso \
    -Y minlevel=-30 \
    -F kv \
    $EXTRA \
    2>&1 | awk '{
        if (match($0, /RSSI[ ]*:[ ]*([-0-9.]+)[ ]*dB/, m)) {
            rssi = m[1] + 0
            if      (rssi > -5)  dist = "~0-5m"
            else if (rssi > -10) dist = "~5-20m"
            else if (rssi > -15) dist = "~20-50m"
            else if (rssi > -20) dist = "~50-100m"
            else if (rssi > -25) dist = "~100-200m"
            else                 dist = ">200m"
            printf "%s  Est: %s\n", $0, dist
        } else {
            print
        }
        fflush()
    }'
