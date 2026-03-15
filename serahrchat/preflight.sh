#!/usr/bin/env bash
# =============================================================================
# SerahrChat Preflight Check & Installer
# =============================================================================
# Standalone script to verify server readiness for SerahrChat deployment.
# Downloads a pre-built Docker image — no git clone or local build required.
#
# Usage:
#   curl -fsSL https://update.serahr.de/serahrchat/preflight.sh | sudo bash
#   -- or --
#   sudo bash preflight.sh
#   sudo bash preflight.sh --install          # run install after checks
#   sudo bash preflight.sh --install --trial   # install in 7-day trial mode
# =============================================================================
set -euo pipefail

# --- Config ---
MIN_RAM_MB=1800
MIN_DISK_MB=1000
MIN_DOCKER_MAJOR=20
REQUIRED_PORTS=(80 443)
OUTBOUND_TEST_HOST="api.openrouter.ai"
OUTBOUND_TEST_PORT=443
DOCKER_IMAGE="ghcr.io/reeb78/serahrchat"
INSTALL_TOKEN_URL="https://licence.serahr.de/api/v1/install-token"
INSTALL_DIR="/opt/serahrchat"
SECRETS_DIR="$INSTALL_DIR/secrets"
DATA_DIR="$INSTALL_DIR/data"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass_count=0
warn_count=0
fail_count=0

