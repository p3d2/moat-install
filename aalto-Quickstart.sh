#!/usr/bin/env bash
set -euo pipefail

echo "=== Aalto Local LLM & Moat Quickstart ==="

# 1. Prompt for API Key if not already set
if [ -z "${AALTO_LLM_KEY:-}" ] || [ "${AALTO_LLM_KEY}" = "your-api-key-here" ]; then
  read -rsp "Paste your Aalto LLM Gateway API Key: " AALTO_LLM_KEY </dev/tty
  echo ""
fi

# 2. Verify VPN / Gateway connection and fetch models early
echo "-> Verifying connection to Aalto LLM Gateway..."
MODELS_JSON=$(curl -sf https://llm-gateway.k8s.aalto.fi/api/v1/models \
  -H "Authorization: Bearer $AALTO_LLM_KEY") || {
  echo "ERROR: Could not reach https://llm-gateway.k8s.aalto.fi or invalid API key."
  echo "Make sure Aalto VPN is connected and your key is valid."
  exit 1
}

# 3. Install Apptainer & dependencies
if ! command -v apptainer >/dev/null 2>&1; then
  echo "-> Installing Apptainer & system dependencies..."
  sudo add-apt-repository -y ppa:apptainer/ppa
  sudo apt-get update -qq
  sudo apt-get install -y -qq squashfuse fuse2fs uidmap apptainer jq curl pipx
else
  sudo apt-get install -y -qq jq curl pipx
fi

# 4. Install Moat binary
echo "-> Installing Moat..."
mkdir -p "$HOME/.local/bin" "$HOME/.apptainer/tmp" "$HOME/.apptainer/cache"
curl -sSL "https://github.com/AaltoRSE/moat/releases/latest/download/moat_$(uname -s)_$(uname -m).tar.gz" \
  | tar -xz -C "$HOME/.local/bin" moat
chmod +x "$HOME/.local/bin/moat"

# 5. Persist environment variables idempotently
if ! grep -q "AALTO_LLM_KEY" "$HOME/.bashrc"; then
  cat << EOF >> "$HOME/.bashrc"

# Aalto Moat & LLM Gateway Environment
export PATH="\$HOME/.local/bin:\$PATH"
export APPTAINER_TMPDIR="\$HOME/.apptainer/tmp"
export APPTAINER_CACHEDIR="\$HOME/.apptainer/cache"
export DONT_PROMPT_WSL_INSTALL=1
export AALTO_LLM_KEY="$AALTO_LLM_KEY"
EOF
fi
export PATH="$HOME/.local/bin:$PATH"
export AALTO_LLM_KEY="$AALTO_LLM_KEY"

# 6. Configure Moat folders & default config
mkdir -p "$HOME/.config/moat" "$HOME/moat/agents-home" "$HOME/moat/vscode-projects" "$HOME/moat/vscodium-projects"
curl -fsSL -o "$HOME/.config/moat/moat-config.yaml" \
  https://raw.githubusercontent.com/AaltoRSE/moat/main/examples/vscode/moat-config.yaml

# 7. Generate aalto-gateway.json dynamically
echo "-> Configuring Aalto LLM Gateway models..."
echo "$MODELS_JSON" | jq '{
  providers: [
    {
      name: "aalto-gateway",
      display_name: "Aalto LLM Gateway",
      base_url: "https://llm-gateway.k8s.aalto.fi/api/v1",
      api_key_env: "AALTO_LLM_KEY",
      auth: "bearer",
      default_model: (.data[0].id // "Qwen/Qwen3.8-27B-FP8"),
      models: [
        .data[]
        | select(.id | test("embed"; "i") | not)
        | {
            id: .id,
            display_name: (.id | split("/") | last),
            context_window: 32768,
            max_output_tokens: 8192
          }
      ],
      pi_api: "openai-completions",
      opencode_npm: "@ai-sdk/openai-compatible",
      codex_disable_response_storage: false
    }
  ]
}' > "$HOME/moat/aalto-gateway.json"

# 8. Install and run moat-install
echo "-> Installing moat-install..."
pipx ensurepath >/dev/null
pipx install --force git+https://github.com/AaltoRSE/moat-install.git
"$HOME/.local/bin/moat-install" "$HOME/moat/aalto-gateway.json" || true

echo "=== Setup Complete! Restart your terminal or run: source ~/.bashrc ==="
