#!/bin/bash
# SELFSTEAL Setup Script
# VLESS Reality (self-steal) за Caddy с нативным automatic HTTPS (без отдельного acme.sh)
# Version: 2.5
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}▶ $1${NC}"; }

SCRIPT_VERSION="2.5"

# ─── Баннер ───────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}"
cat << 'EOF'
   ██████╗███████╗██╗     ███████╗    ███████╗████████╗███████╗ █████╗ ██╗
  ██╔════╝██╔════╝██║     ██╔════╝    ██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║
  ╚█████╗ █████╗  ██║     █████╗      ███████╗   ██║   █████╗  ███████║██║
   ╚═══██╗██╔══╝  ██║     ██╔══╝      ╚════██║   ██║   ██╔══╝  ██╔══██║██║
  ██████╔╝███████╗███████╗██║         ███████║   ██║   ███████╗██║  ██║███████╗
  ╚═════╝ ╚══════╝╚══════╝╚═╝         ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚══════╝
EOF
echo -e "${NC}"
echo -e "  ${GRAY}VLESS Reality + Self-steal за Caddy (native TLS)${NC}"
echo -e "  ${GRAY}Version: ${SCRIPT_VERSION}${NC}"
echo -e "  ${GRAY}────────────────────────────────────────${NC}"
echo ""

# ─── Проверка root ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Скрипт нужно запускать от root"

# ─── Зависимости ──────────────────────────────────────────────────────────────
step "Установка зависимостей"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq unzip dnsutils curl coreutils fail2ban >/dev/null 2>&1
info "unzip, dnsutils, curl, coreutils, fail2ban — готово"

# ─── Шаг 1: Основные параметры ────────────────────────────────────────────────
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

# ─── Шаг 2: Docker-compose из панели ──────────────────────────────────────────
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

[[ -z "$NODE_PORT" ]]  && error "Не удалось найти NODE_PORT в docker-compose"
[[ -z "$SECRET_KEY" ]] && error "Не удалось найти SECRET_KEY в docker-compose"

info "NODE_PORT: $NODE_PORT"
info "SECRET_KEY: ${SECRET_KEY:0:20}..."

# ─── Проверка DNS ─────────────────────────────────────────────────────────────
step "Проверка DNS"
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+\.\d+$' | tail -1)

if [[ -z "$SERVER_IP" ]]; then
    warn "Не удалось определить внешний IP сервера, пропускаю проверку DNS"
