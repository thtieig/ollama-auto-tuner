# Ollama CPU Auto-Tuner

A set of scripts to automatically configure Ollama's performance parameters (`num_parallel`, `num_thread`, `timeout`) based on a server's available CPU resources. This project is designed for CPU-only Ollama servers running on Debian/Ubuntu.

## Features

- **Dynamic Tuning:** Automatically calculates settings based on your server's physical or logical cores.
- **Strategic Modes:** Supports a **`safe`** mode (uses physical cores for stability) and an **`aggressive`** mode (uses logical cores for maximum throughput).
- **Automated Configuration:** Integrates with `systemd` to run the tuning process every time the Ollama service starts.
- **Update-Proof:** Protects the `systemd` configuration from being overwritten by the standard Ollama installation script.
- **Simple Management:** All tuning strategies are managed in a single, simple configuration file.

## Prerequisites

- A server running a Debian-based OS (like Ubuntu).
- **Ollama must be installed first.** You can install it via `curl -fsSL https://ollama.ai/install.sh | sh`.
- The setup script will verify Ollama installation and provide installation instructions if needed.
- Root or `sudo` access.

## Installation

Clone this repository and run the setup script with `sudo`:

```bash
git clone https://thtieig@bitbucket.org/thtieig/ollama-auto-tuner.git
cd ollama-auto-tuner
sudo bash setup.sh
```

The script will handle the rest. It installs dependencies, creates the necessary files, and restarts Ollama with the new tuned configuration.

## How It Works

The setup is composed of a few key components:

- **Tuning Strategy** (/etc/default/ollama-autotune.conf): This is the "recipe" file where you define your performance goals (e.g., MODE="aggressive").
- **Autotune Script** (/usr/local/bin/ollama-autotune.sh): This is the "chef." It reads your strategy, detects the server's CPU cores, calculates the optimal parameters, and writes them to Ollama's configuration file.
- **Ollama Config** (/etc/ollama/config.yaml): The final configuration file that the script generates and that Ollama reads on startup.
- **Systemd Drop-In** (/etc/systemd/system/ollama.service.d/10-autotune.conf): This tells systemd to run our autotune script right before starting the main Ollama process.

This architecture ensures that your tuning is applied automatically every time the service starts, adapting to any changes in your server's hardware.

## Configuration

To change the tuning behavior, simply edit the strategy file and restart the Ollama service:

```bash
sudo nano /etc/default/ollama-autotune.conf
# ...make your changes, for example, switch MODE to "safe"...
sudo systemctl restart ollama
```

## The Upgrade Process

The Ollama install.sh script may place the systemd service file in /etc/systemd/system/ollama.service, which could conflict with custom configurations. The setup script handles this by relocating any existing service file to the standard /usr/lib/systemd/system/ location and ensuring our drop-in configuration takes precedence. This prevents configuration conflicts during upgrades while maintaining automatic tuning functionality.
