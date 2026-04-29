#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# F4IOZ Site — LXC installer for Proxmox VE
# Crée une CT Debian 13 prête à développer le site web radioamateur de F4IOZ
# Stack : FastAPI + Jinja2 + Markdown + HTMX + SQLite
# Style : community-scripts.org
#
# Usage : sur le nœud Proxmox, en root :
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/f4ioz/f4ioz-site-proxmox/main/f4ioz-site-lxc.sh)"
# ------------------------------------------------------------------------------

set -euo pipefail

# ─── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

msg_info() { echo -e "${CYAN}${BOLD}[..]${NC} $1"; }
msg_ok()   { echo -e "${GREEN}${BOLD}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}${BOLD}[!!]${NC} $1"; }
msg_err()  { echo -e "${RED}${BOLD}[KO]${NC} $1" >&2; }

header() {
  clear
  cat <<'EOF'
  ____ _  _    ___    ___    __________
 |  __| || |  |_ _|  / _ \  |__  /__  /
 | |_ | || |_  | |  | | | |   / /  / /
 |  _||__   _| | |  | |_| |  / /_ / /_
 |_|     |_|  |___|  \___/  /____/____|

 F4IOZ Site — LXC Installer for Proxmox VE
 Debian 13 · FastAPI · Jinja · Markdown · HTMX
EOF
  echo
}

# ─── Pré-checks ───────────────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || { msg_err "À lancer en root sur le nœud Proxmox."; exit 1; }
}
check_proxmox() {
  command -v pct   >/dev/null || { msg_err "pct introuvable : pas sur un Proxmox ?"; exit 1; }
  command -v pveam >/dev/null || { msg_err "pveam introuvable."; exit 1; }
}

# ─── Défauts ──────────────────────────────────────────────────────────────────
D_HOSTNAME="f4ioz-site"
D_DISK="20"          # Go (articles md + photos potentielles)
D_CORES="2"
D_RAM="2048"         # Mo (FastAPI + Jinja, pas besoin de 4 Go)
D_SWAP="1024"        # Mo
D_STORAGE="local-lvm"
D_BRIDGE="vmbr0"
D_TMPL_STORAGE="local"
D_USER="f4ioz"
D_IP="dhcp"

find_next_ctid() {
  local id=100
  while pct status "$id" &>/dev/null; do ((id++)); done
  echo "$id"
}

# ─── Prompt config ────────────────────────────────────────────────────────────
prompt_config() {
  D_CTID=$(find_next_ctid)
  echo -e "${BOLD}Configuration de la CT${NC} (Entrée = défaut)"
  echo

  read -rp "Container ID [${D_CTID}] : " CTID;       CTID=${CTID:-$D_CTID}
  read -rp "Hostname [${D_HOSTNAME}] : " CT_HOST;    CT_HOST=${CT_HOST:-$D_HOSTNAME}
  read -rp "Disque (Go) [${D_DISK}] : " DISK;        DISK=${DISK:-$D_DISK}
  read -rp "vCPU [${D_CORES}] : " CORES;             CORES=${CORES:-$D_CORES}
  read -rp "RAM (Mo) [${D_RAM}] : " RAM;             RAM=${RAM:-$D_RAM}
  read -rp "Swap (Mo) [${D_SWAP}] : " SWAP;          SWAP=${SWAP:-$D_SWAP}
  read -rp "Storage CT [${D_STORAGE}] : " STORAGE;   STORAGE=${STORAGE:-$D_STORAGE}
  read -rp "Bridge réseau [${D_BRIDGE}] : " BRIDGE;  BRIDGE=${BRIDGE:-$D_BRIDGE}
  read -rp "IP (dhcp ou CIDR ex 192.168.0.50/24) [${D_IP}] : " IP; IP=${IP:-$D_IP}
  GATEWAY=""
  if [[ "$IP" != "dhcp" ]]; then
    read -rp "Passerelle (ex 192.168.0.1) : " GATEWAY
  fi
  read -rp "Utilisateur applicatif [${D_USER}] : " APP_USER; APP_USER=${APP_USER:-$D_USER}

  echo
  echo "Nom de domaine pour le reverse proxy nginx (ex. f4ioz.fr)"
  read -rp "Domaine (Entrée pour saisir plus tard) : " DOMAIN

  echo
  echo "Clé SSH publique à injecter pour $APP_USER (optionnel)."
  echo "Colle une ligne ssh-ed25519/ssh-rsa... ou Entrée pour ignorer :"
  read -r SSH_PUBKEY

  while :; do
    read -rsp "Mot de passe root de la CT : " CT_PW; echo
    read -rsp "Confirmer : " CT_PW2; echo
    [[ -n "$CT_PW" && "$CT_PW" == "$CT_PW2" ]] && break
    msg_warn "Mots de passe différents ou vides."
  done
  while :; do
    read -rsp "Mot de passe ${APP_USER} : " APP_PW; echo
    read -rsp "Confirmer : " APP_PW2; echo
    [[ -n "$APP_PW" && "$APP_PW" == "$APP_PW2" ]] && break
    msg_warn "Mots de passe différents ou vides."
  done

  echo
  echo -e "${BOLD}Récapitulatif${NC}"
  echo "  CTID=$CTID  host=$CT_HOST  disk=${DISK}G  cpu=$CORES  ram=${RAM}M  swap=${SWAP}M"
  echo "  storage=$STORAGE  bridge=$BRIDGE  ip=$IP ${GATEWAY:+gw=$GATEWAY}"
  echo "  user=$APP_USER  domain=${DOMAIN:-non défini}"
  read -rp "Continuer ? [O/n] : " C
  [[ "${C:-O}" =~ ^[OoYy]$ ]] || { msg_warn "Annulé."; exit 0; }
}