elif [[ -z "$DOMAIN_IP" ]]; then
    warn "Домен $DOMAIN не резолвится — проверьте A-запись"
    read -rp "  Продолжить всё равно? [y/N]: " DNS_CONFIRM
    [[ "$DNS_CONFIRM" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    warn "Домен $DOMAIN → $DOMAIN_IP, IP сервера → $SERVER_IP"
    warn "A-запись указывает не на этот сервер — Let's Encrypt может отказать в выпуске"
    read -rp "  Продолжить всё равно? [y/N]: " DNS_CONFIRM
    [[ "$DNS_CONFIRM" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
else
    info "DNS OK: $DOMAIN → $DOMAIN_IP"
fi

# ─── Подтверждение ────────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Параметры установки:${NC}"
echo -e "  ${GRAY}Домен:     ${NC}$DOMAIN"
echo -e "  ${GRAY}Email:     ${NC}${EMAIL:-"— пропущен"}"
echo -e "  ${GRAY}Panel IP:  ${NC}${PANEL_IP:-"— пропущен"}"
echo -e "  ${GRAY}NODE_PORT: ${NC}$NODE_PORT"
echo ""
read -rp "  Начать установку? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }

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

# ─── Папки ────────────────────────────────────────────────────────────────────
step "Создание папок"
mkdir -p /opt/html /opt/selfsteal /opt/remnanode
info "Готово"

# ─── Заглушка: случайный HTML-шаблон из GitHub-репозитория ───────────────────
step "Загрузка сайта-заглушки"

STUBS_USER="Gorta"
STUBS_REPO="reality-stubs"
STUBS_BRANCH="main"
STUBS_BASE="https://raw.githubusercontent.com/${STUBS_USER}/${STUBS_REPO}/${STUBS_BRANCH}"

SITE_OK=0

if STUBS_LIST=$(curl -fsSL --max-time 10 "${STUBS_BASE}/list.txt" 2>/dev/null) && [[ -n "$STUBS_LIST" ]]; then
    STUBS_LIST=$(echo "$STUBS_LIST" | tr -d '\r' | grep -vE '^\s*(#|$)' || true)

    if [[ -n "$STUBS_LIST" ]]; then
        # Все шаблоны в репозитории — одиночные *.html файлы в sites/.
        # Некоторые строки в list.txt идут без расширения — дописываем его.
        # Если конкретная запись недоступна, пробуем ещё несколько случайных.
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

# fallback — встроенная заглушка
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

# ─── Конфиги ──────────────────────────────────────────────────────────────────
step "Генерация конфигов"

# Caddy сам получает и продлевает сертификат (native automatic HTTPS).
# Caddy не слушает 443 — этот порт целиком принадлежит Xray (Reality),
# который форвардит весь неопознанный трафик (не прошедший Reality-аутентификацию)
# на 127.0.0.1:9443, где его встречает сайт-заглушка.
#
# listener_wrappers привязаны строго к адресу 127.0.0.1:9443: без явного
# адреса эти настройки применились бы ко всем серверам Caddy, включая :80,
# и сломали бы обычный (plain HTTP) ACME-челлендж на этом порту.
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

cat > /opt/selfsteal/docker-compose.yml <<'EOF'
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

cat > /opt/remnanode/docker-compose.yml <<EOF
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
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
chmod 600 /opt/remnanode/docker-compose.yml
info "Конфиги созданы"

# ─── Фаервол ──────────────────────────────────────────────────────────────────
step "Настройка фаервола"
if command -v ufw &>/dev/null; then
    ufw --force reset          >/dev/null 2>&1
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw limit ssh              >/dev/null 2>&1
    ufw allow 80/tcp           >/dev/null 2>&1
    ufw allow 443/tcp          >/dev/null 2>&1

    if [[ -n "$PANEL_IP" ]]; then
        ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null 2>&1
    else
        ufw allow "$NODE_PORT"/tcp >/dev/null 2>&1
        warn "IP панели не указан — порт ${NODE_PORT} открыт всем (рекомендуется ограничить по IP панели, когда он известен)"
    fi

    ufw --force enable         >/dev/null 2>&1
    info "ufw настроен"
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
port    = ssh
backend = systemd
bantime  = 3600
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
docker compose up -d >/dev/null 2>&1
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
    warn "Нет подтверждения выпуска сертификата за ${TIMEOUT}s"
    warn "Проверьте вручную: docker logs caddy-selfsteal | grep -i cert"
fi

if docker ps --filter name=caddy-selfsteal --filter status=running -q | grep -q .; then
    info "Caddy в статусе running"
else
    error "Caddy не запустился. Проверьте: docker logs caddy-selfsteal"
fi

# ─── Запуск ноды ──────────────────────────────────────────────────────────────
step "Запуск Remnawave Node"
cd /opt/remnanode
docker compose up -d >/dev/null 2>&1
sleep 5

if docker ps --filter name=remnanode --filter status=running -q | grep -q .; then
    info "Remnanode запущен"
else
    error "Remnanode не запустился. Проверьте: docker logs remnanode"
fi

# ─── Финал ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Установка завершена${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}  Контейнеры:${NC}"
docker ps --format "    {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E 'caddy|remnanode' || true
echo ""
echo -e "${CYAN}  Проверка портов (443/tcp должен держать Xray, 9443 — Caddy только на loopback):${NC}"
ss -tlnp 2>/dev/null | grep -E ':443|:9443|:80 ' | awk '{print "    " $0}'
echo ""
echo -e "${CYAN}  Сертификат на decoy-порту 9443 (должен быть выдан Let's Encrypt):${NC}"
echo | openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -issuer -subject 2>/dev/null \
    | awk '{print "    " $0}' \
    || warn "Не удалось прочитать сертификат, проверьте вручную"
echo ""
echo -e "${CYAN}  Проверка сайта-заглушки по внешнему пути (через Xray → 9443):${NC}"
curl -skI "https://$DOMAIN" 2>/dev/null | grep -E 'HTTP|Content-Type' | awk '{print "    " $0}' || \
    warn "Сайт ещё не отвечает — DNS может ещё не распространиться"
echo ""
echo -e "${CYAN}  Полезные команды:${NC}"
echo -e "  ${GRAY}Логи Caddy:         ${NC}docker logs -f caddy-selfsteal"
echo -e "  ${GRAY}Логи ноды:          ${NC}docker logs -f remnanode"
echo -e "  ${GRAY}Статус BBR:         ${NC}sysctl net.ipv4.tcp_congestion_control"
echo -e "  ${GRAY}Срок сертификата:   ${NC}echo | openssl s_client -connect 127.0.0.1:9443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -dates"
echo ""