ok()   { pass_count=$((pass_count + 1)); echo -e "  ${GREEN}[OK]${NC}    $1"; }
warn() { warn_count=$((warn_count + 1)); echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
fail() { fail_count=$((fail_count + 1)); echo -e "  ${RED}[FAIL]${NC}  $1"; }

# =============================================================================
# Logging Infrastructure
# =============================================================================
DIAG_LOG=""
INSTALL_START_TS=0
REPORT_GENERATED=false

# Parallel arrays for step tracking (portable, no grep -oP needed)
STEP_NAMES=()
STEP_TYPES=()
STEP_DURATIONS=()
STEP_EXITS=()
CURRENT_STEP=""
CURRENT_STEP_START=0
CURRENT_STEP_TYPE=""

init_logging() {
  mkdir -p "$INSTALL_DIR/logs" "$DATA_DIR"
  DIAG_LOG="$INSTALL_DIR/logs/install-$(date +%Y%m%d-%H%M%S).log"
  INSTALL_START_TS=$(date +%s)
  diag "=== SerahrChat Installation Diagnostic Log ==="
  diag "Timestamp: $(date -Iseconds)"
  diag "Hostname: $(hostname -f 2>/dev/null || hostname)"
  diag "OS: ${OS_INFO:-unknown}"
  diag "Kernel: $(uname -r)"
  diag "Arch: $(uname -m)"
  diag "RAM: ${TOTAL_RAM_MB:-unknown} MB"
  diag "Disk: ${DISK_AVAIL_MB:-unknown} MB free"
  diag "Docker: $(docker --version 2>/dev/null || echo 'not installed')"
  diag "Preflight: passed=$pass_count warn=$warn_count fail=$fail_count"
}

diag() {
  [ -n "$DIAG_LOG" ] && echo "[$(date +%H:%M:%S)] $*" >> "$DIAG_LOG"
}

step_start() {
  CURRENT_STEP="$1"
  CURRENT_STEP_TYPE="${2:-system}"
  CURRENT_STEP_START=$(date +%s)
  diag ">>> STEP: $CURRENT_STEP (type=$CURRENT_STEP_TYPE)"
}

step_end() {
  local rc="${1:-0}"
  local end_ts
  end_ts=$(date +%s)
  local dur=$((end_ts - CURRENT_STEP_START))
  diag "<<< STEP: $CURRENT_STEP (${dur}s, exit=$rc)"
  STEP_NAMES+=("$CURRENT_STEP")
  STEP_TYPES+=("$CURRENT_STEP_TYPE")
  STEP_DURATIONS+=("$dur")
  STEP_EXITS+=("$rc")
}

generate_report() {
  local end_ts
  end_ts=$(date +%s)
  local total=$((end_ts - INSTALL_START_TS))
  local system_time=0
  local user_time=0

  for i in "${!STEP_NAMES[@]}"; do
    if [ "${STEP_TYPES[$i]}" = "user_input" ]; then
      user_time=$((user_time + STEP_DURATIONS[$i]))
    else
      system_time=$((system_time + STEP_DURATIONS[$i]))
    fi
  done

  # Build steps JSON array
  local steps_json="["
  for i in "${!STEP_NAMES[@]}"; do
    [ "$i" -gt 0 ] && steps_json+=","
    steps_json+="$(printf '{"name":"%s","type":"%s","duration":%d,"exit_code":%d}' \
      "${STEP_NAMES[$i]}" "${STEP_TYPES[$i]}" "${STEP_DURATIONS[$i]}" "${STEP_EXITS[$i]}")"
  done
  steps_json+="]"

  # Instance ID from master key
  local instance_id=""
  if [ -f "$SECRETS_DIR/master.key" ]; then
    instance_id=$(sha256sum "$SECRETS_DIR/master.key" | cut -c1-16)
  fi

  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

  cat > "$DATA_DIR/install-report.json" <<REPORT_EOF
{
  "version": "1.0",
  "generated_at": "$(date -Iseconds)",
  "server": {
    "hostname": "$(hostname)",
    "ip": "$SERVER_IP",
    "os": "$OS_INFO",
    "arch": "$ARCH"
  },
  "instance_id": "$instance_id",
  "timing": {
    "total_seconds": $total,
    "net_seconds": $system_time,
    "user_input_seconds": $user_time
  },
  "preflight": {
    "passed": $pass_count,
    "warnings": $warn_count,
    "failed": $fail_count
  },
  "steps": $steps_json
}
REPORT_EOF

  chmod 644 "$DATA_DIR/install-report.json"
  REPORT_GENERATED=true
  diag "=== Report: $DATA_DIR/install-report.json ==="
  diag "Total: ${total}s | Net: ${system_time}s | Input: ${user_time}s"
}

# Trap to ensure report is written even on unexpected exit
cleanup() {
  if [ -n "$DIAG_LOG" ] && [ "$INSTALL_START_TS" -gt 0 ] && ! $REPORT_GENERATED; then
    diag "Script terminated unexpectedly (generating report)"
    generate_report 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Parse arguments ---
DO_INSTALL=false
TRIAL_MODE=false
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=true ;;
    --trial)   TRIAL_MODE=true ;;
  esac
done

# =============================================================================
# Preflight Checks
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}=== SerahrChat Preflight Check ===${NC}"
echo -e "    Prüfe Server-Voraussetzungen..."
echo ""

# --- 1. Root check ---
if [ "$(id -u)" -ne 0 ]; then
  fail "Script muss als root laufen (sudo)"
  echo ""
  echo -e "${RED}Bitte erneut mit sudo starten: sudo bash $0${NC}"
  exit 1
fi
ok "Root-Rechte"

# --- 2. OS / Architecture ---
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ] || [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  ok "Architektur: $ARCH"
else
  fail "Architektur: $ARCH (benötigt: x86_64/amd64 oder aarch64/arm64)"
fi

OS_INFO="unbekannt"
if [ -f /etc/os-release ]; then
  OS_INFO=$(. /etc/os-release && echo "$PRETTY_NAME")
fi
KERNEL=$(uname -r)
ok "Betriebssystem: $OS_INFO (Kernel $KERNEL)"

# --- 3. Docker ---
if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
  DOCKER_MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)
  if [ "$DOCKER_MAJOR" -ge "$MIN_DOCKER_MAJOR" ]; then
    ok "Docker: v$DOCKER_VERSION"
  else
    fail "Docker: v$DOCKER_VERSION (benötigt: >= $MIN_DOCKER_MAJOR.x)"
  fi
