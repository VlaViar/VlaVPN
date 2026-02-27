#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}              Xray + 3X-UI              ${NC}"
echo -e "${GREEN}========================================${NC}"

# Root check
[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ Run as root (sudo -i)${NC}"; exit 1; }

# OS detection
if grep -qi "ID=debian" /etc/os-release; then
    OS_NAME="debian"
    CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release 2>/dev/null || echo "bookworm")
else
    echo -e "${RED}❌ Only Debian supported${NC}"
    exit 1
fi
echo -e "${GREEN}✓ OS: ${OS_NAME^} ${CODENAME}${NC}"

# Checking (and installing) the sudo package
if ! command -v sudo &> /dev/null; then
    echo -e "${YELLOW}Sudo is not installed.${NC}"
    read -p "Do you want to install sudo? (y/n): " INSTALL_SUDO
    if [[ "$INSTALL_SUDO" == "y" ]]; then
        echo -e "${BLUE}Installing sudo...${NC}"
        if command -v apt &> /dev/null; then
            apt update && apt install -y sudo
        else
            echo -e "${RED}❌ Cannot detect package manager. Please install sudo manually.${NC}"
            exit 1
        fi

        if ! command -v sudo &> /dev/null; then
            echo -e "${RED}❌ Failed to install sudo.${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Sudo installed successfully.${NC}"
    else
        echo -e "${RED}❌ Sudo is required for this script.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Sudo has already been installed.${NC}"
fi

# Create user
echo -e "${BLUE}[1/11] Creating user...${NC}"
read -p "Username (not root): " USER
[[ -z "$USER" || "$USER" == "root" ]] && { echo -e "${RED}❌ Invalid username.${NC}"; exit 1; }
id "$USER" &>/dev/null || adduser --disabled-password --gecos "" "$USER"
if grep -i "$USER" /etc/passwd &>/dev/null; then
echo -e "${GREEN}✓ The $USER user has been successfully created.${NC}"
else
echo -e "${RED}❌ User creation error.${NC}" && exit 1
fi

# Adding a user to the sudo group
echo -e "${BLUE}[2/11] Adding a user to the sudo group...${NC}"
mkdir -p /etc/sudoers.d
echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USER"
chmod 440 /etc/sudoers.d/"$USER"
if ! visudo -c -f /etc/sudoers.d/"$USER" &>/dev/null; then
    echo -e "${RED}❌ Sudoers syntax check failed. Removing file.${NC}"
    rm -f /etc/sudoers.d/"$USER"
    exit 1
fi
echo -e "${GREEN}✓ Sudo configured successfully.${NC}"

# Adding SSH key
echo -e "${YELLOW}! Run on your local machine: 'ssh-keygen -t ed25519 -C \"vpn_key\" -f ~/.ssh/vpn-key'${NC}"
read -p "Ready? (y/n): " answer
[[ "$answer" != "y" ]] && exit 1
echo -e "${YELLOW}! Paste your public SSH key:${NC}"
read -s -p "Key: " KEY
[[ ! "$KEY" =~ ^ssh-(rsa|ed25519|ecdsa) ]] && { echo -e "${RED}Invalid key format${NC}"; exit 1; }
echo -e "${BLUE}[3/11] Adding SSH key...${NC}"
mkdir -p /home/"$USER"/.ssh
echo "$KEY" > /home/"$USER"/.ssh/authorized_keys
chmod 700 /home/"$USER"/.ssh
chmod 600 /home/"$USER"/.ssh/authorized_keys
chown -R "$USER":"$USER" /home/"$USER"/.ssh
if grep -i 'vpn_key' /home/"$USER"/.ssh/authorized_keys; then
echo -e "${GREEN}✓ SSH key 'vpn_key' has been successfully created.${NC}"
else
echo -e "${RED}❌ SSH key creation error.${NC}" && exit 1
fi

# SSH configuration
echo -e "${YELLOW}! Enter a free SSH port:${NC}"
read -p "Port: " SSH_PORT
echo -e "${BLUE}[4/11] Configuring SSH...${NC}"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 || SSH_PORT == 22 )); then
    echo -e "${RED}❌ Invalid port. Must be 1024-65535 and not 22.${NC}"
    exit 1
