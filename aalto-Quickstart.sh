#!/usr/bin/env bash
set -euo pipefail

echo "=== Aalto Local LLM & Moat Quickstart ==="
echo "Get your API key at: https://llm-gateway.k8s.aalto.fi"
echo ""

# 1. Prompt interactively for the key and verify gateway connection
while true; do
  read -t 0.1 -n 10000 _discard </dev/tty 2>/dev/null || true
  read -rp "Paste your Aalto LLM Gateway API Key and press Enter: " INPUT_KEY </dev/tty
  AALTO_LLM_KEY=$(printf '%s' "$INPUT_KEY" | tr -d '[:space:]')

  if [ -z "$AALTO_LLM_KEY" ]; then
    echo "Key cannot be empty. Please try again."
    continue
  fi

  echo "-> Verifying connection and fetching live models from Aalto LLM Gateway..."
  HTTP_CODE=$(curl -sS -o /tmp/aalto_models.json -w "%{http_code}" \
    https://llm-gateway.k8s.aalto.fi/api/v1/models \
    -H "Authorization: Bearer $AALTO_LLM_KEY" || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "-> Key verified! Connected to Aalto LLM Gateway."
    break
  elif [ "$HTTP_CODE" = "000" ]; then
    echo "ERROR: Cannot reach https://llm-gateway.k8s.aalto.fi."
    echo "Check that Aalto VPN is connected (or run 'wsl --shutdown' in PowerShell if you just added .wslconfig)."
    exit 1
  else
    echo "ERROR: Gateway rejected the key (HTTP $HTTP_CODE). Please paste a valid key."
  fi
done

# 2. Install Apptainer & dependencies
if ! command -v apptainer >/dev/null 2>&1; then
  echo "-> Installing Apptainer & system dependencies..."
  sudo add-apt-repository -y ppa:apptainer/ppa
  sudo apt-get update -qq
  sudo apt-get install -y -qq squashfuse fuse2fs uidmap apptainer jq curl pipx
else
  sudo apt-get install -y -qq jq curl pipx
fi

# 3. Install Moat binary
echo "-> Installing Moat..."
mkdir -p "$HOME/.local/bin" "$HOME/.apptainer/tmp" "$HOME/.apptainer/cache"
curl -sSL "https://github.com/AaltoRSE/moat/releases/latest/download/moat_$(uname -s)_$(uname -m).tar.gz" \
  | tar -xz -C "$HOME/.local/bin" moat
chmod +x "$HOME/.local/bin/moat"

# 4. Persist environment variables in host ~/.bashrc
sed -i '/export AALTO_LLM_KEY=/d' "$HOME/.bashrc"
if ! grep -q "APPTAINER_TMPDIR" "$HOME/.bashrc"; then
  cat << 'EOB' >> "$HOME/.bashrc"

# Aalto Moat & Apptainer Environment
export PATH="$HOME/.local/bin:$PATH"
export APPTAINER_TMPDIR="$HOME/.apptainer/tmp"
export APPTAINER_CACHEDIR="$HOME/.apptainer/cache"
export DONT_PROMPT_WSL_INSTALL=1
EOB
fi
echo "export AALTO_LLM_KEY=\"$AALTO_LLM_KEY\"" >> "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"
export AALTO_LLM_KEY="$AALTO_LLM_KEY"

# 5. Configure Moat folders, WSLg-compatible moat-config.yaml, and VS Code settings
mkdir -p "$HOME/.config/moat" "$HOME/moat/agents-home/.config/Code/User" \
  "$HOME/moat/vscode-projects" "$HOME/moat/vscodium-projects"

cat << 'EOF' > ~/.config/moat/moat-config.yaml
envs:
    vscode:
        command: code --new-window --no-sandbox --password-store=basic --wait $PWD
        home: $HOME/moat/agents-home
        mounts:
            - $HOME/moat/vscode-projects
            - /run/user/$UID
            - /tmp/.X11-unix
            - /mnt/wslg
    vscodium:
        command: codium --new-window --no-sandbox --password-store=basic --wait $PWD
        home: $HOME/moat/agents-home
        mounts:
            - $HOME/moat/vscodium-projects
            - /run/user/$UID
            - /tmp/.X11-unix
            - /mnt/wslg
EOF

python3 -c '
import sqlite3, pathlib
db = pathlib.Path.home() / "moat/agents-home/.config/Code/User/globalStorage/state.vscdb"
if db.exists():
    con = sqlite3.connect(db)
    con.execute("DELETE FROM ItemTable WHERE key = \"windowsState\"")
    con.commit()
    con.close()
'

# Ensure sandboxed home also has DONT_PROMPT_WSL_INSTALL and AALTO_LLM_KEY
touch "$HOME/moat/agents-home/.bashrc"
sed -i '/export AALTO_LLM_KEY=/d' "$HOME/moat/agents-home/.bashrc"
if ! grep -q "DONT_PROMPT_WSL_INSTALL" "$HOME/moat/agents-home/.bashrc"; then
  echo 'export DONT_PROMPT_WSL_INSTALL=1' >> "$HOME/moat/agents-home/.bashrc"
fi
echo "export AALTO_LLM_KEY=\"$AALTO_LLM_KEY\"" >> "$HOME/moat/agents-home/.bashrc"

# 6. Generate ~/moat/aalto-gateway.json (with GLM as default_model)
echo "-> Generating ~/moat/aalto-gateway.json..."
jq '{
  providers: [
    {
      name: "aalto-gateway",
      display_name: "Aalto LLM Gateway",
      base_url: "https://llm-gateway.k8s.aalto.fi/api/v1",
      api_key_env: "AALTO_LLM_KEY",
      auth: "bearer",
      default_model: ([.data[].id | select(test("glm"; "i"))][0] // .data[0].id // "zai-org/GLM-5.3-Flash"),
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
}' /tmp/aalto_models.json > "$HOME/moat/aalto-gateway.json"
rm -f /tmp/aalto_models.json

# 7. Install and run moat-install
echo "-> Installing and running moat-install..."
pipx ensurepath >/dev/null
pipx install --force git+https://github.com/AaltoRSE/moat-install.git

"$HOME/.local/bin/moat-install" \
  --provider-specification "$HOME/moat/aalto-gateway.json" \
  --home-base "$HOME/moat/agents-home" </dev/tty

echo "=== Setup Complete! Run: source ~/.bashrc ==="