else
  warn "Docker nicht installiert (wird bei Installation automatisch installiert)"
fi

# --- 4. Docker Compose ---
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unbekannt")
  ok "Docker Compose: v$COMPOSE_VERSION"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unbekannt")
  warn "Docker Compose (Legacy): v$COMPOSE_VERSION - empfohlen: docker compose v2"
else
  if command -v docker &>/dev/null; then
    fail "Docker Compose nicht gefunden"
  else
    warn "Docker Compose nicht gefunden (wird mit Docker installiert)"
  fi
fi

# --- 5. RAM ---
TOTAL_RAM_MB=0
if [ -f /proc/meminfo ]; then
  TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
  if [ "$TOTAL_RAM_MB" -ge "$MIN_RAM_MB" ]; then
    ok "RAM: ${TOTAL_RAM_MB} MB (min. ${MIN_RAM_MB} MB)"
  else
    fail "RAM: ${TOTAL_RAM_MB} MB (benötigt: min. ${MIN_RAM_MB} MB)"
  fi
else
  warn "RAM: konnte nicht ermittelt werden"
fi

# --- 6. Disk space ---
DISK_AVAIL_KB=$(df -k / | tail -1 | awk '{print $4}')
DISK_AVAIL_MB=$((DISK_AVAIL_KB / 1024))
DISK_AVAIL_GB=$((DISK_AVAIL_MB / 1024))
if [ "$DISK_AVAIL_MB" -ge "$MIN_DISK_MB" ]; then
  ok "Festplatte: ${DISK_AVAIL_GB} GB frei (min. 1 GB)"
else
  fail "Festplatte: ${DISK_AVAIL_MB} MB frei (benötigt: min. ${MIN_DISK_MB} MB)"
fi

# --- 7. Ports ---
for port in "${REQUIRED_PORTS[@]}"; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
     netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
    PROC=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\("\K[^"]+' || echo "unbekannt")
    fail "Port $port belegt durch: $PROC"
  else
    ok "Port $port frei"
  fi
done

# --- 8. Outbound HTTPS ---
if command -v curl &>/dev/null; then
  if curl -sSo /dev/null --connect-timeout 5 "https://${OUTBOUND_TEST_HOST}" 2>/dev/null; then
    ok "Ausgehend HTTPS: ${OUTBOUND_TEST_HOST} erreichbar"
  else
    # Try with timeout command as fallback
    if timeout 5 bash -c "echo >/dev/tcp/${OUTBOUND_TEST_HOST}/${OUTBOUND_TEST_PORT}" 2>/dev/null; then
      ok "Ausgehend HTTPS: ${OUTBOUND_TEST_HOST} erreichbar (TCP)"
    else
      warn "Ausgehend HTTPS: ${OUTBOUND_TEST_HOST} nicht erreichbar (fuer OpenRouter benoetigt, nicht fuer Ollama)"
    fi
  fi
elif timeout 5 bash -c "echo >/dev/tcp/${OUTBOUND_TEST_HOST}/${OUTBOUND_TEST_PORT}" 2>/dev/null; then
  ok "Ausgehend HTTPS: ${OUTBOUND_TEST_HOST} erreichbar"
else
  warn "Ausgehend HTTPS: ${OUTBOUND_TEST_HOST} nicht erreichbar (fuer OpenRouter benoetigt, nicht fuer Ollama)"
fi

# --- 9. curl available ---
if command -v curl &>/dev/null; then
  ok "curl verfügbar"
else
  warn "curl nicht installiert (wird für Updates benötigt)"
fi

# --- 10. Container Registry reachable ---
if command -v curl &>/dev/null; then
  if curl -fsSL --connect-timeout 5 "https://ghcr.io" -o /dev/null 2>/dev/null; then
    ok "Container Registry (ghcr.io) erreichbar"
  else
    warn "Container Registry (ghcr.io) nicht erreichbar"
  fi
fi

# --- 11. Existing installation check ---
if [ -d "$INSTALL_DIR" ]; then
  warn "Bestehende Installation gefunden in $INSTALL_DIR"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}--- Ergebnis ---${NC}"
