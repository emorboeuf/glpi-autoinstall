#!/usr/bin/env bash
# =============================================================================
#  install-glpi.sh — Installation automatique de GLPI sur Debian 12 / 13
#  Stack : Apache2 + PHP-FPM + MariaDB
#  Auteur : Evan Morboeuf
#
#  Usage :
#    sudo bash install-glpi.sh          -> mode interactif (pose des questions)
#    sudo bash install-glpi.sh --yes    -> mode automatique (valeurs par défaut)
#    sudo bash install-glpi.sh --help   -> aide
#
#  Version de GLPI choisie automatiquement selon Debian :
#    Debian 12 (PHP 8.2) -> GLPI 11.x
#    Debian 13 (PHP 8.4) -> GLPI 12.x (ou 11.x au choix)
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
GLPI_DIR="/var/www/glpi"
LOG_FILE="/var/log/glpi-install.log"
INFO_FILE="/root/glpi-install-info.txt"
GITHUB_API="https://api.github.com/repos/glpi-project/glpi/releases?per_page=100"

# --- Valeurs par défaut (modifiables par variables d'environnement) ---------
GLPI_VERSION="${GLPI_VERSION:-auto}"
DB_NAME="${DB_NAME:-glpi}"
DB_USER="${DB_USER:-glpi}"
DB_PASS="${DB_PASS:-}"
SERVER_NAME="${SERVER_NAME:-}"
GLPI_LANG="${GLPI_LANG:-fr_FR}"
PHP_TZ="${PHP_TZ:-}"
ENABLE_HTTPS="${ENABLE_HTTPS:-n}"
SECURE_LAYOUT="${SECURE_LAYOUT:-o}"
FORCE_REINSTALL="${FORCE_REINSTALL:-n}"
ASSUME_YES=0
DB_PASS_GENERATED=0
STEP=0
TOTAL_STEPS=8
TMP_DIR=""

# --- Affichage ---------------------------------------------------------------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1;34m'; W=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; W=""; N=""
fi
info() { echo "${B}[INFO]${N} $*"; }
ok()   { echo "${G}[ OK ]${N} $*"; }
warn() { echo "${Y}[WARN]${N} $*" >&2; }
die()  { echo "${R}[ERREUR]${N} $*" >&2; exit 1; }
step() { STEP=$((STEP + 1)); echo; echo "${B}==> [${STEP}/${TOTAL_STEPS}] $*${N}"; }

# Exécute une commande en envoyant sa sortie dans le journal
run() { echo "+ $*" >>"$LOG_FILE"; "$@" >>"$LOG_FILE" 2>&1; }

