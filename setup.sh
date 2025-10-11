#!/bin/bash
set -e

# =================================================================
#        Ollama CPU Auto-Tuner :: Setup Script
# =================================================================
# This script installs and configures the auto-tuner service.
# It should be run with root privileges (e.g., sudo bash setup.sh).
# =================================================================

# --- Check for Root Privileges ---
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ This script must be run as root. Please use sudo."
  exit 1
fi

echo "🚀 Starting Ollama CPU Auto-Tuner Setup..."

# --- 1. Install Dependencies ---
echo "📦 Checking for dependencies (wget, yq)..."
if ! command -v wget &> /dev/null; then
    echo "   - wget not found. Installing..."
    apt-get update && apt-get install -y wget
fi
if ! command -v yq &> /dev/null; then
    echo "   - yq not found. Installing..."
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq
fi
echo "✅ Dependencies are satisfied."

# --- 2. Create the Autotune Script ---
echo "✍️  Creating auto-tune script at /usr/local/bin/ollama-autotune.sh..."
cat > /usr/local/bin/ollama-autotune.sh << 'EOF'
#!/bin/bash
set -eo pipefail

# --- Ollama Autotune Script (YAML Version) ---
# This script calculates optimal settings and writes them to a YAML config file.

CONFIG_FILE="/etc/default/ollama-autotune.conf"
OLLAMA_CONFIG_YAML="/etc/ollama/config.yaml"

# Load the tuning strategy
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Autotune config file not found at $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"
FINAL_MODE="${MODE:-safe}"

# --- Parameter Calculation ---
echo "⚖️  Calculating parameters for mode: $FINAL_MODE"
TOTAL_PHYSICAL_CORES=$(( $(lscpu | grep 'Core(s) per socket:' | awk '{print $4}') * $(lscpu | grep 'Socket(s):' | awk '{print $2}') ))
LOGICAL_CORES=$(nproc)

case "$FINAL_MODE" in
  safe)
    OS_HEADROOM=${SAFE_OS_HEADROOM:-2}
    CORES_PER_INFERENCE=${SAFE_CORES_PER_INFERENCE:-4}
    TIMEOUT=${SAFE_TIMEOUT:-90s}
    AVAILABLE_CORES=$((TOTAL_PHYSICAL_CORES - OS_HEADROOM))
    ;;
  aggressive)
    OS_HEADROOM=${AGGRESSIVE_OS_HEADROOM:-2}
    CORES_PER_INFERENCE=${AGGRESSIVE_CORES_PER_INFERENCE:-2}
    TIMEOUT=${AGGRESSIVE_TIMEOUT:-120s}
    AVAILABLE_CORES=$((LOGICAL_CORES - OS_HEADROOM))
    ;;
  *) echo "❌ Error: Invalid mode '$FINAL_MODE'."; exit 1;;
esac
WORKERS=$((AVAILABLE_CORES / CORES_PER_INFERENCE)); if [[ "$WORKERS" -lt 1 ]]; then WORKERS=1; fi
TIMEOUT_SECONDS=${TIMEOUT%s} # Remove 's' for YAML

# --- Apply Configuration to YAML using yq ---
echo "✍️  Applying configuration to $OLLAMA_CONFIG_YAML..."
mkdir -p "$(dirname "$OLLAMA_CONFIG_YAML")"
touch "$OLLAMA_CONFIG_YAML"

yq -i ".num_parallel = $WORKERS" "$OLLAMA_CONFIG_YAML"
yq -i ".num_thread = $CORES_PER_INFERENCE" "$OLLAMA_CONFIG_YAML"
yq -i ".timeout = $TIMEOUT_SECONDS" "$OLLAMA_CONFIG_YAML"

echo "✅ Ollama config updated. The service will use these settings on start."
EOF

# Set permissions for the script
chmod +x /usr/local/bin/ollama-autotune.sh
echo "✅ Auto-tune script created."

# --- 3. Create the Default Configuration ("Recipe") ---
echo "✍️  Creating configuration file at /etc/default/ollama-autotune.conf..."
cat > /etc/default/ollama-autotune.conf << 'EOF'
# --- Default Configuration for Ollama Autotune ---
# This file contains the strategic rules for the auto-tuner.

# Set the default mode: "safe" or "aggressive"
MODE="safe"

# --- Safe Mode Settings (Physical Cores) ---
SAFE_OS_HEADROOM=2            # Cores to reserve for the OS
SAFE_CORES_PER_INFERENCE=4    # Cores to assign to a single inference
SAFE_TIMEOUT=90s              # Max time per request

# --- Aggressive Mode Settings (Logical Cores) ---
AGGRESSIVE_OS_HEADROOM=2      # Cores to reserve for the OS
AGGRESSIVE_CORES_PER_INFERENCE=2 # Cores to assign to a single inference
AGGRESSIVE_TIMEOUT=120s         # Longer timeout for high contention
EOF
echo "✅ Default configuration created."

# --- 4. Create the Systemd Drop-In File ---
echo "✍️  Creating systemd drop-in at /etc/systemd/system/ollama.service.d/10-autotune.conf..."
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/10-autotune.conf << 'EOF'
[Service]
# Point Ollama to the config file we are managing
Environment="OLLAMA_CONFIG=/etc/ollama/config.yaml"

# Increase process priority
Nice=-5

# Run the autotune script as root before starting
ExecStartPre=+/usr/local/bin/ollama-autotune.sh
EOF
echo "✅ Systemd drop-in created."

# --- 5. Protect Against Installer Overwrites ---
echo "🛡️  Protecting systemd configuration from installer overwrites..."
# Remove any existing file and create a symlink to /dev/null
rm -f /etc/systemd/system/ollama.service
ln -s /dev/null /etc/systemd/system/ollama.service
echo "✅ Protection enabled."

# --- 6. Finalizing Setup ---
echo "🔄 Reloading systemd and restarting Ollama..."
systemctl daemon-reload
systemctl restart ollama

echo "🎉 All done! Ollama is now running with auto-tuned settings."
echo "   To change the tuning strategy, edit /etc/default/ollama-autotune.conf"