# ─── Template ─────────────────────────────────────────────────────────────────
ensure_template() {
  msg_info "Recherche d'un template Debian 13…"
  pveam update >/dev/null 2>&1 || true
  local tmpl
  tmpl=$(pveam available --section system 2>/dev/null \
         | awk '/debian-13-standard.*amd64/ {print $2}' | sort -r | head -n1)
  [[ -n "$tmpl" ]] || { msg_err "Aucun template debian-13-standard dans pveam."; exit 1; }

  if ! pveam list "$D_TMPL_STORAGE" 2>/dev/null | grep -q "$tmpl"; then
    msg_info "Téléchargement du template $tmpl…"
    pveam download "$D_TMPL_STORAGE" "$tmpl"
  fi
  TEMPLATE="${D_TMPL_STORAGE}:vztmpl/${tmpl}"
  msg_ok "Template : $tmpl"
}

# ─── Création CT ──────────────────────────────────────────────────────────────
create_lxc() {
  msg_info "Création de la CT $CTID…"
  local net="name=eth0,bridge=${BRIDGE}"
  if [[ "$IP" == "dhcp" ]]; then
    net="${net},ip=dhcp"
  else
    net="${net},ip=${IP},gw=${GATEWAY}"
  fi

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOST" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$net" \
    --password "$CT_PW" \
    --features nesting=1 \
    --onboot 1 \
    --unprivileged 1 \
    --ostype debian >/dev/null
  msg_ok "CT créée."

  msg_info "Démarrage…"
  pct start "$CTID"
  sleep 5
  msg_ok "CT démarrée."
}

# ─── Bootstrap interne ────────────────────────────────────────────────────────
wait_network() {
  msg_info "Attente de la connectivité réseau…"
  local n=20
  while (( n-- > 0 )); do
    pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null && { msg_ok "Réseau OK."; return; }
    sleep 2
  done
  msg_err "Pas de DNS dans la CT."; exit 1
}

install_packages() {
  msg_info "Configuration des locales…"
  pct exec "$CTID" -- bash -c '
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq locales >/dev/null 2>&1
    sed -i "s/^# *\(en_US.UTF-8\)/\1/" /etc/locale.gen
    sed -i "s/^# *\(fr_FR.UTF-8\)/\1/" /etc/locale.gen
    locale-gen >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8
  '
  msg_ok "Locales générées."

  msg_info "apt update + upgrade…"
  pct exec "$CTID" -- bash -c \
    'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
     apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq' >/dev/null
  msg_ok "Système à jour."

  msg_info "Installation des paquets…"
  pct exec "$CTID" -- bash -c \
    'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
       curl ca-certificates git sudo tmux nano vim less jq \
       python3 python3-venv python3-pip python3-dev \
       build-essential pkg-config \
       libjpeg-dev zlib1g-dev \
       openssh-server' >/dev/null
  msg_ok "Paquets installés."
}