fi
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup-"$(date +%F)"
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
echo -e "${GREEN}✓ SSH configured.${NC}"

# Installing the necessary packages
echo -e "${BLUE}[5/11] Installing the necessary packages...${NC}"
apt update -q && apt upgrade -y
apt install -y -q ufw fail2ban iptables curl openssl ca-certificates gnupg jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$OS_NAME/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg -q
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_NAME $CODENAME stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update -q
apt install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
    echo -e "${RED}❌ Docker compose not available. Install manually docker-compose-plugin.${NC}"
    exit 1
fi
usermod -aG docker "$USER"
if groups "$USER" | grep docker && dpkg -l | grep docker-ce; then
    echo -e "${GREEN}✓ All necessary packages are installed.${NC}"
else
    echo -e "${RED}❌ Package installation error.${NC}" && exit 1
fi

# Install 3X-UI
echo -e "${BLUE}[6/11] Downloading and starting 3X-UI...${NC}"
INSTALL_DIR="/home/$USER/3x-ui"
DATA_DIR="$INSTALL_DIR/db"
CERT_DIR="$INSTALL_DIR/cert"
mkdir -p "$DATA_DIR"
mkdir -p "$CERT_DIR"
cd "$INSTALL_DIR"
cat > docker-compose.yml <<EOF
services:
  x-ui:
    image: ghcr.io/mhsanaei/3x-ui:v2.8.10
    container_name: 3x-ui
    restart: unless-stopped
    network_mode: host
    volumes:
      - $DATA_DIR:/etc/x-ui
      - $CERT_DIR:/root/cert
EOF
docker pull ghcr.io/mhsanaei/3x-ui:v2.8.10 -q 2>/dev/null
sleep 10
docker compose down -v 2>/dev/null || true
docker compose up -d --no-build --quiet-pull
sleep 10
if docker inspect 3x-ui --format='{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    echo -e "${GREEN}✓ Container started successfully.${NC}"
else
    echo -e "${RED}❌ 3X-UI failed to start. Logs:${NC}"
    docker logs 3x-ui 2>&1 | tail -30 || echo -e "${RED}❌ Container not created.${NC}"
    exit 1
fi

# Configure ufw
echo -e "${BLUE}[7/11] Configuring ufw...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment "SSH"
ufw allow 443/tcp comment "VLESS+Reality"
ufw allow 2053/tcp comment "3X-UI(panel)"
ufw allow 2096/tcp comment "3X-UI(sub)"
ufw --force enable
echo -e "${GREEN}✓ Ufw is configured successfully.${NC}"