echo -e "  Bestanden: ${GREEN}${pass_count}${NC}  |  Warnungen: ${YELLOW}${warn_count}${NC}  |  Fehlgeschlagen: ${RED}${fail_count}${NC}"
echo ""

if [ "$fail_count" -gt 0 ]; then
  echo -e "${RED}${BOLD}Server erfüllt NICHT alle Voraussetzungen.${NC}"
  echo -e "Bitte beheben Sie die oben markierten Probleme und führen Sie den Check erneut aus."
  echo ""
  exit 1
fi

if [ "$warn_count" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}Server grundsätzlich geeignet (Warnungen beachten).${NC}"
else
  echo -e "${GREEN}${BOLD}Server erfüllt alle Voraussetzungen!${NC}"
fi

# =============================================================================
# Installation offer
# =============================================================================
echo ""

if [ "$DO_INSTALL" = true ]; then
  # --install flag was passed, skip the question
  do_install="j"
elif [ ! -t 0 ]; then
  # Piped via curl | bash — no interactive input available, auto-install
  echo -e "${CYAN}${BOLD}--- SerahrChat Installation ---${NC}"
  echo ""
  echo "  SerahrChat ist eine KI-gestützte FAQ-Appliance für Ihre Website."
  echo "  Nach der Installation läuft das System 7 Tage kostenlos als Testversion."
  echo ""
  TRIAL_MODE=true
  do_install="j"
else
  echo -e "${CYAN}${BOLD}--- SerahrChat Installation ---${NC}"
  echo ""
  echo "  SerahrChat ist eine KI-gestützte FAQ-Appliance für Ihre Website."
  echo "  Nach der Installation läuft das System 7 Tage kostenlos als Testversion."
  echo ""
  echo "  Den benötigten Lizenzschlüssel für den Betrieb nach der Testzeit"
  echo "  können Sie in der Installation selbst erwerben."
  echo ""
  read -p "  Möchten Sie SerahrChat jetzt installieren? (j/N) " do_install
fi

if [ "$do_install" != "j" ] && [ "$do_install" != "J" ]; then
  echo ""
  echo "Installation abgebrochen."
  echo "Sie können die Installation jederzeit starten mit:"
  echo "  sudo bash preflight.sh --install --trial"
  echo ""
  exit 0
fi

# =============================================================================
# Run installation
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}=== SerahrChat Installation ===${NC}"
echo ""

# Initialize logging
init_logging
diag "Installation started (DO_INSTALL=$DO_INSTALL, TRIAL_MODE=$TRIAL_MODE)"

# --- 1/8: Install Docker if needed ---
step_start "docker_install"
if ! command -v docker &>/dev/null; then
  echo "[1/8] Installiere Docker..."
  curl -fsSL https://get.docker.com 2>>"$DIAG_LOG" | sh >>"$DIAG_LOG" 2>&1
  systemctl enable docker >>"$DIAG_LOG" 2>&1
  systemctl start docker >>"$DIAG_LOG" 2>&1
  diag "Docker installed: $(docker --version 2>/dev/null)"
else
  echo "[1/8] Docker bereits installiert."
  diag "Docker already present: $(docker --version 2>/dev/null)"
fi
step_end 0

# --- 2/8: Create directories ---
step_start "create_directories"
echo "[2/8] Erstelle Verzeichnisse..."
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$SECRETS_DIR" \
         "$INSTALL_DIR/docker" "$INSTALL_DIR/scripts" \
         "$INSTALL_DIR/logs" "$INSTALL_DIR/backups"
chmod 700 "$SECRETS_DIR"
diag "Directories created"
step_end 0

# --- 3/8: Generate master key ---
step_start "master_key"
if [ ! -f "$SECRETS_DIR/master.key" ]; then
  echo "[3/8] Generiere Master Key..."
  openssl rand -base64 32 > "$SECRETS_DIR/master.key"
  chown 1000:1000 "$SECRETS_DIR/master.key"
  chmod 600 "$SECRETS_DIR/master.key"
  diag "Master key generated"