create_user() {
  msg_info "Création de l'utilisateur $APP_USER…"
  pct exec "$CTID" -- bash -c "
    id -u $APP_USER &>/dev/null || adduser --disabled-password --gecos '' $APP_USER
    echo '$APP_USER:$APP_PW' | chpasswd
    usermod -aG sudo $APP_USER
  "
  if [[ -n "${SSH_PUBKEY:-}" ]]; then
    msg_info "Injection de la clé SSH publique…"
    pct exec "$CTID" -- bash -c "
      install -d -m 700 -o $APP_USER -g $APP_USER /home/$APP_USER/.ssh
      echo '$SSH_PUBKEY' >> /home/$APP_USER/.ssh/authorized_keys
      chown $APP_USER:$APP_USER /home/$APP_USER/.ssh/authorized_keys
      chmod 600 /home/$APP_USER/.ssh/authorized_keys
    "
  fi
  msg_ok "Utilisateur prêt."
}

configure_ssh() {
  msg_info "Activation SSH (service classique, pas socket activation)…"
  pct exec "$CTID" -- bash -c '
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    # Debian 13 active ssh.socket par défaut → conflit si reload de ssh.service
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    ssh-keygen -A >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1
    systemctl restart ssh.service >/dev/null 2>&1
    sleep 1
    systemctl is-active ssh.service >/dev/null || systemctl restart ssh.service
  '
  msg_ok "SSH activé."
}

bootstrap_project() {
  msg_info "Initialisation du projet f4ioz-site…"
  local tmpdir; tmpdir=$(mktemp -d)

  cat > "$tmpdir/CLAUDE.md" <<EOCLAUDE
# F4IOZ Site — Site web radioamateur de F4IOZ

## Objectif
Site web personnel d'Olivier F4IOZ, radioamateur basé en JN18FS (région
parisienne), membre du Radioclub de Saint Maur des Fossés (F6KMX).
Plateforme à la fois éditoriale (articles, expéditions, galeries) et
applicative (outils interactifs : passages satellite, etc.).
Public : Internet, via reverse proxy nginx + nom de domaine.

## Stack
- Backend : Python 3.11+ / FastAPI / Pydantic / httpx
- Templating : Jinja2Templates (rendu serveur)
- Contenu : articles en Markdown (python-frontmatter + markdown-it-py)
- Front : HTMX + Alpine.js + CSS custom (responsive mobile-first)
- DB : SQLite (compteur, cache TLE/QSO Wavelog, éventuels commentaires)
- Astro/sat : skyfield (préféré à pyephem) + sgp4
- Images : Pillow pour les galeries (resize, thumbnails)
- Déploiement : uvicorn HTTP en interne, TLS terminé par nginx externe
- Headers respectés : X-Forwarded-Proto, X-Forwarded-For
- Pas de build step front (tout côté serveur ou htmx)