on_error() {
  local line=$1 cmd=$2
  echo >&2
  echo "${R}[ERREUR]${N} Échec à la ligne ${line} : ${cmd}" >&2
  if [[ -f $LOG_FILE ]]; then
    echo "${Y}--- 15 dernières lignes de ${LOG_FILE} ---${N}" >&2
    tail -n 15 "$LOG_FILE" >&2 || true
  fi
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap '[[ -n $TMP_DIR ]] && rm -rf "$TMP_DIR"' EXIT

usage() {
  cat <<EOF
install-glpi.sh v${SCRIPT_VERSION} — installe GLPI (Apache, PHP-FPM, MariaDB) sur Debian 12/13.

Usage : sudo bash install-glpi.sh [--yes] [--help]

  -y, --yes    Aucune question : utilise les valeurs par défaut
               (ou celles passées en variables d'environnement).
  -h, --help   Affiche cette aide.

Variables d'environnement (facultatives) :
  GLPI_VERSION     ex. 12.0.2   (défaut : dernière version compatible)
  DB_NAME          défaut : glpi
  DB_USER          défaut : glpi
  DB_PASS          défaut : généré aléatoirement
  SERVER_NAME      défaut : adresse IP de la machine
  GLPI_LANG        défaut : fr_FR
  PHP_TZ           défaut : fuseau du système, sinon Europe/Paris
  ENABLE_HTTPS     o/n, défaut : n (certificat auto-signé si o)
  SECURE_LAYOUT    o/n, défaut : o (config et données hors du dossier web)
  FORCE_REINSTALL  o/n, défaut : n (écrase une installation existante)

Exemple :
  sudo DB_PASS='MonMotDePasse' SERVER_NAME=glpi.local bash install-glpi.sh --yes
EOF
}

# --- Questions (lues sur /dev/tty pour fonctionner aussi via "curl | bash") --
has_tty() { [[ $ASSUME_YES -eq 0 ]] && { : </dev/tty; } 2>/dev/null; }

# ask VARIABLE "Question" "valeur par défaut"
ask() {
  local __var=$1 __q=$2 __def=${3:-} __ans=""
  if has_tty; then
    read -r -p "  ${__q} [${__def}] : " __ans </dev/tty || true
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ask_yn VARIABLE "Question" o|n  -> la variable vaut o ou n
ask_yn() {
  local __var=$1 __yn
  ask __yn "$2 (o/n)" "$3"
  case "${__yn,,}" in
    o|oui|y|yes) printf -v "$__var" 'o' ;;
    *)           printf -v "$__var" 'n' ;;
  esac
}

gen_password() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

password_ok() {
  local p=$1
  case $p in *[\'\"\\\`\$\ ]*) warn "Caractères interdits : ' \" \\ \` \$ et espace."; return 1 ;; esac
  [[ ${#p} -ge 8 ]] || { warn "8 caractères minimum."; return 1; }
}

ask_password() {
  local p1 p2
  if [[ -n $DB_PASS ]]; then
    password_ok "$DB_PASS" || die "Le mot de passe fourni dans DB_PASS est refusé."
    return
  fi
  if ! has_tty; then
    DB_PASS=$(gen_password); DB_PASS_GENERATED=1; return
  fi
  while true; do
    read -r -s -p "  Mot de passe de l'utilisateur SQL (Entrée = généré automatiquement) : " p1 </dev/tty || true
    echo >&2
    if [[ -z $p1 ]]; then DB_PASS=$(gen_password); DB_PASS_GENERATED=1; return; fi
    password_ok "$p1" || continue
    read -r -s -p "  Confirmer le mot de passe : " p2 </dev/tty || true
    echo >&2
    if [[ $p1 == "$p2" ]]; then DB_PASS=$p1; return; fi
    warn "Les deux mots de passe ne correspondent pas."
  done
}

# --- Arguments ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

# =============================================================================
#  Vérifications
# =============================================================================
echo "${W}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   Installation automatique de GLPI — v${SCRIPT_VERSION}  ║"
echo "  ╚══════════════════════════════════════════════╝${N}"

[[ $EUID -eq 0 ]] || die "Ce script doit être lancé en root : sudo bash $0"
[[ -r /etc/os-release ]] || die "Impossible de détecter le système (/etc/os-release absent)."
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == "debian" ]] || die "Ce script est prévu pour Debian (détecté : ${PRETTY_NAME:-inconnu})."

DEB_MAJOR=${VERSION_ID:-0}
DEB_MAJOR=${DEB_MAJOR%%.*}
case $DEB_MAJOR in
  12) COMPAT_BRANCHES=(11);    DEFAULT_BRANCH=11 ;;
  13) COMPAT_BRANCHES=(12 11); DEFAULT_BRANCH=12 ;;
  *)  die "Debian ${VERSION_ID:-inconnue} non prise en charge : Debian 12 ou 13 requise." ;;
esac
ok "Système : ${PRETTY_NAME}"

: >"$LOG_FILE"
chmod 600 "$LOG_FILE"
export DEBIAN_FRONTEND=noninteractive

info "Préparation (curl, jq, certificats)…"
run apt-get update || die "apt-get update a échoué : la machine a-t-elle accès au réseau ?"
run apt-get install -y curl jq ca-certificates

