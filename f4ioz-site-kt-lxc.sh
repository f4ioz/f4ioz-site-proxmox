#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# F4IOZ Site (Kotlin) — LXC pour Proxmox VE
# Crée une CT Debian 13 vide et sûre, prête pour le nouveau site (module :site de SatMe).
# Ne fait que le socle : Java 21, SSH par clé seulement, locales, mises à jour de sécurité.
# Le site lui-même (utilisateur de service, /etc/f4ioz-site-kt, service, pare-feu,
# articles) est installé ensuite par installe-site.sh, depuis le PC, en SSH root.
#
# Usage : sur le nœud Proxmox, en root :
#   bash f4ioz-site-kt-lxc.sh
# ------------------------------------------------------------------------------

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
msg_info() { echo -e "${CYAN}${BOLD}[..]${NC} $1"; }
msg_ok()   { echo -e "${GREEN}${BOLD}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}${BOLD}[!!]${NC} $1"; }
msg_err()  { echo -e "${RED}${BOLD}[KO]${NC} $1" >&2; }

# La clé de Claude Code sur le PC de F4IOZ (sans elle, Claude ne peut pas installer le site).
CLE_CLAUDE='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORgerzsceYxgTZcRJ0UjE915oTh3xw8rQp2+pR95aS6 Claude Code - site f4ioz.fr (PC F4IOZ)'

D_HOSTNAME="f4ioz-site-kt"
D_DISK="10"; D_CORES="1"; D_RAM="1536"; D_SWAP="512"
D_STORAGE="local-lvm"; D_BRIDGE="vmbr0"; D_TMPL_STORAGE="local"

[[ $EUID -eq 0 ]] || { msg_err "À lancer en root sur le nœud Proxmox."; exit 1; }
command -v pct >/dev/null && command -v pveam >/dev/null || { msg_err "pct/pveam introuvables : pas sur un Proxmox ?"; exit 1; }

find_next_ctid() { local id=100; while pct status "$id" &>/dev/null; do ((id++)); done; echo "$id"; }

