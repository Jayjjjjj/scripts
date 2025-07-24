#!/bin/sh
# Docker & Docker Compose installer for Alpine/Debian

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Safety checks
die() {
  >&2 printf "${RED}FATAL: ${NC}%s\n" "$1"
  exit 1
}

is_root() {
  [ "$(id -u)" -eq 0 ] || die "This script must run as root/sudo!"
}

detect_os() {
  if grep -qi 'alpine' /etc/os-release; then
    echo "alpine"
  elif grep -qiE 'debian|ubuntu' /etc/os-release; then
    echo "debian"
  else
    die "Unsupported OS"
  fi
}

get_arch() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  echo "x86_64" ;;
    aarch64) echo "aarch64" ;;
    armv*)   echo "armv7" ;;
    *)       die "Unsupported architecture: $arch" ;;
  esac
}

install_docker() {
  os="$1"
  echo -e "${YELLOW}INSTALLING DOCKER${NC}"
  
  case $os in
    alpine)
      apk update
      apk add docker docker-cli-compose
      rc-update add docker boot
      service docker start || true
      ;;
    debian)
      # Official Docker installation for Debian-based
      apt update -qq
      apt install -y -qq \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common

      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
      apt update -qq
      apt install -y -qq docker-ce docker-ce-cli containerd.io
      systemctl enable --now docker || true
      ;;
  esac

  echo -e "${GREEN}Docker installed successfully${NC}"
}

install_compose() {
  arch="$1"
  temp_file="/tmp/dc_install_$(date +%s)"
  echo -e "${YELLOW}INSTALLING DOCKER COMPOSE${NC}"

  # Get latest version from GitHub
  LATEST_VERSION=$(curl -s "https://api.github.com/repos/docker/compose/releases/latest" | 
                  grep '"tag_name":' | 
                  sed -E 's/.*"([^"]+)".*/\1/')
  
  # Download and verify
  curl -L "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-linux-${arch}" \
    -o "$temp_file" \
    --progress-bar || die "Download failed"

  # Security: Verify binary execute perms
  [ -s "$temp_file" ] || die "Downloaded file is empty"
  
  # Correct architecture in filename
  if [ ! -f /usr/local/bin/docker-compose ]; then
    install -m 755 "$temp_file" /usr/local/bin/docker-compose
    echo -e "${GREEN}Compose ${LATEST_VERSION} installed to /usr/local/bin/${NC}"
    which docker-compose > /dev/null || echo "PATH=/usr/local/bin added permanently"  
  else
    echo -e "${YELLOW}Compose already exists - preserving existing version${NC}"
  fi
}

### MAIN FLOW ###
is_root
OS_TYPE=$(detect_os)
ARCH=$(get_arch)

echo -e "${GREEN}\n✨ Starting Docker installation for ${OS_TYPE} ${ARCH}${NC}"

# Install core packages
case $OS_TYPE in
  alpine) apk add curl jq sudo ;;
  debian) apt update && apt install -y curl jq ;;
esac

install_docker $OS_TYPE
install_compose $ARCH

# Validate installation
echo -e "\n${GREEN}VALIDATING INSTALLATION${NC}"
docker --version || die "Docker validation failed"
docker-compose --version || die "Docker Compose validation failed"

echo -e "\n✅ ${GREEN}INSTALLATION COMPLETE!${NC}\n"
echo "To run containers without 'sudo', add your user to docker group:"
echo "  sudo usermod -aG docker <user-name>"
echo -e "\n📘 Next step: Try running 'docker run hello-world'\n"