info "Récupération de la liste des versions de GLPI sur GitHub…"
ALL_VERSIONS=$(curl -fsSL --max-time 30 "$GITHUB_API" \
  | jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name') \
  || die "Impossible de joindre l'API GitHub (réseau, proxy ou limite de requêtes)."

latest_of_branch() { { grep -E "^$1\.[0-9]+\.[0-9]+$" <<<"$ALL_VERSIONS" || true; } | sort -V | tail -n1; }

# =============================================================================
#  Questions
# =============================================================================
echo
echo "${W}Configuration${N} (Entrée = valeur proposée entre crochets)"
echo
echo "  Versions de GLPI compatibles avec Debian ${DEB_MAJOR} :"
for b in "${COMPAT_BRANCHES[@]}"; do
  v=$(latest_of_branch "$b")
  [[ -n $v ]] && echo "    - ${v}  (dernière ${b}.x)"
done
echo

[[ $GLPI_VERSION == "auto" ]] && GLPI_VERSION=$(latest_of_branch "$DEFAULT_BRANCH")
[[ -n $GLPI_VERSION ]] || die "Aucune version ${DEFAULT_BRANCH}.x trouvée sur GitHub."

while true; do
  ask GLPI_VERSION "Version de GLPI à installer" "$GLPI_VERSION"
  branch=${GLPI_VERSION%%.*}
  if ! grep -qx "$GLPI_VERSION" <<<"$ALL_VERSIONS"; then
    warn "Version ${GLPI_VERSION} introuvable parmi les versions stables publiées."
  elif [[ " ${COMPAT_BRANCHES[*]} " != *" ${branch} "* ]]; then
    warn "GLPI ${branch}.x n'est pas compatible avec la version de PHP de Debian ${DEB_MAJOR}."
  else
    break
  fi
  has_tty || die "Version invalide : ${GLPI_VERSION}"
  GLPI_VERSION=$(latest_of_branch "$DEFAULT_BRANCH")
done

default_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n $SERVER_NAME ]] || SERVER_NAME=${default_ip:-$(hostname)}
ask SERVER_NAME "Nom ou IP d'accès au serveur (ServerName Apache)" "$SERVER_NAME"

while true; do
  ask DB_NAME "Nom de la base de données" "$DB_NAME"
  ask DB_USER "Utilisateur SQL de GLPI" "$DB_USER"
  [[ $DB_NAME =~ ^[A-Za-z0-9_]+$ && $DB_USER =~ ^[A-Za-z0-9_]+$ ]] && break
  warn "Base et utilisateur : lettres, chiffres et _ uniquement."
  has_tty || die "Nom de base ou d'utilisateur invalide."
done
ask_password

while true; do
  ask GLPI_LANG "Langue par défaut de GLPI" "$GLPI_LANG"
  [[ $GLPI_LANG =~ ^[a-z]{2}_[A-Z]{2}$ ]] && break
  warn "Format attendu : fr_FR, en_GB, de_DE…"
  has_tty || die "Langue invalide : ${GLPI_LANG}"
  GLPI_LANG="fr_FR"
done

if [[ -z $PHP_TZ ]]; then
  PHP_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -n $PHP_TZ && $PHP_TZ != "Etc/UTC" && $PHP_TZ != "UTC" ]] || PHP_TZ="Europe/Paris"
fi
while true; do
  ask PHP_TZ "Fuseau horaire" "$PHP_TZ"
  [[ -f /usr/share/zoneinfo/$PHP_TZ ]] && break
  warn "Fuseau horaire inconnu : ${PHP_TZ}"
  has_tty || die "Fuseau horaire invalide."
  PHP_TZ="Europe/Paris"
done

ask_yn ENABLE_HTTPS  "Activer HTTPS avec un certificat auto-signé ?" "$ENABLE_HTTPS"
ask_yn SECURE_LAYOUT "Sécuriser l'arborescence (config et données hors de /var/www) ?" "$SECURE_LAYOUT"

# --- Installation déjà présente ? -------------------------------------------
EXISTING=""
[[ -e $GLPI_DIR ]] && EXISTING+="  - le dossier ${GLPI_DIR}"$'\n'
[[ -e /etc/glpi || -e /var/lib/glpi ]] && EXISTING+="  - les dossiers /etc/glpi et/ou /var/lib/glpi"$'\n'
if command -v mariadb >/dev/null 2>&1 && systemctl is-active --quiet mariadb \
   && [[ -n $(mariadb -N -e "SHOW DATABASES LIKE '${DB_NAME}'" 2>/dev/null) ]]; then
  EXISTING+="  - la base de données ${DB_NAME}"$'\n'
