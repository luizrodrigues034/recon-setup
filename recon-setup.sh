#!/usr/bin/env bash
#
# recon-setup.sh — Instala ferramentas de recon/bug bounty no Ubuntu
# Inclui: python3, unzip, go, jq, assetfinder, amass (snap), anew, findomain
# Extras: httpx, subfinder, nuclei, waybackurls, gau
# Testado em Ubuntu 22.04 / 24.04 (amd64 e arm64)
#
set -euo pipefail

# ---------- cores ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }

# ---------- checks iniciais ----------
if [[ $EUID -eq 0 ]]; then
    warn "Rodando como root. Recomendado rodar como usuário normal com sudo."
    REAL_HOME="/root"
else
    REAL_HOME="$HOME"
fi

if ! command -v sudo &>/dev/null; then
    err "sudo não encontrado. Instale primeiro: apt install sudo"
    exit 1
fi

# Detecta arquitetura
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        GO_ARCH="amd64"
        FINDOMAIN_ASSET="findomain-linux.zip"
        ;;
    aarch64|arm64)
        GO_ARCH="arm64"
        FINDOMAIN_ASSET="findomain-aarch64.zip"
        ;;
    *)
        err "Arquitetura não suportada: $ARCH"
        exit 1
        ;;
esac
log "Arquitetura detectada: $ARCH ($GO_ARCH)"

# ---------- 1. pacotes base via apt ----------
log "Atualizando índice apt..."
sudo apt-get update -y

log "Instalando pacotes base via apt..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    unzip \
    zip \
    jq \
    curl \
    wget \
    git \
    build-essential \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    dnsutils \
    whois \
    libpcap-dev \
    make \
    gcc \
    pkg-config

ok "Pacotes base instalados"

# ---------- 2. snapd ----------
if ! command -v snap &>/dev/null; then
    log "Instalando snapd..."
    sudo apt-get install -y snapd
    sudo systemctl enable --now snapd.socket || true
    [[ ! -e /snap ]] && sudo ln -sf /var/lib/snapd/snap /snap || true
    # dar um tempinho pro snapd subir
    sleep 3
fi

# ---------- 3. Go ----------
GO_VERSION="1.23.4"
GO_MIN="1.21"
INSTALL_GO=true

if command -v go &>/dev/null; then
    CURRENT_GO=$(go version | awk '{print $3}' | sed 's/go//')
    if [[ "$(printf '%s\n' "$GO_MIN" "$CURRENT_GO" | sort -V | head -n1)" == "$GO_MIN" ]]; then
        log "Go $CURRENT_GO já instalado (>= $GO_MIN), mantendo."
        INSTALL_GO=false
    else
        warn "Go $CURRENT_GO é antigo (< $GO_MIN); atualizando para $GO_VERSION"
    fi
fi

if $INSTALL_GO; then
    log "Instalando Go ${GO_VERSION} (${GO_ARCH})..."
    GO_TGZ="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    cd /tmp
    wget -q --show-progress "https://go.dev/dl/${GO_TGZ}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "${GO_TGZ}"
    rm -f "${GO_TGZ}"
    ok "Go ${GO_VERSION} instalado em /usr/local/go"
fi

# PATH do Go (sessão atual)
export GOPATH="${REAL_HOME}/go"
export PATH="${PATH}:/usr/local/go/bin:${GOPATH}/bin"
mkdir -p "${GOPATH}/bin"

# Persistência no ~/.bashrc e ~/.zshrc (se existir)
GO_PATH_MARKER='# === recon-setup.sh: Go PATH ==='
GO_PATH_BLOCK="
${GO_PATH_MARKER}
export GOPATH=\"\$HOME/go\"
export PATH=\"\$PATH:/usr/local/go/bin:\$GOPATH/bin\"
"
for rc in "${REAL_HOME}/.bashrc" "${REAL_HOME}/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -q "$GO_PATH_MARKER" "$rc"; then
        echo "$GO_PATH_BLOCK" >> "$rc"
        ok "PATH do Go adicionado em $rc"
    fi
done

if ! command -v go &>/dev/null; then
    err "Go não encontrado no PATH após instalação."
    exit 1
fi
ok "Go ativo: $(go version)"

# ---------- 4. ferramentas Go ----------
install_go_tool() {
    local pkg="$1"
    local name="$2"
    log "Instalando $name..."
    if go install -v "$pkg" 2>&1 | tail -5; then
        ok "$name instalado"
    else
        warn "Falha ao instalar $name"
    fi
}

install_go_tool "github.com/tomnomnom/assetfinder@latest"                      "assetfinder"
install_go_tool "github.com/tomnomnom/anew@latest"                             "anew"
install_go_tool "github.com/tomnomnom/waybackurls@latest"                      "waybackurls"
install_go_tool "github.com/projectdiscovery/httpx/cmd/httpx@latest"           "httpx"
install_go_tool "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" "subfinder"
install_go_tool "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"      "nuclei"
install_go_tool "github.com/lc/gau/v2/cmd/gau@latest"                          "gau"

# ---------- 5. findomain ----------
log "Instalando findomain (${FINDOMAIN_ASSET})..."
cd /tmp
FINDOMAIN_URL="https://github.com/Findomain/Findomain/releases/latest/download/${FINDOMAIN_ASSET}"
if wget -q "${FINDOMAIN_URL}" -O findomain.zip; then
    unzip -o -q findomain.zip
    chmod +x findomain
    sudo mv findomain /usr/local/bin/findomain
    rm -f findomain.zip
    ok "findomain: $(findomain --version 2>/dev/null | head -n1 || echo instalado)"
else
    err "Falha ao baixar findomain de $FINDOMAIN_URL"
fi

# ---------- 6. amass via snap (fallback go install) ----------
log "Instalando amass via snap..."
if sudo snap install amass 2>/dev/null; then
    ok "amass instalado via snap"
else
    warn "snap install amass falhou; tentando go install como fallback..."
    if go install -v github.com/owasp-amass/amass/v4/...@master; then
        ok "amass instalado via go install"
    else
        err "Falha ao instalar amass pelos dois métodos"
    fi
fi

# ---------- 7. nuclei templates (opcional, não quebra build se falhar) ----------
if command -v nuclei &>/dev/null; then
    log "Atualizando templates do nuclei..."
    nuclei -update-templates -silent 2>/dev/null || warn "Falha ao atualizar templates do nuclei"
fi

# ---------- 8. verificação final ----------
echo
log "=== Verificação final ==="
check() {
    if command -v "$1" &>/dev/null; then
        ok "$(printf '%-14s' "$1") -> $(command -v "$1")"
    else
        err "$(printf '%-14s' "$1") NÃO encontrado"
    fi
}

for tool in python3 pip3 unzip jq curl wget git go \
            assetfinder anew findomain amass \
            httpx subfinder nuclei waybackurls gau; do
    check "$tool"
done

echo
ok "Setup concluído!"
warn "Execute: source ~/.bashrc   (ou abra um novo terminal) para carregar o PATH do Go"
