#!/bin/bash

CYAN='\033[0;36m'
LIGHTBLUE='\033[1;34m'
RED='\033[1;31m'
GREEN='\033[1;32m'
PURPLE='\033[1;35m'
BOLD='\033[1m'
RESET='\033[0m'

ENV_PATH="$HOME/.aztec/.env"

echo -e "\n${CYAN}${BOLD}---- CHECKING DOCKER INSTALLATION ----${RESET}\n"
if ! command -v docker &> /dev/null; then
  echo -e "${LIGHTBLUE}${BOLD}Docker not found. Installing Docker...${RESET}"
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  sudo usermod -aG docker $USER
  rm get-docker.sh
  echo -e "${GREEN}${BOLD}Docker installed successfully!${RESET}"
fi

echo -e "${LIGHTBLUE}${BOLD}Setting up Docker to run without sudo for this session...${RESET}"
if ! getent group docker > /dev/null; then
  sudo groupadd docker
fi

sudo usermod -aG docker $USER

if [ -S /var/run/docker.sock ]; then
  sudo chmod 666 /var/run/docker.sock
  echo -e "${GREEN}${BOLD}Docker socket permissions updated.${RESET}"
else
  echo -e "${RED}${BOLD}Docker socket not found. Docker daemon might not be running.${RESET}"
  echo -e "${LIGHTBLUE}${BOLD}Starting Docker daemon...${RESET}"
  sudo systemctl start docker
  sudo chmod 666 /var/run/docker.sock
fi

if docker info &>/dev/null; then
  echo -e "${GREEN}${BOLD}Docker is now working without sudo.${RESET}"
else
  echo -e "${RED}${BOLD}Failed to configure Docker to run without sudo. Using sudo for Docker commands.${RESET}"
  DOCKER_CMD="sudo docker"
fi

echo -e "\n${CYAN}${BOLD}---- INSTALLING DEPENDENCIES ----${RESET}\n"
sudo apt-get update
sudo apt-get install -y curl screen net-tools psmisc jq

[ -d /root/.aztec/alpha-testnet ] && rm -r /root/.aztec/alpha-testnet

AZTEC_PATH=$HOME/.aztec
BIN_PATH=$AZTEC_PATH/bin
mkdir -p $BIN_PATH

# === Create or Verify .env File ===
echo -e "\n${CYAN}${BOLD}---- VERIFYING ENVIRONMENT VARIABLES ----${RESET}"
if [ ! -f "$ENV_PATH" ]; then
  echo -e "${LIGHTBLUE}${BOLD}.env file not found. Creating new one at $ENV_PATH...${RESET}"
  touch "$ENV_PATH"
fi