fi
if [[ -n $EXISTING ]]; then
  echo
  warn "Une installation de GLPI existe déjà :"
  printf '%s' "$EXISTING" >&2
  ask_yn FORCE_REINSTALL "TOUT SUPPRIMER (fichiers ET base) puis réinstaller ?" "$FORCE_REINSTALL"
  [[ $FORCE_REINSTALL == "o" ]] || die "Installation annulée : rien n'a été modifié."
fi

# --- Récapitulatif ------------------------------------------------------------
PROTO="http"; [[ $ENABLE_HTTPS == "o" ]] && PROTO="https"
echo
echo "${W}Récapitulatif${N}"
echo "  GLPI ............ ${GLPI_VERSION}"
echo "  URL ............. ${PROTO}://${SERVER_NAME}/"
echo "  Base / user SQL . ${DB_NAME} / ${DB_USER}"
echo "  Mot de passe SQL  $([[ $DB_PASS_GENERATED -eq 1 ]] && echo 'généré (affiché à la fin)' || echo 'saisi')"
echo "  Langue .......... ${GLPI_LANG}"
echo "  Fuseau horaire .. ${PHP_TZ}"
echo "  HTTPS ........... ${ENABLE_HTTPS}"
echo "  Arbo sécurisée .. ${SECURE_LAYOUT}"
[[ -n $EXISTING ]] && echo "  ${R}Réinstallation : l'installation existante sera supprimée${N}"
echo
ask_yn CONFIRM "Lancer l'installation ?" "o"
[[ $CONFIRM == "o" ]] || die "Installation annulée."

# =============================================================================
#  1. Paquets
# =============================================================================
step "Installation d'Apache, MariaDB et PHP (quelques minutes)…"
run apt-get install -y apache2 mariadb-server php-cli php-fpm cron openssl tar
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

case ${GLPI_VERSION%%.*} in
  12) PHP_MIN="8.3" ;;
  11) PHP_MIN="8.2" ;;
  *)  PHP_MIN="8.2" ;;
esac
dpkg --compare-versions "$PHPV" ge "$PHP_MIN" \
  || die "PHP ${PHPV} installé, mais GLPI ${GLPI_VERSION} demande PHP ${PHP_MIN} minimum."

PHP_PKGS=()
for ext in mysql curl gd intl mbstring xml zip bz2 ldap bcmath opcache; do
  if apt-cache show "php${PHPV}-${ext}" >/dev/null 2>&1; then
    PHP_PKGS+=("php${PHPV}-${ext}")
  else
    warn "Paquet php${PHPV}-${ext} introuvable, ignoré."
  fi
done
apt-cache show php-apcu >/dev/null 2>&1 && PHP_PKGS+=(php-apcu)
run apt-get install -y "${PHP_PKGS[@]}"
ok "PHP ${PHPV}, Apache et MariaDB installés."

# =============================================================================
#  2. Base de données
# =============================================================================
step "Configuration de MariaDB…"
run systemctl enable --now mariadb

if [[ $FORCE_REINSTALL == "o" ]]; then
  mariadb -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" >>"$LOG_FILE" 2>&1
fi

mariadb >>"$LOG_FILE" 2>&1 <<SQL
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Fuseaux horaires dans MariaDB (recommandé par GLPI)
if command -v mariadb-tzinfo-to-sql >/dev/null 2>&1; then TZ2SQL=mariadb-tzinfo-to-sql; else TZ2SQL=mysql_tzinfo_to_sql; fi
if "$TZ2SQL" /usr/share/zoneinfo 2>>"$LOG_FILE" | mariadb mysql >>"$LOG_FILE" 2>&1; then
  mariadb -e "GRANT SELECT ON mysql.time_zone_name TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" >>"$LOG_FILE" 2>&1
  TZ_OK=1
else
  warn "Import des fuseaux horaires MariaDB impossible (non bloquant)."
  TZ_OK=0