# Configure fail2ban
rm -f /etc/fail2ban/jail.d/* 2>/dev/null
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = auto

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
ignoreip = 127.0.0.1/8 ::1
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban
echo -e "${GREEN}✓ UFW and Fail2ban configured${NC}"

# Download RealiTLScanner
echo -e "${BLUE}[8/11] Downloading RealiTLScanner...${NC}"
mkdir -p /usr/local/bin
if curl -fsSL -o /usr/local/bin/realitlscanner https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.1/RealiTLScanner-linux-64; then
    chmod +x /usr/local/bin/realitlscanner
    if ls /usr/local/bin/realitlscanner; then
        echo -e "${GREEN}✓ RealiTLScanner has been successfully installed${NC}"
    else
        echo -e "${RED}❌ The binary was not found.${NC}"
    fi
else
    echo -e "${YELLOW}❌ Failed to download RealiTLScanner. Skipping...${NC}"
fi

# Creating and adding a certificate for the 3X-UI panel
echo -e "${BLUE}[9/11] Creating and adding a certificate for the 3X-UI panel...${NC}"
sudo mkdir -p $CERT_DIR
IP=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
sudo openssl req -x509 -newkey rsa:4096 -keyout $CERT_DIR/panel.key \
  -out $CERT_DIR/panel.crt -days 3650 -nodes \
  -subj "/CN=3x-ui-panel" \
  -addext "subjectAltName=IP:$IP"
if openssl x509 -in $CERT_DIR/panel.crt -text -noout | grep -A2 "Subject Alternative Name"; then
    echo -e "${GREEN}✓ Certificate has been successfully created and installed.${NC}"
else
    echo -e "${RED}❌ The certificate was created or added with an error.${NC}"
fi

# Configuring 3X-UI panel
echo -e "${BLUE}[10/11] Configuring 3X-UI panel...${NC}"
read -s -p "New password to login to the panel: " PASS_PAN
echo ""
read -p "New port for connect to panel: " PORT_PAN
read -p "Panel path suffix (default: /panel/): " PATH_PAN
read -p "Subscription port (default: 2096): " PORT_SUB
read -p "Subscription path suffix (default: /sub/): " PATH_SUB
[[ -z "$PASS_PAN" || "$PASS_PAN" == "admin" ]] && { echo -e "${RED}❌ Invalid password.${NC}"; exit 1; }
[[ -z "$PORT_PAN" || "$PORT_PAN" == "2053" ]] && { echo -e "${RED}❌ Invalid port.${NC}"; exit 1; }
COOKIE=/tmp/3x-ui_cookie.txt
echo -e "Path to cookie file: $COOKIE"
curl -k -s -c $COOKIE -X POST \
    "http://127.0.0.1:2053/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin&password=admin"
curl -k -s -b /tmp/3x-ui_cookie.txt -X POST \
  "http://127.0.0.1:2053/panel/setting/update" \
  -H "Content-Type: application/json" \
  -d "{
    \"webListen\":\"\",
    \"webDomain\":\"\",
    \"webPort\":${PORT_PAN},
    \"webCertFile\":\"/root/cert/panel.crt\",
    \"webKeyFile\":\"/root/cert/panel.key\",
    \"webBasePath\":\"/panel-${PATH_PAN}/\",
    \"sessionMaxAge\":360,
    \"pageSize\":25,
    \"expireDiff\":0,
    \"trafficDiff\":0,
    \"remarkModel\":\"-ieo\",
    \"datepicker\":\"gregorian\",
    \"tgBotEnable\":false,
    \"tgBotToken\":\"\",
    \"tgBotProxy\":\"\",
    \"tgBotAPIServer\":\"\",
    \"tgBotChatId\":\"\",
    \"tgRunTime\":\"@daily\",
    \"tgBotBackup\":false,
    \"tgBotLoginNotify\":true,
    \"tgCpu\":80,
    \"tgLang\":\"ru-RU\",
    \"timeLocation\":\"Local\",
    \"twoFactorEnable\":false,
    \"twoFactorToken\":\"\",
    \"subEnable\":true,
    \"subJsonEnable\":false,
    \"subTitle\":\"\",
    \"subSupportUrl\":\"\",
    \"subProfileUrl\":\"\",
    \"subAnnounce\":\"\",
    \"subEnableRouting\":true,
    \"subRoutingRules\":\"\",
    \"subListen\":\"\",
    \"subPort\":${PORT_SUB},
    \"subPath\":\"/sub-${PATH_SUB}/\",
    \"subDomain\":\"\",
    \"subCertFile\":\"\",
    \"subKeyFile\":\"\",
    \"subUpdates\":12,
    \"externalTrafficInformEnable\":false,
    \"externalTrafficInformURI\":\"\",
    \"subEncrypt\":true,
    \"subShowInfo\":true,
    \"subURI\":\"\",
    \"subJsonPath\":\"/json/\",
    \"subJsonURI\":\"\",
    \"subJsonFragment\":\"\",
    \"subJsonNoises\":\"\",
    \"subJsonMux\":\"\",
    \"subJsonRules\":\"\",
    \"ldapEnable\":false,
    \"ldapHost\":\"\",
    \"ldapPort\":389,
    \"ldapUseTLS\":false,
    \"ldapBindDN\":\"\",
    \"ldapPassword\":\"\",
    \"ldapBaseDN\":\"\",
    \"ldapUserFilter\":\"(objectClass=person)\",
    \"ldapUserAttr\":\"mail\",
    \"ldapVlessField\":\"vless_enabled\",
    \"ldapSyncCron\":\"@every 1m\",
    \"ldapFlagField\":\"\",
    \"ldapTruthyValues\":\"true,1,yes,on\",
    \"ldapInvertFlag\":false,
    \"ldapInboundTags\":\"\",
    \"ldapAutoCreate\":false,
    \"ldapAutoDelete\":false,
    \"ldapDefaultTotalGB\":0,
    \"ldapDefaultExpiryDays\":0,
    \"ldapDefaultLimitIP\":0
  }"
curl -k -s -b $COOKIE -X POST \
  "http://127.0.0.1:2053/panel/setting/updateUser" \
  -H "Content-Type: application/json" \
  -d "{\"oldUsername\":\"admin\",\"oldPassword\":\"admin\",\"newUsername\":\"admin\",\"newPassword\":\"${PASS_PAN}\"}"
curl -k -s -b $COOKIE -X POST "http://127.0.0.1:2053/panel/setting/restartPanel"
ufw allow $PORT_PAN/tcp comment '3X-UI' && ufw delete allow 2053/tcp && ufw reload
rm -f $COOKIE
echo -e "${GREEN}✓ Password and port for access to panel successfully edited.${NC}"

# Checking and restarting SSH
echo -e "${BLUE}[11/11] Checking and restarting SSH...${NC}"
if ! sshd -t 2>/dev/null; then
    echo -e "${RED}❌ SSH config syntax error.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ SSH config syntax is valid.${NC}"
if ss -tulpn 2>/dev/null | grep -q ":$SSH_PORT.*LISTEN" && ! ss -tulpn 2>/dev/null | grep -q ":$SSH_PORT.*sshd"; then
    echo -e "${RED}❌ Port $SSH_PORT is not available.${NC}"
    ss -tulpn | grep ":$SSH_PORT"
    exit 1
fi
echo -e "${GREEN}✓ Port $SSH_PORT is available for SSH.${NC}"
if [[ $(stat -c "%a" /home/"$USER"/.ssh) != "700" ]] || [[ $(stat -c "%a" /home/"$USER"/.ssh/authorized_keys) != "600" ]]; then
    echo -e "${YELLOW}! Incorrect permissions on .ssh or authorized_keys — fixing.${NC}"
    chmod 700 /home/"$USER"/.ssh
    chmod 600 /home/"$USER"/.ssh/authorized_keys
    chown -R "$USER":"$USER" /home/"$USER"/.ssh
fi
echo -e "${GREEN}✓ SSH key configured correctly.${NC}"
sleep 2
echo ""
echo -e "${YELLOW}SSH daemon will be restarted now.${NC}"
echo -e "${YELLOW}DO NOT CLOSE THIS SESSION until you verify connection!${NC}"
echo ""
read -p "Confirm that you will keep this session open and test the SSH connection in a new window (y/n)?:" confirm_final
[[ "$confirm_final" != "y" ]] && { echo "SSH restart cancelled by user"; exit 0; }
echo -e "${BLUE}Restarting SSH daemon...${NC}"
if systemctl restart sshd 2>/dev/null; then
    echo -e "${GREEN}✓ SSH restarted successfully.${NC}"
    sleep 2
    if ss -tulpn 2>/dev/null | grep "$SSH_PORT" | grep -q LISTEN; then
        echo -e "${GREEN}✓ SSH listening on port $SSH_PORT.${NC}"
    else
        echo -e "${RED}❌ SSH not listening on port $SSH_PORT — check logs:${NC}"
        echo "journalctl -u sshd -n 20 --no-pager"
        exit 1
    fi
else
    echo -e "${RED}❌ Failed to restart SSH.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   The script completed successfully!   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}The following steps to follow are:${NC}"
echo -e "1. Copy the command below and paste it into the terminal on your device to connect via ssh with the new settings to this server:"
echo -e "   ${BLUE}ssh -p $SSH_PORT $USER@$IP -i ~/.ssh/vpn-key${NC}"
echo -e "2. In panel settings change:"
echo -e "   •${BLUE} Panel port: from 2053 to any port in range 10000-65535${NC}"
echo -e "   •${BLUE} Subscription port: from 2096 to any port in range 10000-65535${NC}"
echo -e "   •${BLUE} Panel path: from / to custom path${NC}"
echo -e "   •${BLUE} 127.0.0.1 (block external access)${NC}"
echo -e "   •${BLUE} Change path to the panel's key: $CERT_DIR/panel.key${NC}"
echo -e "   •${BLUE} Change path to the panel's certificate: $CERT_DIR/panel.crt${NC}"
echo -e "   •${BLUE} Change default login/password to strong custom credentials${NC}"