## Reverse proxy
Nginx externe (autre VM/CT du LAN) gère :
- HTTPS (Let's Encrypt sur le domaine $DOMAIN)
- Redirection 80 → 443
- Forward vers la CT ${CT_HOST} sur :8000
- Headers X-Forwarded-Proto / X-Forwarded-For / Host

## Sections du site (v1)
1. Accueil — présentation rapide F4IOZ + dernier article + dernier QSO
2. Articles — billets datés (activations, expéditions, retours technique)
   - Source : fichiers Markdown dans content/articles/YYYY/slug.md
   - Front matter YAML (title, date, tags, summary, hero_image)
   - Listing par tag, pagination
3. Galeries — photos QSL, setup, antennes, expéditions
   - Source : dossiers dans content/gallery/<nom>/
   - Métadonnées dans <nom>/info.md
   - Génération auto de thumbnails au chargement
4. Logbook — QSO récents
   - Lecture depuis l'API Wavelog : GET /index.php/api/logbook (ou équivalent)
   - Cache SQLite TTL 15 min
   - Filtrage : satellite/HF/VHF, dernier mois
5. Outils
   - /sat/passes : prédiction passages satellite par locator
     (Skyfield + TLE Celestrak, cache TLE 6h)
   - /grid : convertisseur locator ↔ lat/lon
   - À venir : carte des activations, calculateur azimuth/distance

## Conventions
- Code/variables en anglais, commentaires en français acceptés
- UTF-8 partout
- Slugs : minuscules, tirets, ASCII pur
- Dates internes en UTC, affichage en Europe/Paris
- Locator regex ^[A-R]{2}[0-9]{2}([A-X]{2})?$
- Callsigns uppercase
- Articles versionnés dans Git (pas de DB pour le contenu éditorial)

## Structure
- app/main.py             — FastAPI entrypoint, mount static, include routers
- app/config.py           — chargement config.yml
- app/content.py          — chargement/rendu Markdown + cache
- app/wavelog_client.py   — client API Wavelog (lecture log public)
- app/sat.py              — Skyfield, TLE, prédictions de passages
- app/galleries.py        — scan dossiers, thumbnails Pillow
- app/db.py               — SQLite (cache, compteurs)
- app/models.py           — Pydantic
- app/routers/
    home.py, articles.py, gallery.py, logbook.py, tools.py
- templates/              — Jinja2 (base.html, partials htmx, pages)
- static/                 — CSS mobile-first, JS Alpine, fonts
- content/
    articles/YYYY/*.md
    gallery/<nom>/*.{jpg,info.md}
    pages/about.md, contact.md
- config.yml              — domaine, Wavelog url+key, paths… (hors git)
- f4ioz-site.service      — unit systemd

## Config (config.yml, .gitignore)
site:
  title: "F4IOZ — Olivier"
  domain: "${DOMAIN:-f4ioz.fr}"
  base_url: "https://${DOMAIN:-f4ioz.fr}"
  locator: "JN18FS"
  timezone: "Europe/Paris"
wavelog:
  url: ""
  api_key: ""           # clé read-only de préférence
satnogs:
  base_url: "https://db.satnogs.org/api"
sat:
  default_satellites: ["ISS", "SO-50", "RS-44", "AO-7", "PO-101"]
  tle_cache_minutes: 360

## Commandes
- Dev   : uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
- Tests : pytest
- Lint  : ruff check app/

## Hors périmètre v1
- Pas d'admin web (édition d'articles via Git/SSH/VS Code Remote)
- Pas de commentaires (Disqus/Isso à voir plus tard)
- Pas de newsletter
- Pas de multi-langue (FR uniquement pour l'instant)
- Pas de panier / paiement (évidemment)

## Licences & contenu
- Code : MIT (à confirmer)
- Articles : © F4IOZ, contact pour reprise
- Photos : idem, mention obligatoire si reprise
EOCLAUDE

  cat > "$tmpdir/.gitignore" <<'EOGIT'
config.yml
.venv/
__pycache__/
*.db
*.sqlite
*.sqlite-journal
.pytest_cache/
.ruff_cache/
*.log
.DS_Store
content/gallery/**/_thumbs/
EOGIT

  cat > "$tmpdir/config.yml.example" <<EOEX
site:
  title: "F4IOZ — Olivier"
  domain: "${DOMAIN:-f4ioz.fr}"
  base_url: "https://${DOMAIN:-f4ioz.fr}"
  locator: "JN18FS"
  timezone: "Europe/Paris"

wavelog:
  url: ""
  api_key: ""

satnogs:
  base_url: "https://db.satnogs.org/api"

sat:
  default_satellites:
    - ISS
    - SO-50
    - RS-44
    - AO-7
    - PO-101
  tle_cache_minutes: 360
EOEX

  pct exec "$CTID" -- sudo -u "$APP_USER" mkdir -p "/home/$APP_USER/site"
  pct push "$CTID" "$tmpdir/CLAUDE.md"          "/home/$APP_USER/site/CLAUDE.md"          --user "$APP_USER" --group "$APP_USER"
  pct push "$CTID" "$tmpdir/.gitignore"         "/home/$APP_USER/site/.gitignore"         --user "$APP_USER" --group "$APP_USER"
  pct push "$CTID" "$tmpdir/config.yml.example" "/home/$APP_USER/site/config.yml.example" --user "$APP_USER" --group "$APP_USER"
  rm -rf "$tmpdir"

  pct exec "$CTID" -- sudo -u "$APP_USER" bash -c "
    cd /home/$APP_USER/site
    git init -q
    git -c user.email='${APP_USER}@${CT_HOST}' -c user.name='${APP_USER}' add CLAUDE.md .gitignore config.yml.example
    git -c user.email='${APP_USER}@${CT_HOST}' -c user.name='${APP_USER}' commit -q -m 'initial project setup'
    python3 -m venv .venv
    .venv/bin/pip install --quiet --upgrade pip
    .venv/bin/pip install --quiet \
      fastapi 'uvicorn[standard]' httpx pydantic pyyaml \
      jinja2 python-multipart \
      'markdown-it-py[plugins]' python-frontmatter \
      pillow \
      skyfield sgp4 \
      pytest ruff
  "
  msg_ok "Projet f4ioz-site initialisé (git + venv + dépendances)."
}