fi
ok "Base ${DB_NAME} et utilisateur ${DB_USER} prêts."

# =============================================================================
#  3. Téléchargement de GLPI
# =============================================================================
step "Téléchargement de GLPI ${GLPI_VERSION}…"
TMP_DIR=$(mktemp -d)
URL="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
run curl -fL --retry 3 --max-time 600 -o "${TMP_DIR}/glpi.tgz" "$URL"

if [[ $FORCE_REINSTALL == "o" ]]; then
  rm -rf "$GLPI_DIR" /etc/glpi /var/lib/glpi /var/log/glpi
fi
run tar -xzf "${TMP_DIR}/glpi.tgz" -C /var/www/
[[ -f ${GLPI_DIR}/bin/console ]] || die "Archive GLPI inattendue : ${GLPI_DIR}/bin/console absent."
ok "GLPI extrait dans ${GLPI_DIR}."

# =============================================================================
#  4. Arborescence et permissions
# =============================================================================
step "Arborescence et permissions…"
chown -R root:root "$GLPI_DIR"
chmod -R u=rwX,go=rX "$GLPI_DIR"
mkdir -p "${GLPI_DIR}/marketplace"
chown -R www-data:www-data "${GLPI_DIR}/marketplace"

if [[ $SECURE_LAYOUT == "o" ]]; then
  mkdir -p /etc/glpi /var/lib/glpi /var/log/glpi
  cp -a "${GLPI_DIR}/config/." /etc/glpi/
  cp -a "${GLPI_DIR}/files/." /var/lib/glpi/
  rm -rf "${GLPI_DIR}/config" "${GLPI_DIR}/files"

  cat >"${GLPI_DIR}/inc/downstream.php" <<'PHP'
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
PHP
  cat >/etc/glpi/local_define.php <<'PHP'
<?php
define('GLPI_VAR_DIR', '/var/lib/glpi');
define('GLPI_LOG_DIR', '/var/log/glpi');
PHP
  chown -R www-data:www-data /etc/glpi /var/lib/glpi /var/log/glpi
  chmod 750 /etc/glpi /var/lib/glpi /var/log/glpi
  ok "Config : /etc/glpi — Données : /var/lib/glpi — Journaux : /var/log/glpi"
else
  chown -R www-data:www-data "${GLPI_DIR}/config" "${GLPI_DIR}/files"
  ok "Config et données dans ${GLPI_DIR} (arborescence standard)."
fi

# =============================================================================
#  5. PHP
# =============================================================================
step "Configuration de PHP ${PHPV}…"
COOKIE_SECURE="Off"; [[ $ENABLE_HTTPS == "o" ]] && COOKIE_SECURE="On"
cat >"/etc/php/${PHPV}/fpm/conf.d/99-glpi.ini" <<INI
; Réglages pour GLPI (généré par install-glpi.sh)
memory_limit = 256M
upload_max_filesize = 20M
post_max_size = 20M
max_execution_time = 600
date.timezone = ${PHP_TZ}
session.cookie_httponly = On
session.cookie_samesite = Lax
session.cookie_secure = ${COOKIE_SECURE}
INI
cat >"/etc/php/${PHPV}/cli/conf.d/99-glpi.ini" <<INI
; Réglages pour GLPI (généré par install-glpi.sh)
date.timezone = ${PHP_TZ}
INI
run systemctl enable php"${PHPV}"-fpm
run systemctl restart php"${PHPV}"-fpm
ok "php.ini ajusté (fuseau ${PHP_TZ}, cookies sécurisés)."

# =============================================================================
#  6. Apache
# =============================================================================
step "Configuration d'Apache…"
run a2enmod rewrite proxy_fcgi setenvif headers
run a2enconf "php${PHPV}-fpm"
run a2dissite 000-default

VHOST=/etc/apache2/sites-available/glpi.conf
cat >"$VHOST" <<APACHE
# GLPI — généré par install-glpi.sh
<Directory ${GLPI_DIR}/public>
    Require all granted
    RewriteEngine On
    # Transmet l'en-tête Authorization (API, CalDAV…)
    RewriteCond %{HTTP:Authorization} ^(.+)\$
    RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
    # Toutes les requêtes passent par index.php
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteRule ^(.*)\$ index.php [QSA,L]
</Directory>
APACHE

