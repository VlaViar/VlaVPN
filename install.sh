#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export APT_OPTIONS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

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
[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ The launch is not from root.${NC}"; exit 1; }
echo -e "${GREEN}✓ Starting from root.${NC}"

# OS detection
if grep -qi "ID=debian" /etc/os-release; then
    OS_NAME="debian"
    CODENAME=$(awk -F= '/^VERSION_CODENAME=/ {print $2}' /etc/os-release 2>/dev/null || echo "bookworm")
else
    echo -e "${RED}❌ Only Debian supported${NC}"
    exit 1
fi
echo -e "${GREEN}✓ OS: ${OS_NAME^} ${CODENAME}${NC}"

# Checking (and installing) the sudo package
if ! command -v sudo &> /dev/null; then
    echo -e "${RED}❌ Sudo is not installed.${NC}"
    read -p "Do you want to install sudo? (y/n): " INSTALL_SUDO
    if [[ "$INSTALL_SUDO" == "y" ]]; then
        echo -e "${BLUE}Installing sudo...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y sudo -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
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

# Off GA on host
if systemctl list-units --all | grep "qemu-guest-agent.service" > /dev/null ; then
    echo -e "${YELLOW}The GA agent was found on the host.${NC}"
    echo -e "${BLUE}Started process configuring GA...${NC}"
    sudo mkdir -p /etc/qemu
    sudo tee /etc/qemu/qemu-ga.conf > /dev/null << 'EOF'
[general]
block-rpcs = ["guest-file-open","guest-file-read","guest-file-write","guest-file-seek","guest-file-flush","guest-file-close","guest-exec","guest-exec-status","guest-set-user-password","guest-set-time"]
loglevel = info
EOF
    if ! [ $? -eq 0 ]; then
        echo -e "${RED}✗ Failed to write config.${NC}"
        exit 1
    fi
    sudo systemctl daemon-reload
    sudo systemctl restart qemu-guest-agent.service
    sleep 1
    if systemctl status qemu-guest-agent.service | grep -wiq "active"; then
        echo -e "${GREEN}✓ Service successfully configured and restarted.${NC}"
    else
        echo -e "${RED}✗ Service failed to start.${NC}"
        exit 1
    fi
fi

# Inputting all necessary values
echo -e "${BLUE}[Preparation] Inputting all necessary values...${NC}"
read -p "Username (not root): " NAME_USER
[[ -z "$NAME_USER" || "$NAME_USER" == "root" ]] && { echo -e "${RED}❌ Invalid username.${NC}"; exit 1; }
read -p "New SSH connection port: " PORT_SSH
if ! [[ "$PORT_SSH" =~ ^[0-9]+$ ]] || (( PORT_SSH < 1024 || PORT_SSH > 65535 || PORT_SSH == 22 )); then
    echo -e "${RED}❌ Invalid port. Must be 1024-65535 and not 22.${NC}"
    exit 1
fi
read -p "Name and comment for SSH key: " NAME_SSH_KEY
[[ -z "$NAME_SSH_KEY" ]] && { echo -e "${RED}❌ Invalid key name.${NC}"; exit 1; }
echo -e "Run on your local machine: ${BLUE}ssh-keygen -t ed25519 -C \"$NAME_SSH_KEY\" -f ~/.ssh/$NAME_SSH_KEY${NC}"
read -s -p "Your public SSH key: " SSH_KEY
echo ""
[[ ! "$SSH_KEY" =~ ^ssh-(rsa|ed25519|ecdsa-sha2-) ]] && { echo -e "${RED}❌ Invalid key format${NC}"; exit 1; }
read -p "New port for connect to panel (anyone, except: 2053): " PORT_PAN
[[ -z "$PORT_PAN" || ! "$PORT_PAN" =~ ^[0-9]+$ || "$PORT_PAN" == "2053" ]] && { echo -e "${RED}❌ Invalid port.${NC}"; exit 1; }
read -p "Subscription port (anyone, except: 2096): " PORT_SUB
[[ -z "$PORT_SUB" || ! "$PORT_SUB" =~ ^[0-9]+$ || "$PORT_SUB" == "2096" ]] && { echo -e "${RED}❌ Invalid port.${NC}"; exit 1; }
read -s -p "New password to login to the panel: " PASS_PAN ; echo ""
[[ -z "$PASS_PAN" || "$PASS_PAN" == "admin" ]] && { echo -e "${RED}❌ Invalid password.${NC}"; exit 1; }
read -p "Panel path suffix (anyone, except: /panel/): " PATH_PAN
[[ -z "$PATH_PAN" || "$PATH_PAN" == "/panel/" ]] && { echo -e "${RED}❌ Invalid path.${NC}"; exit 1; }
read -p "Subscription path suffix (anyone, except: /sub/): " PATH_SUB
[[ -z "$PATH_SUB" || "$PATH_SUB" == "/sub/" ]] && { echo -e "${RED}❌ Invalid path.${NC}"; exit 1; }

# Create user
echo -e "${BLUE}[1/11] Creating user...${NC}"
id "$NAME_USER" &>/dev/null || adduser --disabled-password --gecos "" "$NAME_USER"
if grep -i "$NAME_USER" /etc/passwd &>/dev/null; then
    echo -e "${GREEN}✓ The user $NAME_USER has been successfully created.${NC}"
else
    echo -e "${RED}❌ User creation error.${NC}"
    exit 1
fi

# Adding a user to the sudo group
echo -e "${BLUE}[2/11] Adding a user to the sudo group...${NC}"
mkdir -p /etc/sudoers.d
echo "$NAME_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$NAME_USER"
chmod 440 /etc/sudoers.d/"$NAME_USER"
if ! visudo -c -f /etc/sudoers.d/"$NAME_USER" &>/dev/null; then
    echo -e "${RED}❌ Sudoers syntax check failed. Removing file.${NC}"
    rm -f /etc/sudoers.d/"$NAME_USER"
    exit 1
fi
echo -e "${GREEN}✓ Sudo configured successfully.${NC}"

# Adding SSH key
echo -e "${BLUE}[3/11] Adding SSH key...${NC}"
mkdir -p /home/"$NAME_USER"/.ssh
echo "$SSH_KEY" > /home/"$NAME_USER"/.ssh/authorized_keys
chmod 700 /home/"$NAME_USER"/.ssh
chmod 600 /home/"$NAME_USER"/.ssh/authorized_keys
chown -R "$NAME_USER":"$NAME_USER" /home/"$NAME_USER"/.ssh
if grep -qE '^ssh-(ed25519|rsa|ecdsa)' /home/"$NAME_USER"/.ssh/authorized_keys; then
    echo -e "${GREEN}✓ SSH key added.${NC}"
else
    echo -e "${RED}❌ SSH key validation failed.${NC}"
    exit 1
fi

# Configuring SSH
echo -e "${BLUE}[4/11] Configuring SSH...${NC}"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup-"$(date +%F)"
sed -i "s/^#*Port .*/Port $PORT_SSH/" /etc/ssh/sshd_config
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
grep -q "^Port $PORT_SSH" /etc/ssh/sshd_config || echo "Port $PORT_SSH" >> /etc/ssh/sshd_config
sshd -t || { echo -e "${RED}❌ SSH config syntax error${NC}"; exit 1; }
if [[ -d /home/"$NAME_USER"/.ssh ]]; then
    if [[ $(stat -c "%a" /home/"$NAME_USER"/.ssh) != "700" ]]; then
        chmod 700 /home/"$NAME_USER"/.ssh
        chown "$NAME_USER":"$NAME_USER" /home/"$NAME_USER"/.ssh
    fi
fi
if [[ -f /home/"$NAME_USER"/.ssh/authorized_keys ]]; then
    if [[ $(stat -c "%a" /home/"$NAME_USER"/.ssh/authorized_keys) != "600" ]]; then
        chmod 600 /home/"$NAME_USER"/.ssh/authorized_keys
        chown "$NAME_USER":"$NAME_USER" /home/"$NAME_USER"/.ssh/authorized_keys
    fi
fi
echo -e "${GREEN}✓ SSH configured.${NC}"

# Installing the necessary packages
echo -e "${BLUE}[5/11] Installing the necessary packages...${NC}"
apt-get update -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
apt-get install -q -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    bash-completion tree net-tools ufw fail2ban iptables curl openssl ca-certificates gnupg git sqlite3
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$OS_NAME/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg -q
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_NAME $CODENAME stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
apt-get install -q -y \
 -o Dpkg::Options::=--force-confdef \
 -o Dpkg::Options::=--force-confold \
 docker-ce docker-ce-cli containerd.io docker-compose-plugin
apt-get upgrade -q -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
for i in {1..10}; do
    systemctl is-active --quiet docker && break
    sleep 1
done
if ! systemctl is-active --quiet docker; then
    echo -e "${RED}❌ Docker launch failed${NC}"
    exit 1
fi
if ! command -v docker &>/dev/null; then
    echo -e "${RED}❌ Docker installation failed${NC}"
    exit 1
fi
if ! command -v docker compose &>/dev/null; then
    echo -e "${RED}❌ Docker-compose plugin installation failed${NC}"
    exit 1
fi
usermod -aG docker "$NAME_USER"
if ! groups "$NAME_USER" | grep -qw docker; then
    echo -e "${RED}❌ Error adding user \"$NAME_USER\" in docker group${NC}"
    exit 1
fi
mkdir -p /usr/local/bin
if curl -fsSL -o /usr/local/bin/realitlscanner https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.1/RealiTLScanner-linux-64 >/dev/null; then
    chmod +x /usr/local/bin/realitlscanner
else
    echo -e "${RED}❌ Failed to install RealiTLScanner.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ All necessary packages are installed.${NC}"

# Downloading and starting 3X-UI
sleep 1
echo -e "${BLUE}[6/11] Downloading and starting 3X-UI...${NC}"
INSTALL_DIR="/home/$NAME_USER/3x-ui"
DATA_DIR="$INSTALL_DIR/db"
CERT_DIR="$INSTALL_DIR/cert"
mkdir -p "$INSTALL_DIR"
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
if ! docker pull ghcr.io/mhsanaei/3x-ui:v2.8.10 -q; then
    echo -e "${RED}❌ Failed to pull 3X-UI image${NC}"
    exit 1
fi
sleep 5
docker compose down -v 2>/dev/null || true
docker compose up -d --no-build --quiet-pull
sleep 5
for i in {1..30}; do
    if docker inspect 3x-ui --format='{{.State.Running}}' 2>/dev/null | grep -q "true"; then
        break
    fi
    sleep 1
done
if docker inspect 3x-ui --format='{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    echo -e "${GREEN}✓ 3X-UI container successfully downloaded and started.${NC}"
else
    echo -e "${RED}❌ 3X-UI failed to start. Logs:${NC}"
    docker logs 3x-ui 2>&1 | tail -20
    exit 1
fi

# Configuring ufw and fail2ban
echo -e "${BLUE}[7/11] Configuring ufw and fail2ban...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$PORT_SSH"/tcp comment "SSH"
ufw allow 443/tcp comment "VLESS+Reality"
ufw allow "$PORT_PAN"/tcp comment "3X-UI(panel)"
ufw allow "$PORT_SUB"/tcp comment "3X-UI(sub)"
ufw --force enable
sleep 1
if ! ufw status | grep -q "Status: active"; then
    echo -e "${RED}❌ Error configuring or launching ufw${NC}"
    exit 1
fi
rm -f /etc/fail2ban/jail.d/* 2>/dev/null
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = $PORT_SSH
filter = sshd
logpath = sshd
maxretry = 5
bantime = 1h
findtime = 10m
ignoreip = 127.0.0.1/8 ::1
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 1
if ! systemctl is-active --quiet fail2ban; then
    echo -e "${RED}❌ Error configuring or launching fail2ban${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Ufw and fail2ban successfully configured${NC}"

# Creating and adding a certificate for the 3X-UI panel
echo -e "${BLUE}[8/11] Creating and adding a certificate for the 3X-UI panel...${NC}"
mkdir -p $CERT_DIR
IP=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
openssl req -x509 -newkey rsa:4096 -keyout $CERT_DIR/panel.key \
  -out $CERT_DIR/panel.crt -days 3650 -nodes \
  -subj "/CN=3x-ui-panel" \
  -addext "subjectAltName=IP:$IP"
chmod 640 $CERT_DIR/panel.*
if openssl x509 -in $CERT_DIR/panel.crt -text -noout | grep -A2 "Subject Alternative Name"; then
    echo -e "${GREEN}✓ Certificate has been successfully created and installed.${NC}"
else
    echo -e "${RED}❌ The certificate was created or added with an error.${NC}"
    exit 1
fi

# Configuring 3X-UI panel
echo -e "${BLUE}[9/11] Configuring 3X-UI panel...${NC}"
COOKIE=/tmp/3x-ui_cookie.txt
echo -e "Path to cookie file: $COOKIE"
curl -k -s -f -c $COOKIE -X POST \
    "http://127.0.0.1:2053/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin&password=admin"
curl -k -s -f -b /tmp/3x-ui_cookie.txt -X POST \
  "http://127.0.0.1:2053/panel/setting/update" \
  -H "Content-Type: application/json" \
  -d "{
    \"webListen\":\"\",
    \"webDomain\":\"\",
    \"webPort\":${PORT_PAN},
    \"webCertFile\":\"/root/cert/panel.crt\",
    \"webKeyFile\":\"/root/cert/panel.key\",
    \"webBasePath\":\"/${PATH_PAN}/\",
    \"sessionMaxAge\":180,
    \"pageSize\":0,
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
    \"subPath\":\"/${PATH_SUB}/\",
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
curl -k -s -f -b $COOKIE -X POST \
  "http://127.0.0.1:2053/panel/setting/updateUser" \
  -H "Content-Type: application/json" \
  -d "{\"oldUsername\":\"admin\",\"oldPassword\":\"admin\",\"newUsername\":\"admin\",\"newPassword\":\"${PASS_PAN}\"}"
curl -k -s -f -b $COOKIE -X POST "http://127.0.0.1:2053/panel/setting/restartPanel" ; echo ""
rm -f $COOKIE
echo -e "${GREEN}✓ Password and port for access to panel successfully edited.${NC}"

# Removing not used packages
echo -e "${BLUE}[10/11] Removing not used packages...${NC}"
apt-get autoremove -y -q
apt-get autoclean -q
echo -e "${GREEN}✓ Cleanup completed.${NC}"

# Restarting and checking SSH
echo -e "${BLUE}[11/11] Restarting and checking SSH...${NC}"
echo ""
echo -e "${YELLOW}SSH daemon will be restarted now.${NC}"
echo -e "${YELLOW}Do not terminate this SSH session until you see the final output with the command for a new SSH connection!${NC}"
echo ""
echo -e "${BLUE}Restarting SSH daemon...${NC}"
if systemctl restart sshd 2>/dev/null; then
    echo -e "${GREEN}✓ SSH restarted successfully.${NC}"
else
    echo -e "${RED}❌ Failed to restart SSH.${NC}"
    exit 1
fi
if ss -tulpn 2>/dev/null | grep -q ":$PORT_SSH.*LISTEN" && ! ss -tulpn 2>/dev/null | grep -q ":$PORT_SSH.*sshd"; then
    echo -e "${RED}❌ Port $PORT_SSH is not available.${NC}"
    ss -tulpn | grep ":$PORT_SSH"
    exit 1
fi
echo -e "${GREEN}✓ SSH listening on port $PORT_SSH.${NC}"

# Final output
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   The script completed successfully!   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Copy the command below, open a new terminal window on your device without closing the current one, and SSH into this server with the new settings:"
echo -e "${BLUE}ssh -p $PORT_SSH $NAME_USER@$IP -i ~/.ssh/$NAME_SSH_KEY${NC}"
echo ""
echo "Enter this link in search bar browser for connect to panel:"
echo -e "${BLUE}https://$IP:$PORT_PAN/$PATH_PAN/${NC}"