# Auto-detect and write IP if not already set
if ! grep -q "^NODE_IP=" "$ENV_PATH" || [[ -z $(grep "^NODE_IP=" "$ENV_PATH" | cut -d '=' -f2) ]]; then
  DETECTED_IP=$(curl -s https://api.ipify.org || curl -s http://checkip.amazonaws.com || curl -s https://ifconfig.me)
  echo "NODE_IP=$DETECTED_IP" >> "$ENV_PATH"
  echo -e "${GREEN}${BOLD}NODE_IP auto-detected and saved: $DETECTED_IP${RESET}"
else
  echo -e "${GREEN}${BOLD}NODE_IP already set in .env. Skipping...${RESET}"
fi

# Define required keys and prompts
declare -A env_vars=( 
  ["L1_RPC_URL"]="Sepolia Ethereum RPC URL"
  ["L1_CONSENSUS_URL"]="Sepolia BEACON (consensus) URL"
  ["VALIDATOR_PRIVATE_KEY"]="Your EVM wallet private key (with 0x prefix)"
  ["COINBASE_ADDRESS"]="Wallet address associated with the above private key"
)

# Loop through each required variable and verify existence
for key in "${!env_vars[@]}"; do
  current_val=$(grep "^$key=" "$ENV_PATH" | cut -d '=' -f2-)
  if [[ -z "$current_val" ]]; then
    echo -e "${LIGHTBLUE}${BOLD}${env_vars[$key]} not found in .env. Please enter it now:${RESET}"
    read -rp "> " value
    sed -i "/^$key=/d" "$ENV_PATH"
    echo "$key=$value" >> "$ENV_PATH"
    echo -e "${GREEN}${BOLD}$key has been set.${RESET}"
  else
    echo -e "${GREEN}${BOLD}$key already set in .env. Skipping...${RESET}"
  fi
  export $key=$(grep "^$key=" "$ENV_PATH" | cut -d '=' -f2-)
done

echo -e "\n${CYAN}${BOLD}---- INSTALLING AZTEC TOOLKIT ----${RESET}\n"

if [ -n "$DOCKER_CMD" ]; then
  export DOCKER_CMD="$DOCKER_CMD"
fi

curl -fsSL https://install.aztec.network | bash

if ! command -v aztec >/dev/null 2>&1; then
  echo -e "${LIGHTBLUE}${BOLD}Aztec CLI not found in PATH. Adding it for current session...${RESET}"
  export PATH="$PATH:$HOME/.aztec/bin"
  if ! grep -Fxq 'export PATH=$PATH:$HOME/.aztec/bin' "$HOME/.bashrc"; then
    echo 'export PATH=$PATH:$HOME/.aztec/bin' >> "$HOME/.bashrc"
    echo -e "${GREEN}${BOLD}Added Aztec to PATH in .bashrc${RESET}"
  fi
fi

if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
elif [ -f "$HOME/.bashrc" ]; then
  source "$HOME/.bashrc"
fi

export PATH="$PATH:$HOME/.aztec/bin"

if ! command -v aztec &> /dev/null; then
  echo -e "${RED}${BOLD}ERROR: Aztec installation failed. Please check the logs above.${RESET}"
  exit 1
fi

echo -e "\n${CYAN}${BOLD}---- UPDATING AZTEC TO ALPHA-TESTNET ----${RESET}\n"
aztec-up alpha-testnet

echo -e "\n${CYAN}${BOLD}---- CONFIGURING NODE ----${RESET}\n"

if netstat -tuln | grep -q ":8080 "; then
  echo -e "${LIGHTBLUE}${BOLD}Port 8080 is in use. Attempting to free it...${RESET}"
  sudo fuser -k 8080/tcp
  sleep 2
  echo -e "${GREEN}${BOLD}Port 8080 has been freed successfully.${RESET}"
else
  echo -e "${GREEN}${BOLD}Port 8080 is already free and available.${RESET}"
fi

echo -e "\n${CYAN}${BOLD}---- STOPPING AND REMOVING EXISTING SYSTEMD SERVICE (if exists) ----${RESET}\n"
if systemctl is-active --quiet aztec; then
    echo -e "${LIGHTBLUE}${BOLD}Stopping existing Aztec service...${RESET}"
    sudo systemctl stop aztec
    sudo systemctl disable aztec
    sudo systemctl daemon-reload
    sudo rm /etc/systemd/system/aztec.service
    echo -e "${GREEN}${BOLD}Existing service removed successfully.${RESET}"
fi

echo -e "\n${CYAN}${BOLD}---- CREATING SYSTEMD SERVICE ----${RESET}\n"

cat > $HOME/.aztec/start_node.sh <<EOL
#!/bin/bash
source "$ENV_PATH"
export PATH=\$PATH:\$HOME/.aztec/bin
aztec start --node --archiver --sequencer \\
  --network alpha-testnet \\
  --port 8080 \\
  --l1-rpc-urls \$L1_RPC_URL \\
  --l1-consensus-host-urls \$L1_CONSENSUS_URL \\
  --sequencer.validatorPrivateKey \$VALIDATOR_PRIVATE_KEY \\
  --sequencer.coinbase \$COINBASE_ADDRESS \\
  --p2p.p2pIp \$NODE_IP
EOL

chmod +x $HOME/.aztec/start_node.sh

# Update the systemd service definition with the full path to aztec
cat > /etc/systemd/system/aztec.service << EOL
[Unit]
Description=Aztec Alpha Node
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/root
EnvironmentFile=/root/.aztec/.env
Environment=PATH=/root/.aztec/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=/root
ExecStart=/root/.aztec/bin/aztec start --node --archiver --sequencer \
  --network alpha-testnet \
  --port 8080 \
  --l1-rpc-urls ${L1_RPC_URL} \
  --l1-consensus-host-urls ${L1_CONSENSUS_URL} \
  --sequencer.validatorPrivateKey ${VALIDATOR_PRIVATE_KEY} \
  --sequencer.coinbase ${COINBASE_ADDRESS} \
  --p2p.p2pIp ${NODE_IP}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL


# sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable aztec
sudo systemctl start aztec

echo -e "${GREEN}${BOLD}Aztec Node has been successfully configured and started as a service!${RESET}"