install_systemd_service() {
  msg_info "Installation du service systemd f4ioz-site (désactivé pour l'instant)…"
  pct exec "$CTID" -- bash -c "cat > /etc/systemd/system/f4ioz-site.service <<EOF
[Unit]
Description=F4IOZ Site (FastAPI/uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=/home/${APP_USER}/site
Environment=PATH=/home/${APP_USER}/site/.venv/bin
ExecStart=/home/${APP_USER}/site/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
"
  msg_ok "Service installé (à activer après dev : systemctl enable --now f4ioz-site)."
}

install_claude_code() {
  msg_info "Installation de Claude Code pour $APP_USER…"
  pct exec "$CTID" -- sudo -u "$APP_USER" bash -c '
    curl -fsSL https://claude.ai/install.sh | bash
    grep -q ".local/bin" "$HOME/.bashrc" 2>/dev/null || \
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
  ' || msg_warn "Échec Claude Code — à relancer manuellement dans la CT."
  msg_ok "Claude Code installé."
}

# ─── Récap final ──────────────────────────────────────────────────────────────
show_summary() {
  local ip
  ip=$(pct exec "$CTID" -- bash -c \
       "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || echo "?")

  echo
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}${BOLD}  Installation terminée${NC}"
  echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo
  echo "  CT ID      : $CTID"
  echo "  Hostname   : $CT_HOST"
  echo "  IP         : $ip"
  echo "  User       : $APP_USER"
  echo "  Domaine    : ${DOMAIN:-(à définir)}"
  echo
  echo "  SSH        : ssh ${APP_USER}@${ip}"
  echo "  App (dev)  : http://${ip}:8000"
  echo
  echo "  Reverse-proxy nginx (ton serveur du LAN) — exemple Let's Encrypt :"
  echo "    server {"
  echo "      listen 80;"
  echo "      server_name ${DOMAIN:-f4ioz.fr} www.${DOMAIN:-f4ioz.fr};"
  echo "      return 301 https://${DOMAIN:-f4ioz.fr}\$request_uri;"
  echo "    }"
  echo "    server {"
  echo "      listen 443 ssl http2;"
  echo "      server_name ${DOMAIN:-f4ioz.fr};"
  echo "      ssl_certificate     /etc/letsencrypt/live/${DOMAIN:-f4ioz.fr}/fullchain.pem;"
  echo "      ssl_certificate_key /etc/letsencrypt/live/${DOMAIN:-f4ioz.fr}/privkey.pem;"
  echo "      client_max_body_size 25m;   # uploads photos"
  echo "      location / {"
  echo "        proxy_pass http://${ip}:8000;"
  echo "        proxy_set_header Host \$host;"
  echo "        proxy_set_header X-Real-IP \$remote_addr;"
  echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
  echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
  echo "      }"
  echo "    }"
  echo
  echo "  Démarrer Claude Code :"
  echo "    ssh ${APP_USER}@${ip}"
  echo "    cd ~/site && source .venv/bin/activate"
  echo "    claude"
  echo
  echo "  Une fois l'app prête, activer le service systemd :"
  echo "    sudo systemctl enable --now f4ioz-site"
  echo "    sudo systemctl status f4ioz-site"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  header
  check_root
  check_proxmox
  prompt_config
  ensure_template
  create_lxc
  wait_network
  install_packages
  create_user
  configure_ssh
  bootstrap_project
  install_systemd_service
  install_claude_code
  show_summary
}

main "$@"