# Une adresse libre sur le réseau du bridge : ni prise par une CT/VM du Proxmox (même arrêtée),
# ni qui répond (ARP ou ping). De .50 à .250, hors de la plupart des plages DHCP des box.
propose_ip() {
  D_IP=""; D_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  local cidr; cidr=$(ip -4 -o addr show "$BRIDGE" 2>/dev/null | awk '{print $4; exit}')
  [[ -n "$cidr" ]] || return 0
  local masque=${cidr#*/} base; base=$(echo "${cidr%/*}" | cut -d. -f1-3)
  [[ "$masque" == "24" ]] || return 0
  local prises; prises=$(cat /etc/pve/lxc/*.conf /etc/pve/qemu-server/*.conf 2>/dev/null | grep -o 'ip=[0-9.]*' | cut -d= -f2)
  msg_info "Recherche d'une adresse libre sur ${base}.0/24…"
  local n ip
  for n in $(seq 50 250); do
    ip="${base}.${n}"
    [[ "$ip" == "${cidr%/*}" || "$ip" == "$D_GW" ]] && continue
    grep -qx "$ip" <<<"$prises" && continue
    ping -c1 -W1 "$ip" &>/dev/null && continue
    if command -v arping >/dev/null; then arping -c2 -w2 -I "$BRIDGE" "$ip" &>/dev/null && continue
    else ip neigh show "$ip" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY' && continue; fi
    D_IP="${ip}/24"; msg_ok "Adresse libre proposée : ${ip} (vérifie qu'elle est hors de la plage DHCP de ta box)"; return 0
  done
  msg_warn "Aucune adresse libre trouvée entre .50 et .250."
}

prompt_config() {
  D_CTID=$(find_next_ctid)
  echo -e "${BOLD}Nouvelle CT du site F4IOZ (Kotlin)${NC} (Entrée = défaut)"; echo
  read -rp "Container ID [${D_CTID}] : " CTID;       CTID=${CTID:-$D_CTID}
  read -rp "Hostname [${D_HOSTNAME}] : " CT_HOST;    CT_HOST=${CT_HOST:-$D_HOSTNAME}
  read -rp "Disque (Go) [${D_DISK}] : " DISK;        DISK=${DISK:-$D_DISK}
  read -rp "vCPU [${D_CORES}] : " CORES;             CORES=${CORES:-$D_CORES}
  read -rp "RAM (Mo) [${D_RAM}] : " RAM;             RAM=${RAM:-$D_RAM}
  read -rp "Swap (Mo) [${D_SWAP}] : " SWAP;          SWAP=${SWAP:-$D_SWAP}
  read -rp "Storage CT [${D_STORAGE}] : " STORAGE;   STORAGE=${STORAGE:-$D_STORAGE}
  read -rp "Bridge réseau [${D_BRIDGE}] : " BRIDGE;  BRIDGE=${BRIDGE:-$D_BRIDGE}
  # Une IP fixe : nginx et le pare-feu en dépendent. Une adresse libre est proposée.
  propose_ip
  while :; do
    read -rp "IP fixe en CIDR${D_IP:+ [${D_IP}]} : " IP; IP=${IP:-$D_IP}
    [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
    msg_warn "Une IP fixe est nécessaire (ex 192.168.0.51/24)."
  done
  read -rp "Passerelle [${D_GW:-192.168.0.1}] : " GATEWAY; GATEWAY=${GATEWAY:-${D_GW:-192.168.0.1}}
  echo
  echo "Ta propre clé SSH publique pour root (en plus de celle de Claude), ou Entrée :"
  read -r SSH_PUBKEY
  while :; do
    read -rsp "Mot de passe root de la CT (console Proxmox seulement, jamais par SSH) : " CT_PW; echo
    read -rsp "Confirmer : " CT_PW2; echo
    [[ -n "$CT_PW" && "$CT_PW" == "$CT_PW2" ]] && break
    msg_warn "Mots de passe différents ou vides."
  done
  echo
  echo -e "${BOLD}Récapitulatif${NC}"
  echo "  CTID=$CTID  host=$CT_HOST  disk=${DISK}G  cpu=$CORES  ram=${RAM}M  swap=${SWAP}M"
  echo "  storage=$STORAGE  bridge=$BRIDGE  ip=$IP  gw=$GATEWAY"
  read -rp "Continuer ? [O/n] : " C
  [[ "${C:-O}" =~ ^[OoYy]$ ]] || { msg_warn "Annulé."; exit 0; }
}

ensure_template() {
  msg_info "Recherche d'un template Debian 13…"
  pveam update >/dev/null 2>&1 || true
  local tmpl
  tmpl=$(pveam available --section system 2>/dev/null | awk '/debian-13-standard.*amd64/ {print $2}' | sort -r | head -n1)
  [[ -n "$tmpl" ]] || { msg_err "Aucun template debian-13-standard dans pveam."; exit 1; }
  pveam list "$D_TMPL_STORAGE" 2>/dev/null | grep -q "$tmpl" || pveam download "$D_TMPL_STORAGE" "$tmpl"
  TEMPLATE="${D_TMPL_STORAGE}:vztmpl/${tmpl}"
  msg_ok "Template : $tmpl"
}

create_lxc() {
  msg_info "Création de la CT $CTID…"
  local cles; cles=$(mktemp)
  echo "$CLE_CLAUDE" > "$cles"
  [[ -n "${SSH_PUBKEY:-}" ]] && echo "$SSH_PUBKEY" >> "$cles"
  # Non privilégiée ; nesting=1 : le systemd de Debian 13 en a besoin dans une CT.
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOST" --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --password "$CT_PW" --ssh-public-keys "$cles" \
    --features nesting=1 --onboot 1 --unprivileged 1 --ostype debian >/dev/null
  rm -f "$cles"
  pct start "$CTID"
  msg_ok "CT $CTID créée et démarrée."
}

wait_network() {
  msg_info "Attente du réseau…"
  local n=30
  while (( n-- > 0 )); do
    pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null && { msg_ok "Réseau OK."; return; }
    sleep 2
  done
  msg_err "Pas de DNS dans la CT."; exit 1
}

install_packages() {
  msg_info "Mise à jour et paquets (Java 21, SSH, pare-feu, mises à jour de sécurité)…"
  pct exec "$CTID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq locales >/dev/null
    sed -i "s/^# *\(fr_FR.UTF-8\)/\1/;s/^# *\(en_US.UTF-8\)/\1/" /etc/locale.gen
    locale-gen >/dev/null; update-locale LANG=fr_FR.UTF-8
    apt-get upgrade -y -qq >/dev/null
    apt-get install -y -qq openjdk-21-jre-headless openssh-server sudo nftables \
      unattended-upgrades curl ca-certificates rsync less nano >/dev/null
    ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
  '
  msg_ok "Paquets installés ($(pct exec "$CTID" -- java -version 2>&1 | head -n1))."
}

configure_ssh() {
  msg_info "SSH : root par clé seulement, aucun mot de passe…"
  pct exec "$CTID" -- bash -c '
    cat > /etc/ssh/sshd_config.d/10-f4ioz.conf <<EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
EOF
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1
    systemctl restart ssh.service
  '
  msg_ok "SSH prêt."
}

show_summary() {
  local ip=${IP%/*}
  echo
  echo -e "${GREEN}${BOLD}  CT prête pour le site F4IOZ (Kotlin)${NC}"
  echo
  echo "  CT ID : $CTID   Hostname : $CT_HOST   IP : $ip"
  echo "  SSH   : ssh -i ~/.ssh/site_f4ioz_ed25519 root@${ip}"
  echo
  echo "  Envoie cette IP (et celle de la VM nginx) à Claude : il installe le site,"
  echo "  le pare-feu (seul nginx entre sur 8001/8002) et migre les articles."
  echo "  L'ancien site (192.168.0.9) n'est pas touché."
  echo
}

prompt_config
ensure_template
create_lxc
wait_network
install_packages
configure_ssh
show_summary
