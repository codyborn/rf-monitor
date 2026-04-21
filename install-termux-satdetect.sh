#!/data/data/com.termux/files/usr/bin/bash
# Satellite-band activity detector — Termux install
# Passive RF presence detection only (no demodulation, no decoding).
# Default bands: Iridium (1616–1626.5 MHz), Swarm (137–138 MHz).
#
# Run after install-termux-gmrs.sh (shares the rtl_tcp + numpy setup).

set -e
echo "=== Satellite Band Detector — Termux Setup ==="

# Deps: python + numpy. Installed by install-termux-gmrs.sh already;
# idempotent if re-run.
pkg install -y python python-numpy

mkdir -p "$HOME/radio"

# --- sat-detect.py: FFT-based presence detector via rtl_tcp ----------------
cat > "$HOME/radio/sat-detect.py" << 'PYEOF'
#!/usr/bin/env python3
"""Satellite-band RF activity detector via rtl_tcp.

Passive only: captures IQ, computes FFT power, logs bins above a threshold.
Does not demodulate, does not decode.
"""
import socket, struct, sys, argparse, time
import numpy as np

def cmd(s, c, p): s.sendall(struct.pack('>BI', c, p))

def connect(host, port, samp, gain):
    s = socket.socket(); s.connect((host, port)); s.recv(12)
    cmd(s, 0x02, samp)
    cmd(s, 0x03, 0 if gain == 0 else 1)
    if gain: cmd(s, 0x04, gain * 10)
    return s

def read_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise ConnectionError("rtl_tcp closed")
        buf.extend(c)
    return bytes(buf)

def spectrum(iq, n_fft):
    x = np.frombuffer(iq, np.uint8).astype(np.float32) - 127.5
    z = x[0::2] + 1j * x[1::2]
    n = len(z) // n_fft
    if n == 0: return None
    frames = z[:n * n_fft].reshape(n, n_fft) * np.hanning(n_fft).astype(np.float32)
    F = np.fft.fftshift(np.fft.fft(frames, axis=1), axes=1)
    return 10.0 * np.log10(np.mean(np.abs(F) ** 2, axis=0) + 1e-12)