else
  echo "[3/8] Master Key existiert bereits."
  diag "Master key already exists"
fi
INSTANCE_ID=$(sha256sum "$SECRETS_DIR/master.key" | cut -c1-16)
diag "Instance ID: $INSTANCE_ID"
step_end 0

# --- 4/8: Pull Docker image + extract config ---
step_start "pull_image"
echo "[4/8] Lade SerahrChat Docker Image..."
# Fetch read-only GHCR credentials from licence server
GHCR_CREDS=$(curl -fsSL --connect-timeout 10 "$INSTALL_TOKEN_URL" 2>>"$DIAG_LOG") || {
  echo -e "  ${RED}[FAIL] Konnte Zugangsdaten nicht abrufen.${NC}"
  echo "  Bitte prüfen Sie die Internetverbindung und versuchen Sie es erneut."
  diag "Failed to fetch install token from $INSTALL_TOKEN_URL"
  step_end 1
  exit 1
}
GHCR_USER=$(echo "$GHCR_CREDS" | grep -o '"user":"[^"]*"' | cut -d'"' -f4)
GHCR_TOKEN=$(echo "$GHCR_CREDS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >>"$DIAG_LOG" 2>&1
diag "GHCR login completed"
docker pull "${DOCKER_IMAGE}:latest" >>"$DIAG_LOG" 2>&1
diag "Image pulled: $(docker inspect --format='{{.Id}}' "${DOCKER_IMAGE}:latest" 2>/dev/null | cut -c1-20)"

echo "       Extrahiere Konfigurationsdateien..."
docker run --rm --user 0 \
  -v "$INSTALL_DIR:/install" \
  "${DOCKER_IMAGE}:latest" \
  sh -c "cp -r /app/deploy-config/docker/* /install/docker/ && \
         cp -r /app/deploy-config/scripts/* /install/scripts/ && \
         chmod +x /install/scripts/*.sh"
diag "Config files extracted to $INSTALL_DIR"
diag "Docker dir: $(ls -la "$INSTALL_DIR/docker/" 2>/dev/null)"
step_end 0

# --- 5/8: Create .env (includes license key input) ---
echo "[5/8] Erstelle Konfiguration..."

# License key handling — track user input time separately
LICENSE_KEY_VALUE=""
if [ "$TRIAL_MODE" = true ]; then
  echo "       Testmodus: 7 Tage kostenlos, kein Lizenzschlüssel nötig."
  diag "License: trial mode"
else
  if [ -n "${LICENSE_KEY:-}" ]; then
    LICENSE_KEY_VALUE="$LICENSE_KEY"
    echo "       Lizenzschlüssel aus Umgebungsvariable übernommen."
    diag "License: from env var"
  else
    step_start "license_input" "user_input"
    echo ""
    echo "  Haben Sie bereits einen Lizenzschlüssel?"
    echo "  (Ohne Schlüssel startet eine 7-Tage-Testversion)"
    echo ""
    read -p "  Lizenzschlüssel eingeben (oder Enter für Testversion): " LICENSE_KEY_VALUE
    step_end 0
    if [ -z "$LICENSE_KEY_VALUE" ]; then
      echo "       Testmodus: 7 Tage kostenlos."
      diag "License: user chose trial"
    else
      diag "License: key provided (${LICENSE_KEY_VALUE:0:8}...)"
    fi
  fi
fi

step_start "create_config"
# Generate Watchtower API token for auto-updates
WATCHTOWER_TOKEN=$(openssl rand -hex 24)

cat > "$INSTALL_DIR/.env" <<EOF
MASTER_KEY_HOST_PATH=$SECRETS_DIR/master.key
LICENSE_KEY=$LICENSE_KEY_VALUE
LISTEN_PORT=80
TLS_PORT=443
WATCHTOWER_TOKEN=$WATCHTOWER_TOKEN
SERAHRCHAT_VERSION=latest
INSTALL_DIR=$INSTALL_DIR
EOF
chmod 600 "$INSTALL_DIR/.env"
diag ".env created"
step_end 0

# --- 6/8: Set up daily backup cron ---
step_start "setup_backup"
echo "[6/8] Richte tägliches Backup ein..."
BACKUP_CRON="0 2 * * * $INSTALL_DIR/scripts/backup.sh >> /var/log/serahrchat-backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "serahrchat.*backup" || true; echo "$BACKUP_CRON") | crontab -
diag "Backup cron installed"
step_end 0

# --- 7/8: Start services ---
step_start "start_services"
echo "[7/8] Starte SerahrChat..."
docker compose -f "$INSTALL_DIR/docker/docker-compose.yml" --env-file "$INSTALL_DIR/.env" up -d >>"$DIAG_LOG" 2>&1
diag "Docker compose up completed"

# Log Docker image info
diag "Docker images:"
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' 2>/dev/null | head -20 >> "$DIAG_LOG" 2>/dev/null || true
diag "Docker containers:"
docker compose -f "$INSTALL_DIR/docker/docker-compose.yml" --env-file "$INSTALL_DIR/.env" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' >> "$DIAG_LOG" 2>/dev/null || true
step_end 0

# --- 8/8: Health check ---
step_start "health_check"
echo "[8/8] Prüfe Systemstatus..."
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")
HEALTH_OK=false
echo -n "       Warte auf Systemstart"
for i in $(seq 1 45); do
  if curl -fsSL --connect-timeout 2 "http://127.0.0.1/health" 2>/dev/null | grep -q 'ok'; then
    HEALTH_OK=true
    diag "Health check passed (attempt $i)"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""
if $HEALTH_OK; then
  ok "System bereit"
else
  fail "System antwortet nicht nach 90 Sekunden"
  diag "Health check: no response after 90s"
  echo ""
  echo -e "  ${RED}Fehlerdiagnose:${NC}"
  echo "  docker compose -f $INSTALL_DIR/docker/docker-compose.yml --env-file $INSTALL_DIR/.env logs"
  # Capture container logs for diagnostics
  diag "=== Docker logs (last 50 lines) ==="
  docker compose -f "$INSTALL_DIR/docker/docker-compose.yml" --env-file "$INSTALL_DIR/.env" logs --tail=50 >> "$DIAG_LOG" 2>/dev/null || true
fi
step_end 0

# =============================================================================
# Generate install report + finish
# =============================================================================
generate_report

echo ""
echo -e "${GREEN}${BOLD}=== Installation abgeschlossen ===${NC}"
echo ""

echo "  Admin UI:  http://${SERVER_IP}/admin/ui/"
echo "  Health:    http://${SERVER_IP}/health"
echo ""

echo -e "  ${YELLOW}Öffnen Sie die Admin-Oberfläche im Browser, um Ihr Admin-Konto einzurichten.${NC}"
echo ""

if [ -z "$LICENSE_KEY_VALUE" ]; then
  echo -e "  ${YELLOW}${BOLD}TESTVERSION: 7 Tage kostenlos${NC}"
  echo "  Den Lizenzschlüssel können Sie direkt in der Admin-Oberfläche erwerben."
  echo ""
fi

# Show timing summary
if [ "$INSTALL_START_TS" -gt 0 ]; then
  END_TS=$(date +%s)
  TOTAL_SECS=$((END_TS - INSTALL_START_TS))
  TOTAL_MINS=$((TOTAL_SECS / 60))
  TOTAL_REMAINING=$((TOTAL_SECS % 60))
  echo -e "  ${CYAN}Installationsdauer: ${TOTAL_MINS}m ${TOTAL_REMAINING}s${NC}"
  echo ""
fi

echo "  Für TLS/HTTPS-Einrichtung und weitere Konfiguration:"
echo "  https://docs.serahr.de/serahrchat/installation"
echo ""