if [[ $ENABLE_HTTPS == "o" ]]; then
  run a2enmod ssl
  if [[ $SERVER_NAME =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then SAN="IP:${SERVER_NAME}"; else SAN="DNS:${SERVER_NAME}"; fi
  run openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/private/glpi.key -out /etc/ssl/certs/glpi.crt \
    -subj "/CN=${SERVER_NAME}" -addext "subjectAltName=${SAN}"
  chmod 600 /etc/ssl/private/glpi.key
  cat >>"$VHOST" <<APACHE

<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    Redirect permanent / https://${SERVER_NAME}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${SERVER_NAME}
    DocumentRoot ${GLPI_DIR}/public
    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/glpi.crt
    SSLCertificateKeyFile /etc/ssl/private/glpi.key
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
APACHE
else
  cat >>"$VHOST" <<APACHE

<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    DocumentRoot ${GLPI_DIR}/public
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
APACHE
fi

run a2ensite glpi
run apache2ctl configtest
run systemctl enable apache2
run systemctl restart apache2
ok "Site Apache glpi activé."

# =============================================================================
#  7. Installation de GLPI (création des tables)
# =============================================================================
step "Installation de GLPI en base de données (1 à 3 minutes)…"
run runuser -u www-data -- php "${GLPI_DIR}/bin/console" db:install \
  --db-host=localhost \
  --db-name="$DB_NAME" \
  --db-user="$DB_USER" \
  --db-password="$DB_PASS" \
  --default-language="$GLPI_LANG" \
  --no-interaction
if [[ $TZ_OK -eq 1 ]]; then
  run runuser -u www-data -- php "${GLPI_DIR}/bin/console" db:enable_timezones --no-interaction \
    || warn "Activation des fuseaux horaires GLPI impossible (non bloquant)."
fi
ok "Base GLPI créée."

# =============================================================================
#  8. Finalisation
# =============================================================================
step "Finalisation…"
rm -f "${GLPI_DIR}/install/install.php"

cat >/etc/cron.d/glpi <<CRON
# Actions automatiques de GLPI — généré par install-glpi.sh
* * * * * www-data /usr/bin/php ${GLPI_DIR}/front/cron.php >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/glpi
run systemctl enable --now cron

cat >"$INFO_FILE" <<INFO
Installation GLPI — $(date '+%d/%m/%Y %H:%M')
  Version ........... ${GLPI_VERSION}
  URL ............... ${PROTO}://${SERVER_NAME}/
  Base de données ... ${DB_NAME}
  Utilisateur SQL ... ${DB_USER}
  Mot de passe SQL .. ${DB_PASS}
  Dossier GLPI ...... ${GLPI_DIR}
  Journal ........... ${LOG_FILE}
Comptes GLPI par défaut (À CHANGER) :
  glpi/glpi (super-admin), tech/tech, normal/normal, post-only/postonly
INFO
chmod 600 "$INFO_FILE"

echo
echo "${G}══════════════════════════════════════════════════════${N}"
echo "${G}  GLPI ${GLPI_VERSION} est installé !${N}"
echo "${G}══════════════════════════════════════════════════════${N}"
echo "  Accès        : ${W}${PROTO}://${SERVER_NAME}/${N}"
echo "  Connexion    : glpi / glpi"
[[ $DB_PASS_GENERATED -eq 1 ]] && echo "  Mot de passe SQL généré : ${W}${DB_PASS}${N}"
echo "  Récapitulatif enregistré dans ${INFO_FILE} (lisible par root seulement)"
echo
echo "${Y}  À faire maintenant :${N}"
echo "   1. Changer les mots de passe des comptes glpi, tech, normal et post-only"
echo "      (ou désactiver ceux qui ne servent pas)."
[[ $ENABLE_HTTPS == "o" ]] && echo "   2. Le certificat est auto-signé : le navigateur affichera un avertissement."
echo
