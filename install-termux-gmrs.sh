#!/data/data/com.termux/files/usr/bin/bash
# GMRS Voice Monitor — Termux Install Script
# Run this inside Termux. Pairs with the existing install-termux.sh (433/915 setup).
#
# Unlike rtl_433, rtl_fm can't talk to rtl_tcp directly, so this installs a small
# Python bridge that reads IQ from rtl_tcp, does narrow-FM demodulation with
# channel scanning + squelch, and emits PCM for sox/play.
#
# Usage: bash install-termux-gmrs.sh

set -e

echo "=== GMRS Voice Monitor — Termux Setup ==="
echo ""

# 1. Install deps
echo "[1/2] Installing sox + python + numpy..."
pkg install -y sox python python-numpy

# 2. Write scripts to ~/radio/
echo "[2/2] Installing scripts to ~/radio/..."
mkdir -p "$HOME/radio"

# --- gmrs-rx.py: NFM scanner via rtl_tcp, PCM to stdout ---------------------
cat > "$HOME/radio/gmrs-rx.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Narrow-FM scanner over rtl_tcp. Emits 24 kHz signed-16 mono PCM on stdout.
Squelch opens on RMS threshold; cycles channels when closed, holds when open.
"""
import socket, struct, sys, argparse
import numpy as np

SAMP_RATE = 240_000
AUDIO_RATE = 24_000
DECIM = SAMP_RATE // AUDIO_RATE          # = 10

def send_cmd(s, cmd, param):
    s.sendall(struct.pack('>BI', cmd, param))

def connect(host, port, gain):
    s = socket.socket()
    s.connect((host, port))
    s.recv(12)                             # skip "RTL0"+tuner info header
    send_cmd(s, 0x02, SAMP_RATE)
    send_cmd(s, 0x03, 0 if gain == 0 else 1)   # 0=auto gain, 1=manual
    if gain > 0:
        send_cmd(s, 0x04, gain * 10)       # gain in 0.1 dB steps
    return s

def read_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("rtl_tcp stream closed")
        buf.extend(chunk)
    return bytes(buf)

def demod_nfm(iq_bytes):
    """8-bit unsigned IQ -> instantaneous phase differential (NFM audio)."""
    x = np.frombuffer(iq_bytes, dtype=np.uint8).astype(np.float32) - 127.5
    z = x[0::2] + 1j * x[1::2]
    return np.angle(z[1:] * np.conj(z[:-1])).astype(np.float32)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=14423)
    ap.add_argument('--freq', action='append', type=float, required=True,
                    help='channel in MHz, repeatable')
    ap.add_argument('--gain', type=int, default=40, help='dB; 0=auto')
    ap.add_argument('--squelch', type=float, default=0.4,
                    help='RMS threshold on NFM audio (0..pi)')
    ap.add_argument('--dwell', type=float, default=0.1,
                    help='seconds per channel while scanning')
    args = ap.parse_args()

    freqs = [int(f * 1e6) for f in args.freq]
    s = connect(args.host, args.port, args.gain)
    chunk_iq_bytes = int(SAMP_RATE * args.dwell) * 2
    lpf = np.ones(DECIM, dtype=np.float32) / DECIM

    i = 0
    held = False
    sys.stderr.write(f"scanning {len(freqs)} channel(s) dwell={args.dwell}s\n")
    sys.stderr.flush()

    try:
        while True:
            if not held:
                send_cmd(s, 0x01, freqs[i])
                read_exact(s, chunk_iq_bytes // 4)   # flush retune transient

            data = read_exact(s, chunk_iq_bytes)
            audio = demod_nfm(data)
            level = float(np.sqrt(np.mean(audio * audio))) if len(audio) else 0.0

            if level >= args.squelch:
                if not held:
                    sys.stderr.write(
                        f"[signal] {freqs[i]/1e6:.4f} MHz level={level:.2f}\n")
                    sys.stderr.flush()
                held = True
                # simple boxcar LPF + decimation
                filt = np.convolve(audio, lpf, mode='valid')[::DECIM]
                pcm = (filt / np.pi * 32767 * 0.8).clip(
                    -32767, 32767).astype(np.int16)
                sys.stdout.buffer.write(pcm.tobytes())
                sys.stdout.buffer.flush()
            else:
                if held:
                    sys.stderr.write(f"[clear] {freqs[i]/1e6:.4f} MHz\n")
                    sys.stderr.flush()
                held = False
                i = (i + 1) % len(freqs)
    except (KeyboardInterrupt, BrokenPipeError, ConnectionError):
        pass
    finally:
        s.close()

if __name__ == '__main__':
    main()
PYEOF
chmod +x "$HOME/radio/gmrs-rx.py"

# --- gmrs-monitor.sh: shell wrapper with listen/record modes ----------------
cat > "$HOME/radio/gmrs-monitor.sh" << 'SHEOF'
#!/data/data/com.termux/files/usr/bin/bash
# GMRS Voice Monitor (Termux, via rtl_tcp + SDR Driver app)
# Usage: ./gmrs-monitor.sh [--main|--frs|--repeaters|--all] [--record]
#
# Requires SDR Driver app running with rtl_tcp server on 127.0.0.1:14423.

MAIN="462.5500 462.5750 462.6000 462.6250 462.6500 462.6750 462.7000 462.7250"
FRS="462.5625 462.5875 462.6125 462.6375 462.6625 462.6875 462.7125"
INPUTS="467.5500 467.5750 467.6000 467.6250 467.6500 467.6750 467.7000 467.7250"

MODE="main"
RECORD=false
SQUELCH=0.4
GAIN=40
HOST="127.0.0.1"
PORT="14423"

for arg in "$@"; do
    case $arg in
        --main)      MODE="main" ;;
        --frs)       MODE="frs" ;;
        --repeaters) MODE="repeaters" ;;
        --all)       MODE="all" ;;
        --record)    RECORD=true ;;
        --squelch=*) SQUELCH="${arg#*=}" ;;
        --gain=*)    GAIN="${arg#*=}" ;;
        --host=*)    HOST="${arg#*=}" ;;
        --port=*)    PORT="${arg#*=}" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  --main        8 GMRS primary channels (default)
  --frs         7 FRS/GMRS interstitial channels
  --repeaters   8 repeater input freqs (467 MHz)
  --all         All 23 channels
  --record      Save to gmrs_recordings/<timestamp>/, split per transmission
  --squelch=N   RMS threshold 0..pi (default 0.4; lower=more sensitive)
  --gain=N      Tuner gain dB (default 40; 0=auto)
  --host/--port rtl_tcp endpoint (default 127.0.0.1:14423)

Start the SDR Driver app first so rtl_tcp is listening.
Review recordings with: ./gmrs-analyze.sh
EOF
            exit 0
            ;;
    esac
done

case $MODE in
    main)      CHANS="$MAIN" ;;
    frs)       CHANS="$FRS" ;;
    repeaters) CHANS="$INPUTS" ;;
    all)       CHANS="$MAIN $FRS $INPUTS" ;;
esac

FARGS=""
for f in $CHANS; do FARGS="$FARGS --freq=$f"; done

echo "Monitoring: $CHANS"
echo "Source: rtl_tcp://$HOST:$PORT  Squelch: $SQUELCH  Gain: $GAIN"

RX=(python "$HOME/radio/gmrs-rx.py" --host="$HOST" --port="$PORT" \
    --squelch="$SQUELCH" --gain="$GAIN")
# shellcheck disable=SC2086
RX+=($FARGS)

if [ "$RECORD" = true ]; then
    STAMP=$(date +%Y%m%d_%H%M%S)
    OUTDIR="gmrs_recordings/$STAMP"
    mkdir -p "$OUTDIR"
    echo "Recording to: $OUTDIR/  (tx001.wav, tx002.wav, ...)"
    echo "Press Ctrl+C to stop"
    echo "---"
    "${RX[@]}" \
        2> >(while IFS= read -r line; do
                printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
             done > "$OUTDIR/scan.log") \
        | sox -t raw -r 24000 -e signed -b 16 -c 1 - \
              "$OUTDIR/tx.wav" \
              silence 1 0.1 1% 1 2.0 1% : newfile : restart
else
    echo "Live listening — press Ctrl+C to stop"
    echo "---"
    "${RX[@]}" 2>/dev/null \
        | play -q -r 24000 -t raw -e signed -b 16 -c 1 -
fi
SHEOF
chmod +x "$HOME/radio/gmrs-monitor.sh"

# --- gmrs-analyze.sh: review recordings -------------------------------------
cat > "$HOME/radio/gmrs-analyze.sh" << 'SHEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Review recorded GMRS transmissions (Termux)
# Usage: ./gmrs-analyze.sh [directory]  (default: most recent)

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
[ -d "$DIR" ] || { echo "Not a directory: $DIR"; exit 1; }

echo "=========================================="
echo " GMRS Recording Review: $DIR"
echo "=========================================="

shopt -s nullglob
files=("$DIR"/tx*.wav)
if [ ${#files[@]} -eq 0 ]; then
    echo "No tx*.wav files found"
    exit 0
fi

printf "%-18s %10s %8s  %s\n" "File" "Bytes" "Duration" "Captured"
printf "%-18s %10s %8s  %s\n" "----" "-----" "--------" "--------"

total=0
# 24 kHz, 16-bit mono = 48000 bytes/sec (minus 44-byte WAV header)
for f in "${files[@]}"; do
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
    dur=$(awk "BEGIN { printf \"%.1f\", ($size - 44) / 48000 }")
    mtime=$(stat -c "%y" "$f" 2>/dev/null | cut -d. -f1 \
            || stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$f")
    printf "%-18s %10s %6ss   %s\n" "$(basename "$f")" "$size" "$dur" "$mtime"
    total=$(awk "BEGIN { print $total + $dur }")
done

echo "---"
echo "Total: ${#files[@]} transmissions, ${total}s of audio"

if [ -f "$DIR/scan.log" ]; then
    echo ""
    echo "Channel activity (most recent hops from scan.log):"
    grep -E "signal|clear" "$DIR/scan.log" 2>/dev/null | tail -20
fi

echo ""
echo "=========================================="
echo "Play one:     play $DIR/tx001.wav"
echo "Play all:     for f in $DIR/tx*.wav; do play -q \"\$f\"; done"
echo "Transcribe:   pip install openai-whisper"
echo "              whisper $DIR/tx001.wav --model base --language en"
echo "Bulk search:  for f in $DIR/tx*.wav; do"
echo "                whisper \"\$f\" --model base --output_format txt"
echo "              done && grep -l -iE 'WRDH|two.four.seven' $DIR/*.txt"
echo "=========================================="
SHEOF
chmod +x "$HOME/radio/gmrs-analyze.sh"

echo ""
echo "=== Setup complete! ==="
cat <<EOF

Quick start:
  1. Open the SDR Driver app (already installed for the 433/915 setup)
     and start the rtl_tcp server (port 14423).
  2. cd ~/radio
  3. Live listen:   ./gmrs-monitor.sh
     Record all:    ./gmrs-monitor.sh --record
     Channels only: ./gmrs-monitor.sh --main --record --squelch=0.3
  4. Review later:  ./gmrs-analyze.sh

Tuning tips:
  - Lower --squelch (e.g. 0.25) if weak signals aren't triggering.
  - Raise --squelch (e.g. 0.6) if noise is filling the recordings.
  - --main only (8 channels) gives faster scan cycles than --all (23).
EOF
