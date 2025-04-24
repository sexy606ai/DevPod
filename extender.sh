#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
# DevPod – Raspberry-Pi Edition (personalized)
# Version : 1.3.1-personal  (2024-06-07)
# Author  : sexy69ai <sexy69ai@outlook.com>
# Licence : MIT
#
# USAGE   : sudo ./extender.sh install  <domain> [admin_email]
#           sudo ./extender.sh upgrade
#           sudo ./extender.sh uninstall
#
# If [admin_email] is omitted,   sexy69ai@outlook.com   is used.
# ──────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

# ── personalization ──────────────────────────────────────
ADMIN_USER_DEFAULT="sexy69ai"
ADMIN_MAIL_DEFAULT="sexy69ai@outlook.com"

# ── cosmetic helpers ─────────────────────────────────────
R=$'\e[31m';G=$'\e[32m';Y=$'\e[33m';B=$'\e[34m';C=$'\e[36m';W=$'\e[97m';N=$'\e[0m'
log()  { printf "${B}[%-19s]${N} %s\n"  "$(date '+%F %T')" "$*"; }
ok()   { printf "${G}[%-19s]${N} %s\n"  "$(date '+%F %T')" "$*"; }
warn() { printf "${Y}[%-19s]${N} %s\n"  "$(date '+%F %T')" "$*"; }
err()  { printf "${R}[%-19s] ERROR:${N} %s\n" "$(date '+%F %T')" "$*" >&2; }

# ── globals & paths ──────────────────────────────────────
SCRIPT_VERSION="1.3.1-personal"
CFG_DIR=/opt/devpod
DATA_DIR=/srv/devpod
LOG_DIR=/var/log/devpod
BACKUP_DIR=/srv/devpod-backups
TRAEFIK_DIR="$CFG_DIR/traefik"
COMPOSE_FILE="$CFG_DIR/docker-compose.yml"
ENV_FILE="$CFG_DIR/.env"
CRON_FILE=/etc/cron.d/devpod-backup
SSH_PORT=2222

randpw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c32; }
need_root(){ [[ $EUID -ne 0 ]] && { err "Run as root"; exit 1; }; }

banner() {
cat <<EOT
${C}
╔══════════════════════════════════════════════════════╗
║             DevPod – Raspberry Pi Edition            ║
║           personalized for ${ADMIN_USER_DEFAULT}           ║
╠══════════════════════════════════════════════════════╣
║  Version: ${SCRIPT_VERSION}                                 ║
╚══════════════════════════════════════════════════════╝${N}
EOT
}

