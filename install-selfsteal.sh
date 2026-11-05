#!/bin/bash
# SELFSTEAL Setup Script
# VLESS Reality (self-steal) + Hysteria2 за Caddy с нативным automatic HTTPS (без отдельного acme.sh)
# Version: 2.6

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}▶ $1${NC}"; }

SCRIPT_VERSION="2.6"
STATE_FILE="/opt/selfsteal/.install-state"

# ─── Проверка root ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Скрипт нужно запускать от root"

# ─── Определение режима: fresh / upgrade / refresh ───────────────────────────
# fresh   — состояния нет, обычная интерактивная установка с нуля
# upgrade — состояние есть, версия скрипта отличается от установленной:
#           переиспользуем сохранённые ответы, полностью перегенерируем
#           конфиги/compose/ufw без единого вопроса
# refresh — состояние есть, версия совпадает: просто обновляем образы
mkdir -p /opt/html /opt/selfsteal /opt/remnanode

MODE="fresh"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  if [[ "$INSTALLED_VERSION" == "$SCRIPT_VERSION" ]]; then
    MODE="refresh"
  else
    MODE="upgrade"
  fi
fi

# ─── Баннер ───────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}"
cat << 'EOF'
 ██████╗███████╗██╗     ███████╗███████╗████████╗███████╗ █████╗ ██╗
██╔════╝██╔════╝██║     ██╔════╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║
╚█████╗ █████╗  ██║     █████╗  ███████╗   ██║   █████╗  ███████║██║
 ╚═══██╗██╔══╝  ██║     ██╔══╝  ╚════██║   ██║   ██╔══╝  ██╔══██║██║
██████╔╝███████╗███████╗██║     ███████║   ██║   ███████╗██║  ██║███████╗
╚═════╝ ╚══════╝╚══════╝╚═╝     ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚══════╝
EOF
echo -e "${NC}"
echo -e "   ${GRAY}VLESS Reality + Hysteria2 + Self-steal за Caddy (native TLS)${NC}"
echo -e "   ${GRAY}Version: ${SCRIPT_VERSION}   Режим: ${MODE}${NC}"
echo -e "   ${GRAY}────────────────────────────────────────${NC}"
echo ""

# ─── Зависимости ──────────────────────────────────────────────────────────────
step "Установка зависимостей"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq unzip dnsutils curl coreutils fail2ban >/dev/null 2>&1
info "unzip, dnsutils, curl, coreutils, fail2ban — готово"

# ─── Режим refresh: версия не менялась, просто обновляем образы ──────────────
if [[ "$MODE" == "refresh" ]]; then
  step "Версия не изменилась (${SCRIPT_VERSION}) — конфиги не трогаю, обновляю образы"

  if [[ -f /opt/selfsteal/docker-compose.yml ]]; then
    (cd /opt/selfsteal && docker compose pull -q && docker compose up -d --remove-orphans)
    info "Caddy обновлён"
  else
    warn "/opt/selfsteal/docker-compose.yml не найден — state-файл есть, а установки нет. Удалите ${STATE_FILE} и запустите заново"
    exit 1
  fi

  if [[ -f /opt/remnanode/docker-compose.yml ]]; then
    (cd /opt/remnanode && docker compose pull -q && docker compose up -d --remove-orphans)
    info "remnanode обновлён"
  fi

  echo ""
  echo -e "${CYAN} Контейнеры:${NC}"
  docker ps --format " {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E 'caddy|remnanode' || true
  echo ""
  exit 0
fi