def plan_sweep(bands, samp):
    """Turn 'name:lo:hi' strings into (name, [center_hz, ...]) tuples."""
    step_mhz = samp / 1e6 * 0.9       # 10% overlap between adjacent tunings
    sweeps = []
    for b in bands:
        name, lo, hi = b.split(':')
        lo, hi = float(lo), float(hi)
        centers, c = [], lo + step_mhz / 2
        while c - step_mhz / 2 < hi:
            centers.append(int(c * 1e6))
            c += step_mhz
        sweeps.append((name, centers))
    return sweeps

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=14423)
    ap.add_argument('--band', action='append',
                    help='name:start_MHz:end_MHz (repeatable). '
                         'Default: iridium + swarm')
    ap.add_argument('--samp', type=int, default=2_400_000, help='IQ sample rate')
    ap.add_argument('--gain', type=int, default=40, help='dB; 0=auto')
    ap.add_argument('--dwell', type=float, default=0.1, help='seconds per tuning')
    ap.add_argument('--threshold', type=float, default=10.0,
                    help='dB above noise-floor median to count as a detection')
    ap.add_argument('--n-fft', type=int, default=1024)
    ap.add_argument('--log', default='sat-detect.log')
    a = ap.parse_args()

    bands = a.band or ['iridium:1616:1626.5', 'swarm:137:138']
    sweeps = plan_sweep(bands, a.samp)

    s = connect(a.host, a.port, a.samp, a.gain)
    chunk_bytes = int(a.samp * a.dwell) * 2        # *2 for I + Q
    bin_hz = a.samp / a.n_fft

    log = open(a.log, 'a', buffering=1)
    log.write(f"# start {time.strftime('%Y-%m-%d %H:%M:%S')} "
              f"bands={bands} thresh={a.threshold}dB\n")
    sys.stderr.write(
        f"monitoring {[b[0] for b in sweeps]} "
        f"({sum(len(c) for _, c in sweeps)} tuning steps)\n"
        f"log: {a.log}\n")
    sys.stderr.flush()

    try:
        while True:
            for name, centers in sweeps:
                for center in centers:
                    cmd(s, 0x01, center)
                    read_exact(s, chunk_bytes // 4)     # flush retune transient
                    psd = spectrum(read_exact(s, chunk_bytes), a.n_fft)
                    if psd is None: continue

                    noise = float(np.median(psd))
                    peaks = np.where(psd > noise + a.threshold)[0]
                    if not len(peaks): continue

                    # collapse adjacent bins into single detections
                    groups, prev = [[peaks[0]]], peaks[0]
                    for p in peaks[1:]:
                        if p - prev <= 2:
                            groups[-1].append(p)
                        else:
                            groups.append([p])
                        prev = p

                    ts = time.strftime('%Y-%m-%d %H:%M:%S')
                    for g in groups:
                        peak_bin = int(g[int(np.argmax(psd[g]))])
                        freq_mhz = (center + (peak_bin - a.n_fft / 2) * bin_hz) / 1e6
                        level = float(psd[peak_bin] - noise)
                        line = (f"{ts} [{name}] {freq_mhz:.4f} MHz "
                                f"+{level:.1f} dB over noise")
                        print(line, flush=True)
                        log.write(line + "\n")
    except (KeyboardInterrupt, ConnectionError, BrokenPipeError):
        pass
    finally:
        log.close()
        s.close()

if __name__ == '__main__':
    main()
PYEOF
chmod +x "$HOME/radio/sat-detect.py"

# --- sat-detect.sh: thin wrapper -------------------------------------------
cat > "$HOME/radio/sat-detect.sh" << 'SHEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Satellite-band activity detector (Termux, via rtl_tcp + SDR Driver app)
# Usage: ./sat-detect.sh [--iridium-only] [--swarm-only]
#                        [--threshold=N] [--gain=N] [--log=FILE]

BANDS=(--band=iridium:1616:1626.5 --band=swarm:137:138)
EXTRA=()

for arg in "$@"; do
    case $arg in
        --iridium-only) BANDS=(--band=iridium:1616:1626.5) ;;
        --swarm-only)   BANDS=(--band=swarm:137:138) ;;
        --threshold=*|--gain=*|--log=*|--dwell=*|--host=*|--port=*)
                        EXTRA+=("$arg") ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  --iridium-only   Scan 1616-1626.5 MHz only
  --swarm-only     Scan 137-138 MHz only
  --threshold=N    dB over noise-floor median to count as detection (default 10)
  --gain=N         Tuner gain dB (default 40; 0=auto)
  --log=FILE       Log file (default sat-detect.log)
  --dwell=S        Seconds per tuning (default 0.1)

Requires SDR Driver app serving rtl_tcp on 127.0.0.1:14423.
Note: at 1616+ MHz the RTL-SDR tuner is near its upper limit (~1.7 GHz)
and sensitivity is reduced. Use --gain=0 for auto, or try --gain=49.6.
EOF
            exit 0 ;;
    esac
done

exec python "$HOME/radio/sat-detect.py" "${BANDS[@]}" "${EXTRA[@]}"
SHEOF
chmod +x "$HOME/radio/sat-detect.sh"

echo ""
echo "=== Setup complete ==="
cat <<EOF

Start SDR Driver app (rtl_tcp server), then:

  cd ~/radio
  ./sat-detect.sh                      # both bands
  ./sat-detect.sh --iridium-only       # L-band only
  ./sat-detect.sh --swarm-only         # VHF only
  ./sat-detect.sh --threshold=6        # more sensitive

Each line in sat-detect.log is one detected peak with timestamp, band,
frequency, and dB above the local noise-floor median.
EOF
