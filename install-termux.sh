#!/data/data/com.termux/files/usr/bin/bash
# RTL-SDR Monitor — Termux Install Script
# Run this inside Termux after installing it from F-Droid
#
# Usage: bash install-termux.sh

set -e

echo "=== RTL-SDR Monitor — Termux Setup ==="
echo ""

# 1. Update package repos
echo "[1/5] Updating packages..."
pkg update -y

# 2. Install build tools
echo "[2/4] Installing build tools..."
pkg install -y cmake git make clang

# 3. Build rtl_433 from source (without librtlsdr — uses rtl_tcp instead)
echo "[3/4] Building rtl_433..."
if command -v rtl_433 &>/dev/null; then
    echo "  rtl_433 already installed, skipping build."
else
    cd "$HOME"
    rm -rf rtl_433_build
    git clone https://github.com/merbanan/rtl_433.git rtl_433_build
    cd rtl_433_build
    # Android's Bionic libc doesn't have pthread_cancel.
    # Create a stub and compile with relaxed warnings.
    cat > pthread_cancel_stub.c << 'STUB'
#include <pthread.h>
#include <signal.h>
int pthread_cancel(pthread_t thread) {
    return pthread_kill(thread, SIGUSR1);
}
STUB
    clang -c pthread_cancel_stub.c -o pthread_cancel_stub.o
    mkdir build && cd build
    cmake .. \
        -DENABLE_RTLSDR=OFF \
        -DENABLE_SOAPYSDR=OFF \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_C_FLAGS="-Wno-implicit-function-declaration" \
        -DCMAKE_EXE_LINKER_FLAGS="$HOME/rtl_433_build/pthread_cancel_stub.o"
    make -j$(nproc)
    make install
    cd "$HOME"
    rm -rf rtl_433_build
    echo "  rtl_433 installed."
fi

# 4. Install monitor script
echo "[4/4] Installing monitor script..."
mkdir -p "$HOME/radio"
cat > "$HOME/radio/monitor.sh" << 'SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# RTL-SDR 433/915 MHz Signal Monitor (Termux/Android)
# Usage: ./monitor.sh [--433] [--915] [--log] [--save]
#
# Requires SDR Driver app (by Martin Marinov) for USB access.
# Start rtl_tcp in SDR Driver first, then run this script.

FREQS="-f 433.92M -f 915M"
EXTRA=""
DEVICE="-d rtl_tcp:127.0.0.1:1234"

for arg in "$@"; do
    case $arg in
        --433)    FREQS="-f 433.92M" ;;
        --915)    FREQS="-f 915M" ;;
        --log)    EXTRA="$EXTRA -F json:sensor_log.jsonl" ;;
        --save)   EXTRA="$EXTRA -S all" ;;
        --usb)    DEVICE="" ;;  # Direct USB (requires root)
        -h|--help)
            echo "Usage: $0 [--433] [--915] [--log] [--save] [--usb]"
            echo "  --433   433.92 MHz only"
            echo "  --915   915 MHz only"
            echo "  --log   Append decoded JSON to sensor_log.jsonl"
            echo "  --save  Save raw .cu8 signal files"
            echo "  --usb   Direct USB access (requires root)"
            echo ""
            echo "Default: connects via rtl_tcp on 127.0.0.1:1234"
            echo "Start SDR Driver app first, enable rtl_tcp server."
            exit 0
            ;;
    esac
done

echo "Monitoring: $FREQS"
[ -n "$DEVICE" ] && echo "Source: rtl_tcp (start SDR Driver app first)"
echo "Press Ctrl+C to stop"
echo "---"

rtl_433 $DEVICE $FREQS \
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
SCRIPT
chmod +x "$HOME/radio/monitor.sh"

# 5. Done
echo "Setup complete!"
echo ""
echo "=== Quick Start ==="
echo "1. Install 'SDR Driver' app by Martin Marinov from Play Store"
echo "2. Plug in RTL-SDR via USB OTG adapter"
echo "3. Open SDR Driver, grant USB permission, start rtl_tcp server"
echo "4. In Termux, run:"
echo "     cd ~/radio && ./monitor.sh"
echo ""
echo "If your device is rooted, use --usb for direct USB access:"
echo "     ./monitor.sh --usb"
echo ""