# ─── Шаг 1: Основные параметры ────────────────────────────────────────────────
if [[ "$MODE" == "fresh" ]]; then
  step "Основные параметры"
  while true; do
    read -rp "  Домен ноды (например, node-01.example.com): " DOMAIN
    [[ -n "$DOMAIN" ]] && break
    echo -e "  ${RED}Домен не может быть пустым${NC}"
  done

  while true; do
    read -rp "  Email для Let's Encrypt (Enter — пропустить): " EMAIL
    [[ -z "$EMAIL" ]] && { warn "Email пропущен — ACME-аккаунт будет анонимным"; break; }
    [[ "$EMAIL" == *@* ]] && break
    echo -e "  ${RED}Некорректный email${NC}"
  done

  while true; do
    read -rp "  IP панели Remnawave, для фаервола (Enter — пропустить): " PANEL_IP
    [[ -z "$PANEL_IP" ]] && { warn "IP панели пропущен — порт ноды будет открыт всем без ограничения по IP"; break; }
    [[ "$PANEL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echo -e "  ${RED}Некорректный IPv4${NC}"
  done
else
  step "Основные параметры"
  info "Используются сохранённые значения (upgrade, без вопросов):"
  echo -e "  ${GRAY}Домен:${NC} $DOMAIN"
  echo -e "  ${GRAY}Email:${NC} ${EMAIL:-"— пропущен"}"
  echo -e "  ${GRAY}Panel IP:${NC} ${PANEL_IP:-"— пропущен"}"
fi

# ─── Шаг 2: Docker-compose из панели (только при fresh-установке) ────────────
if [[ "$MODE" == "fresh" ]]; then
  step "Docker-compose из панели Remnawave"
  echo ""
  echo -e "  ${YELLOW}Панель → Nodes → создать ноду → скопировать docker-compose.yml${NC}"
  echo -e "  ${YELLOW}Вставьте содержимое, затем на новой строке нажмите Ctrl+D:${NC}"
  echo ""
  # Читаем paste до явного EOF, а не до эвристики по содержимому строки —
  # устойчиво к любому формату и длине SECRET_KEY.
  COMPOSE_CONTENT=$(cat)
  NODE_PORT=$(echo "$COMPOSE_CONTENT" | grep 'NODE_PORT' | grep -oP '\d+' | head -1)
  SECRET_KEY=$(echo "$COMPOSE_CONTENT" | grep 'SECRET_KEY' | sed 's/.*SECRET_KEY=\s*"\?\([^"]*\)"\?.*/\1/' | head -1)
  [[ -z "$NODE_PORT" ]] && error "Не удалось найти NODE_PORT в docker-compose"
  [[ -z "$SECRET_KEY" ]] && error "Не удалось найти SECRET_KEY в docker-compose"
  info "NODE_PORT: $NODE_PORT"
  info "SECRET_KEY: ${SECRET_KEY:0:20}..."
else
  info "NODE_PORT/SECRET_KEY взяты из сохранённого состояния (NODE_PORT: $NODE_PORT)"
fi

# ─── Проверка DNS ─────────────────────────────────────────────────────────────
step "Проверка DNS"
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | tail -1)

if [[ -z "$SERVER_IP" ]]; then
  warn "Не удалось определить внешний IP сервера, пропускаю проверку DNS"
elif [[ -z "$DOMAIN_IP" ]]; then
  warn "Домен $DOMAIN не резолвится — проверьте A-запись"
  if [[ "$MODE" == "fresh" ]]; then
    read -rp "  Продолжить всё равно? [y/N]: " DNS_CONFIRM
    [[ "$DNS_CONFIRM" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
  else
    warn "Режим upgrade — продолжаю без подтверждения"
  fi
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
  warn "Домен $DOMAIN → $DOMAIN_IP, IP сервера → $SERVER_IP"
  warn "A-запись указывает не на этот сервер — Let's Encrypt может отказать в выпуске"
  if [[ "$MODE" == "fresh" ]]; then
    read -rp "  Продолжить всё равно? [y/N]: " DNS_CONFIRM
    [[ "$DNS_CONFIRM" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
  else
    warn "Режим upgrade — продолжаю без подтверждения"
  fi
else
  info "DNS OK: $DOMAIN → $DOMAIN_IP"
fi

# ─── Подтверждение (только fresh) ─────────────────────────────────────────────
if [[ "$MODE" == "fresh" ]]; then
  echo ""
  echo -e "  ${CYAN}Параметры установки:${NC}"
  echo -e "  ${GRAY}Домен:${NC} $DOMAIN"
  echo -e "  ${GRAY}Email:${NC} ${EMAIL:-"— пропущен"}"
  echo -e "  ${GRAY}Panel IP:${NC} ${PANEL_IP:-"— пропущен"}"
  echo -e "  ${GRAY}NODE_PORT:${NC} $NODE_PORT"
  echo ""
  read -rp "  Начать установку? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

# ─── Docker ───────────────────────────────────────────────────────────────────
step "Установка Docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "live-restore": true
}
EOF
  systemctl restart docker
  info "Docker установлен"
else
  info "Docker уже установлен: $(docker --version | cut -d' ' -f3)"
fi

# ─── Заглушка: случайный HTML-шаблон из GitHub-репозитория (только fresh) ────
if [[ "$MODE" == "fresh" ]]; then
  step "Загрузка сайта-заглушки"
  STUBS_USER="Gorta"
  STUBS_REPO="reality-stubs"
  STUBS_BRANCH="main"
  STUBS_BASE="https://raw.githubusercontent.com/${STUBS_USER}/${STUBS_REPO}/${STUBS_BRANCH}"
  SITE_OK=0

  if STUBS_LIST=$(curl -fsSL --max-time 10 "${STUBS_BASE}/list.txt" 2>/dev/null) && [[ -n "$STUBS_LIST" ]]; then
    STUBS_LIST=$(echo "$STUBS_LIST" | tr -d '\r' | grep -vE '^\s*(#|$)' || true)
    if [[ -n "$STUBS_LIST" ]]; then
      CANDIDATES=$(echo "$STUBS_LIST" | shuf | head -n 5)
      while IFS= read -r ENTRY; do
        [[ -z "$ENTRY" ]] && continue
        [[ "$ENTRY" == *.html ]] || ENTRY="${ENTRY}.html"
        if curl -fsSL --max-time 15 "${STUBS_BASE}/${ENTRY}" -o /tmp/stub.html 2>/dev/null \
           && [[ -s /tmp/stub.html ]] \
           && head -c 200 /tmp/stub.html | grep -qi '<!doctype\|<html'; then
          rm -rf /opt/html/*
          mv /tmp/stub.html /opt/html/index.html
          SITE_OK=1
          info "Шаблон установлен: ${ENTRY}"
          break
        else
          rm -f /tmp/stub.html
        fi
      done <<< "$CANDIDATES"
      [[ "$SITE_OK" -eq 0 ]] && warn "Не удалось скачать ни один шаблон из list.txt"
    else
      warn "list.txt пустой или содержит только комментарии"
    fi
  else
    warn "Не удалось получить list.txt из ${STUBS_BASE}"
  fi

  if [[ "$SITE_OK" -eq 0 ]]; then
    cat > /opt/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Welcome</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{display:flex;align-items:center;justify-content:center;min-height:100vh;
font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f8f9fa}
.wrap{text-align:center;color:#495057}
h1{font-size:2rem;font-weight:300;margin-bottom:.5rem}
p{color:#868e96;font-size:.95rem}
</style>
</head>
<body>
<div class="wrap"><h1>Welcome</h1><p>This site is under maintenance.</p></div>
</body>
</html>
EOF
    info "Использована встроенная заглушка"
  fi
else
  info "Шаг с decoy-сайтом пропущен (upgrade) — существующий /opt/html остаётся как есть"
fi

# ─── Конфиги: Caddyfile + caddy docker-compose ────────────────────────────────
step "Генерация конфигов Caddy"
# Caddy сам получает и продлевает сертификат (native automatic HTTPS).
# Caddy не слушает 443 — этот порт целиком принадлежит Xray (Reality на TCP,
# Hysteria2 на UDP), который форвардит весь неопознанный TCP-трафик (не прошедший
# Reality-аутентификацию) на 127.0.0.1:9443, где его встречает сайт-заглушка.
EMAIL_LINE=""
[[ -n "$EMAIL" ]] && EMAIL_LINE="    email ${EMAIL}"

cat > /opt/selfsteal/Caddyfile <<EOF
{
${EMAIL_LINE}
    servers 127.0.0.1:9443 {
        listener_wrappers {
            proxy_protocol {
                allow 127.0.0.1/32
            }
            tls
        }
    }
}

${DOMAIN}:9443 {
    bind 127.0.0.1
    tls {
        protocols tls1.2 tls1.3
    }
    root * /var/www/html
    try_files {path} /index.html
    file_server
    header {
        -Server
        -X-Powered-By
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }
}

:80 {
    bind 0.0.0.0
    redir https://{host}{uri} permanent
}
EOF

# name: selfsteal фиксирует имя docker compose проекта (и, значит, имя volume
# caddy_data → selfsteal_caddy_data), чтобы remnanode мог находить сертификат
# по предсказуемому имени volume вне зависимости от того, из какой директории
# когда-либо запускался docker compose.
cat > /opt/selfsteal/docker-compose.yml <<'EOF'
name: selfsteal
services:
  caddy:
    image: caddy:latest
    container_name: caddy-selfsteal
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - /opt/html:/var/www/html:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
EOF
info "Caddyfile и docker-compose для Caddy готовы"

# ─── Фаервол ──────────────────────────────────────────────────────────────────
step "Настройка фаервола"
if command -v ufw &>/dev/null; then
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw limit ssh >/dev/null 2>&1
  ufw allow 80/tcp >/dev/null 2>&1
  ufw allow 443/tcp >/dev/null 2>&1
  ufw allow 443/udp >/dev/null 2>&1   # Hysteria2 (QUIC)
  if [[ -n "$PANEL_IP" ]]; then
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null 2>&1
  else
    ufw allow "$NODE_PORT"/tcp >/dev/null 2>&1
    warn "IP панели не указан — порт ${NODE_PORT} открыт всем (рекомендуется ограничить по IP панели, когда он известен)"
  fi
  ufw --force enable >/dev/null 2>&1
  info "ufw настроен (включая 443/udp для Hysteria2)"
else
  warn "ufw не найден, пропускаю"
fi

# ─── Swap ─────────────────────────────────────────────────────────────────────
step "Настройка swap"
if swapon --show | grep -q .; then
  info "Swap уже настроен, пропускаю"
elif [[ -f /swapfile ]]; then
  info "/swapfile уже существует, пропускаю создание"
else
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  info "Добавлено 2 ГБ swap (/swapfile)"
fi

# ─── fail2ban ─────────────────────────────────────────────────────────────────
step "Настройка fail2ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
bantime = 3600
findtime = 600
maxretry = 5
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1
info "fail2ban настроен (sshd: 5 попыток / 10 мин → бан на 1 час)"

# ─── BBR ──────────────────────────────────────────────────────────────────────
step "Оптимизация сети (BBR)"
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
EOF
sysctl -p /etc/sysctl.d/99-vpn.conf >/dev/null 2>&1
info "BBR включён (+ tcp_rmem/wmem/fastopen)"

# ─── Запуск Caddy (получает сертификат через ACME HTTP-01 на :80) ────────────
step "Запуск Caddy"
cd /opt/selfsteal
docker compose pull -q >/dev/null 2>&1 || true
docker compose up -d --remove-orphans >/dev/null 2>&1
info "Caddy запущен, ожидаю выпуск сертификата..."

TIMEOUT=90; ELAPSED=0; CERT_OK=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  if docker compose logs 2>/dev/null | grep -q "certificate obtained successfully"; then
    CERT_OK=1
    break
  fi
  sleep 3; ELAPSED=$((ELAPSED + 3))
  echo -ne "  ${GRAY}${ELAPSED}s...${NC}\r"
done
echo ""

if [[ "$CERT_OK" -eq 1 ]]; then
  info "Сертификат получен"
else
  warn "Нет подтверждения выпуска сертификата за ${TIMEOUT}s (возможно, он уже был выпущен ранее и Caddy его просто переиспользовал — это нормально при upgrade)"
fi

if docker ps --filter name=caddy-selfsteal --filter status=running -q | grep -q .; then
  info "Caddy в статусе running"
else
  error "Caddy не запустился. Проверьте: docker logs caddy-selfsteal"
fi

# ─── Подключение сертификата Caddy к remnanode (для Hysteria2) ───────────────
step "Подключение сертификата к remnanode (Hysteria2)"

CADDY_DATA_MOUNT=$(docker volume inspect -f '{{ .Mountpoint }}' selfsteal_caddy_data 2>/dev/null || true)
CERT_CRT=""
CERT_KEY=""

if [[ -z "$CADDY_DATA_MOUNT" ]]; then
  warn "Volume selfsteal_caddy_data не найден — Hysteria2 не получит сертификат, пока это не будет поправлено вручную"
else
  # Ищем папку с именем ровно $DOMAIN под caddy/certificates/<acme-directory>/ —
  # не завязываемся на конкретное имя ACME-директории (production/staging/иное).
  CERT_DIR=$(find "$CADDY_DATA_MOUNT/caddy/certificates" -maxdepth 2 -type d -iname "$DOMAIN" 2>/dev/null | head -1)
  if [[ -z "$CERT_DIR" || ! -f "$CERT_DIR/$DOMAIN.crt" || ! -f "$CERT_DIR/$DOMAIN.key" ]]; then
    warn "Файлы сертификата для $DOMAIN не найдены в $CADDY_DATA_MOUNT/caddy/certificates — Hysteria2-инбаунд не заработает, пока сертификат не появится (cert-watch.timer подхватит его сам при следующей проверке, но первый докрут может понадобиться вручную: перезапустите этот скрипт после того, как сертификат точно будет выпущен)"
  else
    CERT_CRT="$CERT_DIR/$DOMAIN.crt"
    CERT_KEY="$CERT_DIR/$DOMAIN.key"
    info "Сертификат найден: $CERT_CRT"
  fi
fi

# ─── docker-compose для remnanode (с учётом найденного сертификата) ──────────
step "Генерация docker-compose для remnanode"
{
  cat <<EOF
name: remnanode
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    cgroup: host
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
EOF
  if [[ -n "$CERT_CRT" && -n "$CERT_KEY" ]]; then
    cat <<EOF
    volumes:
      - ${CERT_CRT}:/var/lib/remnawave/configs/xray/ssl/fullchain.pem:ro
      - ${CERT_KEY}:/var/lib/remnawave/configs/xray/ssl/privkey.key:ro
EOF
  fi
  cat <<EOF
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
} > /opt/remnanode/docker-compose.yml
chmod 600 /opt/remnanode/docker-compose.yml
info "docker-compose.yml для remnanode готов"

# ─── Watcher: рестарт remnanode при обновлении сертификата Caddy ─────────────
step "Установка watcher'а обновления сертификата"

cat > /opt/remnanode/cert-watch.sh <<'WATCHEOF'
#!/bin/bash
# Следит за сертификатом, смонтированным в remnanode, и рестартит контейнер,
# когда Caddy обновляет его (ACME-ренувал раз в ~60 дней). Путь к сертификату
# берётся прямо из текущего docker-compose.yml — отдельного источника правды нет.
set -e

STATE_FILE="/opt/remnanode/.cert-watch-state"
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

CERT_CRT=$(grep -oP '(?<=- )\S+(?=:/var/lib/remnawave/configs/xray/ssl/fullchain\.pem)' "$COMPOSE_FILE" 2>/dev/null | head -1 || true)
[[ -z "$CERT_CRT" || ! -f "$CERT_CRT" ]] && exit 0

CURRENT_HASH=$(sha256sum "$CERT_CRT" | awk '{print $1}')
LAST_HASH=""
[[ -f "$STATE_FILE" ]] && LAST_HASH=$(cat "$STATE_FILE")

if [[ "$CURRENT_HASH" != "$LAST_HASH" ]]; then
  echo "$(date -Is) сертификат изменился ($CERT_CRT), рестартую remnanode" >> /var/log/cert-watch.log
  docker restart remnanode >/dev/null 2>&1 || true
  echo "$CURRENT_HASH" > "$STATE_FILE"
fi
WATCHEOF
chmod +x /opt/remnanode/cert-watch.sh

cat > /etc/systemd/system/cert-watch.service <<'EOF'
[Unit]
Description=Проверка обновления сертификата Caddy для remnanode (Hysteria2)

[Service]
Type=oneshot
ExecStart=/opt/remnanode/cert-watch.sh
EOF

cat > /etc/systemd/system/cert-watch.timer <<'EOF'
[Unit]
Description=Запуск cert-watch.sh раз в сутки

[Timer]
OnCalendar=daily
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cert-watch.timer >/dev/null 2>&1
info "cert-watch.timer установлен (проверка раз в сутки, рестарт remnanode только при реальном изменении файла)"

# ─── Запуск ноды ──────────────────────────────────────────────────────────────
step "Запуск Remnawave Node"
cd /opt/remnanode
docker compose pull -q >/dev/null 2>&1 || true
docker compose up -d --remove-orphans >/dev/null 2>&1
sleep 5

if docker ps --filter name=remnanode --filter status=running -q | grep -q .; then
  info "Remnanode запущен"
else
  error "Remnanode не запустился. Проверьте: docker logs remnanode"
fi

# ─── Сохранение состояния (для следующего upgrade/refresh запуска) ───────────
step "Сохранение состояния"
cat > "$STATE_FILE" <<EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
PANEL_IP="$PANEL_IP"
NODE_PORT="$NODE_PORT"
SECRET_KEY="$SECRET_KEY"
INSTALLED_VERSION="$SCRIPT_VERSION"
EOF
chmod 600 "$STATE_FILE"
info "Состояние сохранено — повторный запуск скрипта обновит без вопросов"

# ─── Финал ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Установка завершена (${MODE})${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}  Контейнеры:${NC}"
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E 'caddy|remnanode' || true
echo ""
echo -e "${CYAN}  Проверка портов (443/tcp — Xray, 443/udp — Hysteria2, 9443 — Caddy только на loopback):${NC}"
ss -tlnp 2>/dev/null | grep -E ':443|:9443|:80 ' | awk '{print "  " $0}'
ss -ulnp 2>/dev/null | grep -E ':443' | awk '{print "  " $0}'
echo ""
echo -e "${CYAN}  Сертификат на decoy-порту 9443 (должен быть выдан Let's Encrypt):${NC}"
echo | openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -issuer -subject 2>/dev/null \
  | awk '{print "  " $0}' \
  || warn "Не удалось прочитать сертификат, проверьте вручную"
echo ""
echo -e "${CYAN}  Проверка сайта-заглушки по внешнему пути (через Xray → 9443):${NC}"
curl -skI "https://$DOMAIN" 2>/dev/null | grep -E 'HTTP|Content-Type' | awk '{print "  " $0}' || \
  warn "Сайт ещё не отвечает — DNS может ещё не распространиться"
echo ""
if [[ -z "$CERT_CRT" ]]; then
  warn "Сертификат для Hysteria2 не был смонтирован в remnanode — проверьте шаг выше и перезапустите скрипт после выпуска сертификата"
fi
echo -e "${CYAN}  Полезные команды:${NC}"
echo -e "  ${GRAY}Логи Caddy:        ${NC}docker logs -f caddy-selfsteal"
echo -e "  ${GRAY}Логи ноды:         ${NC}docker logs -f remnanode"
echo -e "  ${GRAY}Статус BBR:        ${NC}sysctl net.ipv4.tcp_congestion_control"
echo -e "  ${GRAY}Срок сертификата:  ${NC}echo | openssl s_client -connect 127.0.0.1:9443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -dates"
echo -e "  ${GRAY}Watcher вручную:   ${NC}/opt/remnanode/cert-watch.sh && systemctl status cert-watch.timer"
echo ""
