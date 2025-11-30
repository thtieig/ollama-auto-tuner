#!/bin/bash
set -e

# =====================================================================
#        Ollama CPU Auto-Tuner :: Setup Script
# =====================================================================
# This script installs and configures the auto-tuner service.
# Designed for CPU-only Ollama deployments with dynamic scaling.
# Run with root privileges: sudo bash setup.sh
# =====================================================================

VERSION="2.1.0"

# Check for root privileges
if [[ "$EUID" -ne 0 ]]; then
  echo "✗ This script must be run as root. Please use sudo."
  exit 1
fi

# Check for Ollama installation
echo "🔍 Checking if Ollama is installed..."
if ! command -v ollama &> /dev/null; then
  echo "✗ Ollama not found."
  echo "   This script requires Ollama to be installed first."
  echo ""
  read -p "   Do you want to automatically install it? (y/n): " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "📥 Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
    echo "✓ Ollama installation complete."
  else
    echo "   Install Ollama manually with: curl -fsSL https://ollama.ai/install.sh | sh"
    echo "   Then restart this script."
    exit 1
  fi
fi
echo "✓ Ollama found."

echo ">> Starting Ollama CPU Auto-Tuner Setup (v${VERSION})..."

# =====================================================================
# 1. Install Dependencies
# =====================================================================
echo "📦 Checking for dependencies (wget, yq)..."
if ! command -v wget &> /dev/null; then
    echo "   - wget not found. Installing..."
    apt-get update && apt-get install -y wget > /dev/null 2>&1
fi
if ! command -v yq &> /dev/null; then
    echo "   - yq not found. Installing..."
    wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq
fi
echo "✓ Dependencies satisfied."

# =====================================================================
# 2. Create the Autotune Script (Improved Logic)
# =====================================================================
echo "✏️  Creating improved auto-tune script..."
cat > /usr/local/bin/ollama-autotune.sh << 'EOFSCRIPT'
#!/bin/bash
set -eo pipefail

CONFIG_FILE="/etc/default/ollama-autotune.conf"
OLLAMA_CONFIG_YAML="/etc/ollama/config.yaml"

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

# Get system info
PHYSICAL_CORES=$(lscpu | grep '^Core(s) per socket:' | awk '{print $4}')
SOCKETS=$(lscpu | grep '^Socket(s):' | awk '{print $2}')
TOTAL_PHYSICAL_CORES=$((PHYSICAL_CORES * SOCKETS))
LOGICAL_CORES=$(nproc)

echo "System Info: $TOTAL_PHYSICAL_CORES physical cores, $LOGICAL_CORES logical cores"

# ===================================================================
# Calculate optimal parameters based on MODE
# ===================================================================

FINAL_MODE="${MODE:-safe}"
echo "Mode: $FINAL_MODE"

case "$FINAL_MODE" in
  safe)
    # Conservative: good for general workloads, stability over speed
    OS_HEADROOM=4
    NUM_THREAD=$((TOTAL_PHYSICAL_CORES / 4))  # Each inference gets ~4 cores
    NUM_PARALLEL=$((TOTAL_PHYSICAL_CORES / NUM_THREAD))
    BATCH_SIZE=256
    TIMEOUT=120
    ;;
  
  balanced)
    # Moderate: balance between throughput and stability
    OS_HEADROOM=3
    NUM_THREAD=$((TOTAL_PHYSICAL_CORES / 6))  # Each inference gets ~2-3 cores
    NUM_PARALLEL=$((TOTAL_PHYSICAL_CORES / NUM_THREAD))
    BATCH_SIZE=512
    TIMEOUT=120
    ;;
  
  aggressive)
    # Aggressive: maximize throughput, accept occasional timeouts
    OS_HEADROOM=2
    NUM_THREAD=$((TOTAL_PHYSICAL_CORES / 8))  # Each inference gets ~1-2 cores
    NUM_PARALLEL=$((TOTAL_PHYSICAL_CORES / NUM_THREAD))
    BATCH_SIZE=1024
    TIMEOUT=180
    ;;
  
  *)
    echo "ERROR: Invalid mode '$FINAL_MODE'. Use: safe, balanced, or aggressive" >&2
    exit 1
    ;;
esac

# Ensure minimum values
[[ $NUM_THREAD -lt 1 ]] && NUM_THREAD=1
[[ $NUM_PARALLEL -lt 1 ]] && NUM_PARALLEL=1
[[ $NUM_THREAD -gt $TOTAL_PHYSICAL_CORES ]] && NUM_THREAD=$TOTAL_PHYSICAL_CORES
[[ $NUM_PARALLEL -gt $TOTAL_PHYSICAL_CORES ]] && NUM_PARALLEL=$TOTAL_PHYSICAL_CORES

# ===================================================================
# Calculate total threads to leave OS headroom
# ===================================================================
THREADS=$((TOTAL_PHYSICAL_CORES - OS_HEADROOM))
[[ $THREADS -lt 1 ]] && THREADS=1