###############################################################################
#  Dispatch
###############################################################################
[[ $# -lt 1 ]] && { echo "Usage: $0 {install|upgrade|uninstall}"; exit 1; }
MODE="$1"; shift

###############################################################################
#  Install helpers
###############################################################################
install_deps() {
  log "Installing dependencies"
  apt-get update -qq
  apt-get install -yqq curl gnupg git jq lsb-release openssl
  if ! command -v docker >/dev/null; then
      log "Installing Docker"
      curl -fsSL https://get.docker.com | sh
  fi
  if ! docker compose version &>/dev/null; then
      warn "Installing Docker Compose plugin"
      mkdir -p /usr/local/lib/docker/cli-plugins
      TAG=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
      curl -SL "https://github.com/docker/compose/releases/download/${TAG}/docker-compose-linux-$(uname -m)" \
           -o /usr/local/lib/docker/cli-plugins/docker-compose
      chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
}

preflight() {
  if lsof -Pi :80 -sTCP:LISTEN -t >/dev/null || lsof -Pi :443 -sTCP:LISTEN -t >/dev/null; then
      err "Ports 80/443 busy – stop whatever is running first."; exit 1
  fi
}

make_dirs() {
  mkdir -p "$CFG_DIR" "$DATA_DIR" "$LOG_DIR" "$BACKUP_DIR" \
           "$TRAEFIK_DIR"/{dynamic,acme}
  chown -R 1000:1000 "$DATA_DIR" || true
}

gen_secrets() {
  POSTGRES_PASSWORD=$(randpw)
  REDIS_PASSWORD=$(randpw)
  ADMIN_PASSWORD=$(randpw)
  REGISTRY_PASSWORD=$(randpw)
  JWT_SECRET=$(randpw)
  AUTHELIA_JWT=$(randpw)
  DRONE_RPC=$(randpw)
}

write_env() {
cat > "$ENV_FILE" <<EOF
# Generated $(date)
DOMAIN=$DOMAIN
EMAIL=$ADMIN_MAIL
SSH_PORT=$SSH_PORT

TRAEFIK_DIR=$TRAEFIK_DIR
CFG_DIR=$CFG_DIR
DATA_DIR=$DATA_DIR
BACKUP_DIR=$BACKUP_DIR
COMPOSE_FILE=$COMPOSE_FILE

POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
ADMIN_USER=$ADMIN_USER_DEFAULT
ADMIN_PASSWORD=$ADMIN_PASSWORD
REGISTRY_PASSWORD=$REGISTRY_PASSWORD
JWT_SECRET=$JWT_SECRET
AUTHELIA_JWT=$AUTHELIA_JWT
DRONE_RPC=$DRONE_RPC
EOF
}

write_traefik() {
cat > "$TRAEFIK_DIR/traefik.yml" <<EOF
entryPoints:
  web: {address: ":80"}
  websecure: {address: ":443"}
  ssh: {address: ":$SSH_PORT"}
certificatesResolvers:
  letsencrypt:
    acme:
      email: $ADMIN_MAIL
      storage: /acme/acme.json
      httpChallenge: {entryPoint: web}
providers:
  docker: {network: devpod, exposedByDefault: false}
  file:   {directory: /etc/traefik/dynamic, watch: true}
api: {dashboard: true}
EOF
cat > "$TRAEFIK_DIR/dynamic/mw.yml" <<EOF
http:
  middlewares:
    authelia:
      forwardAuth:
        address: http://authelia:9091/api/verify?rd=https://auth.$DOMAIN
        trustForwardHeader: true
        authResponseHeaders:
          - Remote-User
          - Remote-Email
          - Remote-Name
          - Remote-Groups
EOF
chmod 600 "$TRAEFIK_DIR"/acme
}

write_authelia() {
mkdir -p "$CFG_DIR/authelia"
cat > "$CFG_DIR/authelia/config.yml" <<EOF
jwt_secret: $AUTHELIA_JWT
host: 0.0.0.0
port: 9091
theme: dark
session:
  secret: $JWT_SECRET
  domain: $DOMAIN
authentication_backend:
  file: {path: /config/users.yml}
access_control:
  default_policy: deny
  rules:
    - domain: "*.$DOMAIN"
      policy: one_factor
storage: {local: {path: /config/db.sqlite3}}
notifier: {filesystem: {filename: /config/notification.txt}}
EOF
PASS_HASH=$(docker run --rm authelia/authelia:4.38.0 \
             authelia crypto hash generate argon2 --password "$ADMIN_PASSWORD")
cat > "$CFG_DIR/authelia/users.yml" <<EOF
users:
  ${ADMIN_USER_DEFAULT}:
    displayname: "${ADMIN_USER_DEFAULT}"
    password: "$PASS_HASH"
    email: $ADMIN_MAIL
    groups: ["admins"]
EOF
}

write_compose() {
cat > "$COMPOSE_FILE" <<'EOF'
version: "3.9"
networks: {devpod: {}, monitor: {}}
volumes:
  pg: {}; redis: {}; gitea: {}; drone: {}; registry: {}
  verdaccio: {}; pypi: {}; code: {}; prometheus: {}; grafana: {}
  authelia: {}; acme: {}

services:
  traefik:
    image: traefik:v2.10
    networks: [devpod]
    ports: ["80:80","443:443","${SSH_PORT}:${SSH_PORT}"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${TRAEFIK_DIR}:/etc/traefik
      - ${TRAEFIK_DIR}/acme:/acme

  # ── stores ──
  postgres:
    image: postgres:16-alpine
    environment: {POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}}
    volumes: [pg:/var/lib/postgresql/data]
    networks: [devpod]

  redis:
    image: redis:7-alpine
    command: --requirepass ${REDIS_PASSWORD}
    volumes: [redis:/data]
    networks: [devpod]

  # ── dev services ──
  gitea:
    image: gitea/gitea:1.21-rootless
    depends_on: [postgres, redis]
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=postgres
      - GITEA__database__HOST=postgres:5432
      - GITEA__database__PASSWD=${POSTGRES_PASSWORD}
      - GITEA__security__SECRET_KEY=${JWT_SECRET}
      - GITEA__server__DOMAIN=git.${DOMAIN}
      - GITEA__server__ROOT_URL=https://git.${DOMAIN}/
      - GITEA__server__SSH_DOMAIN=git.${DOMAIN}
      - GITEA__server__SSH_PORT=${SSH_PORT}
      - GITEA__security__DEFAULT_ADMIN_NAME=${ADMIN_USER}
      - GITEA__security__DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - GITEA__security__DEFAULT_ADMIN_EMAIL=${EMAIL}
      - GITEA__cache__ADAPTER=redis
      - GITEA__cache__HOST=redis:6379
      - GITEA__cache__PASSWORD=${REDIS_PASSWORD}
    volumes: [gitea:/var/lib/gitea]
    networks: [devpod]
    labels:
      traefik.enable: "true"
      traefik.http.routers.gitea.rule: Host(`git.${DOMAIN}`)
      traefik.http.routers.gitea.entrypoints: websecure
      traefik.http.routers.gitea.tls.certresolver: letsencrypt
      traefik.http.routers.gitea.middlewares: authelia@file

  drone:
    image: drone/drone:2.24
    depends_on: [gitea]
    environment:
      DRONE_GITEA_SERVER: https://git.${DOMAIN}
      DRONE_SERVER_HOST: ci.${DOMAIN}
      DRONE_SERVER_PROTO: https
      DRONE_RPC_SECRET: ${DRONE_RPC}
    volumes: [drone:/data]
    networks: [devpod]
    labels:
      traefik.enable: "true"
      traefik.http.routers.drone.rule: Host(`ci.${DOMAIN}`)
      traefik.http.routers.drone.entrypoints: websecure
      traefik.http.routers.drone.tls.certresolver: letsencrypt
      traefik.http.routers.drone.middlewares: authelia@file

  drone-runner:
    image: drone/drone-runner-docker:1.8.3
    depends_on: [drone]
    environment:
      DRONE_RPC_PROTO: http
      DRONE_RPC_HOST: drone
      DRONE_RPC_SECRET: ${DRONE_RPC}
    volumes: [/var/run/docker.sock:/var/run/docker.sock]
    networks: [devpod]

  registry:
    image: registry:2
    environment: {REGISTRY_HTTP_ADDR: :5000}
    volumes: [registry:/var/lib/registry]
    networks: [devpod]
    labels:
      traefik.enable: "true"
      traefik.http.routers.registry.rule: Host(`registry.${DOMAIN}`)
      traefik.http.routers.registry.entrypoints: websecure
      traefik.http.routers.registry.tls.certresolver: letsencrypt
      traefik.http.routers.registry.middlewares: authelia@file

  verdaccio:
    image: verdaccio/verdaccio:5
    volumes: [verdaccio:/verdaccio/storage]
    networks: [devpod]
    labels:
      traefik.enable: "true"
      traefik.http.routers.npm.rule: Host(`npm.${DOMAIN}`)
      traefik.http.routers.npm.entrypoints: websecure
      traefik.http.routers.npm.tls.certresolver: letsencrypt
      traefik.http.routers.npm.middlewares: authelia@file

  pypi:
    image: pypiserver/pypiserver:1.5.2
    command: -P .htpasswd -a update,download /data/packages
    volumes: [pypi:/data/packages]
    networks: [devpod]
    labels:
      traefik.enable: "true"
      traefik.http.routers.pypi.rule: Host(`pypi.${DOMAIN}`)
      traefik.http.routers.pypi.entrypoints: websecure
      traefik.http.routers.pypi.tls.certresolver: letsencrypt
      traefik.http.routers.pypi.middlewares: authelia@file

  code:
    image: lscr.io/linuxserver/code-server:4.22.0
    environment:
      PUID: 1000
      PGID: 1000
      PASSWORD: ${ADMIN_PASSWORD}
      TZ: UTC
    volumes:
      - code:/config
      - /home/${SUDO_USER:-pi}:/home/dev
    networks: [devpod]
    labels:
      traefik.enable: "true"
      traefik.http.routers.code.rule: Host(`code.${DOMAIN}`)
      traefik.http.routers.code.entrypoints: websecure
      traefik.http.routers.code.tls.certresolver: letsencrypt
      traefik.http.routers.code.middlewares: authelia@file

  # ── monitoring ──
  prometheus:
    image: prom/prometheus:v2.48.1
    volumes: [prometheus:/prometheus]
    networks: [monitor]
    command: --config.file=/etc/prometheus/prometheus.yml
    labels:
      traefik.enable: "true"
      traefik.http.routers.prom.rule: Host(`prom.${DOMAIN}`)
      traefik.http.routers.prom.entrypoints: websecure
      traefik.http.routers.prom.tls.certresolver: letsencrypt
      traefik.http.routers.prom.middlewares: authelia@file

  grafana:
    image: grafana/grafana:10.2.2
    depends_on: [prometheus]
    volumes: [grafana:/var/lib/grafana]
    networks: [monitor]
    labels:
      traefik.enable: "true"
      traefik.http.routers.grafana.rule: Host(`grafana.${DOMAIN}`)
      traefik.http.routers.grafana.entrypoints: websecure
      traefik.http.routers.grafana.tls.certresolver: letsencrypt
      traefik.http.routers.grafana.middlewares: authelia@file

  authelia:
    image: authelia/authelia:4.38.0
    volumes:
      - ${CFG_DIR}/authelia:/config
      - authelia:/var/lib/authelia
    networks: [devpod]
EOF
}

backup_job() {
cat > "$CFG_DIR/backup.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$ENV_FILE"
DEST="${BACKUP_DIR}/$(date +%F)"
mkdir -p "$DEST"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T postgres \
     pg_dumpall -U postgres > "$DEST/postgres.sql"
tar -czf "$DEST/data.tar.gz" -C "$DATA_DIR" .
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;
BASH
chmod +x "$CFG_DIR/backup.sh"
echo "0 3 * * * root $CFG_DIR/backup.sh >>$LOG_DIR/backup.log 2>&1" > "$CRON_FILE"
}

show_info() {
cat <<INFO

${W}=========  DevPod URLs / Credentials  =========${N}
   Admin user  : ${Y}${ADMIN_USER_DEFAULT}${N}
   Password    : ${Y}${ADMIN_PASSWORD}${N}

   VS Code     : https://code.$DOMAIN
   Gitea       : https://git.$DOMAIN
   Drone CI    : https://ci.$DOMAIN
   Registry    : https://registry.$DOMAIN
   Prometheus  : https://prom.$DOMAIN
   Grafana     : https://grafana.$DOMAIN
   Traefik     : https://traefik.$DOMAIN
(All sites protected by Authelia SSO.)
INFO
}

###############################################################################
#  Main modes
###############################################################################
need_root
banner

case "$MODE" in
 install)
    [[ $# -lt 1 || $# -gt 2 ]] && { err "Usage: $0 install <domain> [email]"; exit 1; }
    DOMAIN="$1"
    ADMIN_MAIL="${2:-$ADMIN_MAIL_DEFAULT}"

    preflight
    install_deps
    make_dirs
    gen_secrets
    write_env
    write_traefik
    write_authelia
    write_compose
    ok "Pulling container images (first run)…"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
    ok "Starting stack"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    backup_job
    ok "DevPod deployed ✔"
    show_info
    ;;
 upgrade)
    source "$ENV_FILE"
    ok "Upgrading containers"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    ;;
 uninstall)
    read -rp "This removes DevPod completely. Continue? [y/N] " a
    [[ $a =~ ^[yY]$ ]] || { echo "Abort"; exit 0; }
    source "$ENV_FILE" || true
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down -v || true
    rm -rf "$CFG_DIR" "$DATA_DIR" "$BACKUP_DIR" "$CRON_FILE"
    ok "DevPod removed"
    ;;
 *)
    err "Unknown mode $MODE"; exit 1 ;;
esac