# ===================================================================
# Display calculated parameters
# ===================================================================
cat << EOF
╔═══════════════════════════════════════════════════════════════╗
║         Calculated Ollama Configuration (Mode: $FINAL_MODE)        ║
╠═══════════════════════════════════════════════════════════════╣
║ Physical Cores:        $TOTAL_PHYSICAL_CORES
║ OS Headroom:           $OS_HEADROOM cores
║ Ollama Threads:        $THREADS cores (total)
║ Thread per Inference:  $NUM_THREAD cores
║ Parallel Inferences:   $NUM_PARALLEL concurrent
║ Batch Size:            $BATCH_SIZE
║ Request Timeout:       ${TIMEOUT}s
╚═══════════════════════════════════════════════════════════════╝
EOF

# ===================================================================
# Apply configuration using yq
# ===================================================================
echo "✏️  Applying configuration to $OLLAMA_CONFIG_YAML..."
mkdir -p "$(dirname "$OLLAMA_CONFIG_YAML")"
touch "$OLLAMA_CONFIG_YAML"

# Set all parameters atomically
yq -i ".threads = $THREADS" "$OLLAMA_CONFIG_YAML"
yq -i ".num_thread = $NUM_THREAD" "$OLLAMA_CONFIG_YAML"
yq -i ".num_parallel = $NUM_PARALLEL" "$OLLAMA_CONFIG_YAML"
yq -i ".batch_size = $BATCH_SIZE" "$OLLAMA_CONFIG_YAML"
yq -i ".timeout = $TIMEOUT" "$OLLAMA_CONFIG_YAML"
yq -i ".mmap = true" "$OLLAMA_CONFIG_YAML"

echo "✅ Configuration applied."
echo ""
echo "Current config.yaml:"
cat "$OLLAMA_CONFIG_YAML"
EOFSCRIPT

chmod +x /usr/local/bin/ollama-autotune.sh
echo "✓ Auto-tune script created."

# =====================================================================
# 3. Create Configuration File (Recipe)
# =====================================================================
echo "✏️  Creating configuration at /etc/default/ollama-autotune.conf..."
cat > /etc/default/ollama-autotune.conf << 'EOFCONF'
# =====================================================================
# Ollama Auto-Tuner Configuration
# =====================================================================
# This file controls how Ollama is tuned for your hardware.
#
# MODES:
#   safe      - Conservative settings, suitable for stable production
#   balanced  - Good balance between throughput and reliability
#   aggressive - Maximize throughput, accept potential instability
#
# Edit MODE to change tuning strategy, then restart Ollama:
#   sudo systemctl restart ollama
# =====================================================================

MODE="balanced"
EOFCONF
echo "✓ Configuration created."

# =====================================================================
# 4. Ensure Service File Location
# =====================================================================
echo ">> Ensuring ollama.service is in the correct location..."
if [ -f /etc/systemd/system/ollama.service ]; then
    echo "   - Found service file in /etc/systemd/system/, moving to standard location..."
    mv /etc/systemd/system/ollama.service /usr/lib/systemd/system/ollama.service
elif [ ! -f /usr/lib/systemd/system/ollama.service ]; then
    echo "   - Creating service file..."
    cat > /usr/lib/systemd/system/ollama.service << 'SERVICE_EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"

[Install]
WantedBy=default.target
SERVICE_EOF
fi
echo "✓ Service file location confirmed."

# =====================================================================
# 5. Create Systemd Drop-In
# =====================================================================
echo "✏️  Creating systemd drop-in..."
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/10-autotune.conf << 'EOFDROP'
[Service]
Environment="OLLAMA_CONFIG=/etc/ollama/config.yaml"
Nice=-5

# Run autotune before starting Ollama
ExecStartPre=+/usr/local/bin/ollama-autotune.sh
EOFDROP
echo "✓ Systemd drop-in created."

# =====================================================================
# 6. Ensure Service is Not Masked
# =====================================================================
echo "🛡️  Unmask ollama.service if previously masked..."
systemctl unmask ollama.service 2>/dev/null || true
echo "✓ Service unmask complete."

# =====================================================================
# 7. Apply and Start
# =====================================================================
echo ">> Reloading systemd daemon..."
systemctl daemon-reload

echo ">> Restarting Ollama with auto-tuned settings..."
systemctl restart ollama

# Wait for Ollama to stabilise
sleep 3

# Show status
echo ""
echo "** Setup complete! **"
echo ""
echo "Ollama status:"
systemctl status ollama --no-pager || true
echo ""
echo "📋 Current configuration (/etc/ollama/config.yaml):"
cat /etc/ollama/config.yaml
echo ""
echo "💡 Tips:"
echo "   - To change tuning mode, edit: /etc/default/ollama-autotune.conf"
echo "   - Then restart: sudo systemctl restart ollama"
echo "   - View logs: sudo journalctl -u ollama -f"
echo "   - Available modes: safe, balanced, aggressive"
