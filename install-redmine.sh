#!/usr/bin/env bash
###############################################################################
# install-redmine.sh  (v2 — tailored to the crm server audit of 2026-10-02)
#
# Target : Ubuntu 24.04, existing nginx (sites-enabled) + certbot, no Docker
# Result : https://pm.netaport.com -> nginx -> Puma 127.0.0.1:3080 -> Redmine
#
# Adds   : /opt/redmine (app + private Ruby 3.4), user "redmine",
#          PostgreSQL 16 from Ubuntu repo (127.0.0.1:5432, new, dedicated),
#          redmine.service, ONE nginx vhost, ONE Let's Encrypt certificate.
# Never  : touches MariaDB, php-fpm, redis, n8n, pm2 apps, grafana, semaphore,
#          openbao, ufw rules, or any existing nginx vhost / certificate.
#          No existing package is upgraded and no existing service restarted
#          (the script aborts in pre-flight if apt would have to).
#
# Usage  : sudo PREFLIGHT_ONLY=1 bash install-redmine.sh   # checks only
#          sudo bash install-redmine.sh                    # install
# Re-run : safe (idempotent). Credentials: /root/.redmine-pm.netaport.com.env
###############################################################################
set -Eeuo pipefail

DOMAIN="${DOMAIN:-pm.netaport.com}"
REDMINE_VERSION="${REDMINE_VERSION:-7.0.2}"
RUBY_SERIES="${RUBY_SERIES:-3.4}"
APP_PORT="${APP_PORT:-3080}"
PUMA_WORKERS="${PUMA_WORKERS:-2}"
BUILD_JOBS="${BUILD_JOBS:-2}"            # of 4 cores — leaves room for live apps
MEMORY_MAX="${MEMORY_MAX:-1500M}"        # hard cap for the Redmine service
REDMINE_LANG="${REDMINE_LANG:-en}"
ENABLE_TLS="${ENABLE_TLS:-yes}"
LE_EMAIL="${LE_EMAIL:-}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
ALLOW_UPGRADES="${ALLOW_UPGRADES:-0}"

RM_USER="redmine"
RM_HOME="/opt/redmine"
RUBY_DIR="$RM_HOME/ruby"
APP_DIR="$RM_HOME/redmine-$REDMINE_VERSION"
CURRENT="$RM_HOME/current"
FILES_DIR="$RM_HOME/files"
DB_NAME="redmine"
DB_USER="redmine"
VHOST="/etc/nginx/sites-available/$DOMAIN"
VHOST_LINK="/etc/nginx/sites-enabled/$DOMAIN"
STATE="/root/.redmine-${DOMAIN}.env"
LOG="/var/log/redmine-install.log"

declare -A SHA256=(
  [7.0.2]="d45e6d4c373cc3c8d33f1f4d4a2ffae1e1adb18703160707467493de7b4be591"
  [6.1.5]="4b653d8863c012fdb226aedf6f8a18bdfa08d04625d15e8aafbbc3c4f6b70144"
)

PKGS=(build-essential autoconf patch bzip2 git curl ca-certificates
      libssl-dev libyaml-dev libffi-dev libreadline-dev zlib1g-dev
      libgdbm-dev libncurses-dev libgmp-dev libpq-dev
      postgresql imagemagick ghostscript)

# packages that must never be upgraded/restarted as a side effect of this run
CRITICAL='^(nginx|mariadb|mysql|php|redis|grafana|nodejs|certbot|python3-certbot|openssh|openbao|docker|containerd|systemd|libc6|linux-image)'

# ----------------------------------------------------------------- helpers ---
log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "line $LINENO: $BASH_COMMAND (log: $LOG)"' ERR

[[ $EUID -eq 0 ]] || die "Run as root."
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

rand_hex()  { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
port_busy() { [[ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]]; }
apt_run()   { env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
                apt-get -o DPkg::Lock::Timeout=300 "$@"; }

# run a command string as the redmine user: clean env, private Ruby, low priority
as_rm() {
  local dir=$1; shift
  runuser -u "$RM_USER" -- nice -n 10 ionice -c2 -n7 env -i \
    HOME="$RM_HOME" USER="$RM_USER" LANG=C.UTF-8 TMPDIR="$RM_HOME/tmp" \
    PATH="$RUBY_DIR/bin:/usr/local/bin:/usr/bin:/bin" \
    RAILS_ENV=production REDMINE_LANG="$REDMINE_LANG" \
    bash -c "cd '$dir' && $*"
}

pg()    { (cd / && runuser -u postgres -- psql -v ON_ERROR_STOP=1 -AtqX "$@"); }
pg_up() { id postgres >/dev/null 2>&1 && [[ "$(pg -c 'select 1' 2>/dev/null || true)" == "1" ]]; }
tcp_login_ok() {
  [[ "$(cd / && PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -p "$DB_PORT" -U "$DB_USER" \
        -d "$DB_NAME" -AtqXc 'select 1' 2>/dev/null || true)" == "1" ]]
}

# ------------------------------------------------------------------- state ---
# shellcheck disable=SC1090
if [[ -f $STATE ]]; then source "$STATE"; fi
DB_PASS="${DB_PASS:-$(rand_hex 24)}"
ADMIN_PASS="${ADMIN_PASS:-}"
save_state() {
  ( umask 077; printf "DB_PASS='%s'\nADMIN_PASS='%s'\n" "$DB_PASS" "$ADMIN_PASS" > "$STATE" )
}

###############################################################################
# 0. PRE-FLIGHT — read-only checks; nothing on the server is changed here
#    (only "apt-get update", which refreshes package lists)
###############################################################################
log "0/10 Pre-flight checks"

# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] \
  || die "This build is tailored to Ubuntu 24.04 (found: ${PRETTY_NAME:-unknown})."

MEM_AVAIL=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
DISK_AVAIL=$(df -Pm /opt | awk 'NR==2{print $4}')
echo "Memory available : ${MEM_AVAIL} MB (need >= 1500)"
echo "Disk free on /opt: ${DISK_AVAIL} MB (need >= 4000)"
(( MEM_AVAIL  >= 1500 )) || die "Not enough free memory for the Ruby build + Redmine."
(( DISK_AVAIL >= 4000 )) || die "Not enough free disk space."

systemctl is-active -q nginx || die "nginx is not running — this build expects the existing nginx."
nginx -t 2>/dev/null \
  || die "Existing nginx config already fails 'nginx -t'. Fix that first; nothing was changed."
[[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]] \
  || die "/etc/nginx/sites-available|sites-enabled not found."
CONFLICT="$(grep -RlE "server_name[^;]*[[:space:]]${DOMAIN//./\\.}[[:space:];]" \
              /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
            | grep -vxF -e "$VHOST_LINK" -e "$VHOST" || true)"
[[ -z $CONFLICT ]] || die "$DOMAIN is already defined in: $CONFLICT"
echo "nginx            : running, config valid, $DOMAIN not defined elsewhere"

if port_busy "$APP_PORT" && ! systemctl is-active -q redmine; then
  die "Port $APP_PORT is in use by another program. Re-run with APP_PORT=<free port>."
fi
echo "Puma port        : 127.0.0.1:$APP_PORT free"

if ! id postgres >/dev/null 2>&1 && port_busy 5432; then
  die "Port 5432 is in use but PostgreSQL is not installed — refusing to install over it."
fi
echo "PostgreSQL       : $(pg_up && echo 'already present, will be reused' || echo 'not installed, port 5432 free — will be installed')"

DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
MY_IPS="$(hostname -I 2>/dev/null || true) $(curl -s4 -m 5 https://ifconfig.me 2>/dev/null || true)"
TLS_OK=0
if [[ $ENABLE_TLS == no ]]; then
  echo "TLS              : disabled by ENABLE_TLS=no"
elif ! command -v certbot >/dev/null 2>&1 || [[ "$(certbot plugins 2>/dev/null || true)" != *nginx* ]]; then
  warn "certbot with the nginx plugin not found — site will be HTTP only."
elif [[ -z $DNS_IP || " $MY_IPS " != *" $DNS_IP "* ]]; then
  warn "$DOMAIN resolves to '${DNS_IP:-nothing}', not this server — TLS step will be skipped."
else
  TLS_OK=1
  echo "TLS              : certbot + nginx plugin present, DNS -> $DNS_IP OK"
fi

apt_run -qq update || warn "apt-get update reported problems (continuing with current lists)"
SIM="$(apt_run -s install --no-upgrade -y "${PKGS[@]}")" \
  || die "apt cannot resolve the required packages. Nothing was changed."
SIM_REMOVE="$(grep -E '^Remv ' <<<"$SIM" || true)"
SIM_UPGRADE="$(grep -E '^Inst [^ ]+ \[' <<<"$SIM" || true)"
SIM_NEW="$(grep -cE '^Inst [^ ]+ \(' <<<"$SIM" || true)"
echo "apt plan         : $SIM_NEW new packages, $(grep -c . <<<"$SIM_UPGRADE" || true) upgrades, $(grep -c . <<<"$SIM_REMOVE" || true) removals"
[[ -z $SIM_REMOVE ]] || die "apt would REMOVE packages — aborting:
$SIM_REMOVE"
if [[ -n $SIM_UPGRADE ]]; then
  echo "Library upgrades pulled in by the -dev packages:"
  sed 's/^/    /' <<<"$SIM_UPGRADE"
  CRIT_HIT="$(awk '{print $2}' <<<"$SIM_UPGRADE" | grep -E "$CRITICAL" || true)"
  if [[ -n $CRIT_HIT && $ALLOW_UPGRADES != 1 ]]; then
    die "apt would upgrade a package your running apps depend on (see list). Nothing was changed.
Upgrade it yourself in a maintenance window, or re-run with ALLOW_UPGRADES=1."
  fi
fi

echo
echo "Pre-flight passed."
if [[ $PREFLIGHT_ONLY == 1 ]]; then
  echo "PREFLIGHT_ONLY=1 — stopping here, nothing was installed."
  trap - ERR
  exit 0
fi
save_state

# ------------------------------------------------------------ 1. packages ---
log "1/10 Packages (new only — existing packages are not upgraded)"
apt_run -y -q install --no-upgrade "${PKGS[@]}"

# ---------------------------------------------------------------- 2. user ---
log "2/10 Service account + directories"
getent group "$RM_USER" >/dev/null || groupadd -r "$RM_USER"
id "$RM_USER" >/dev/null 2>&1 || useradd -r -g "$RM_USER" -d "$RM_HOME" -M -s /bin/bash "$RM_USER"
mkdir -p "$RM_HOME" "$FILES_DIR" "$RM_HOME/tmp"
chown "$RM_USER:$RM_USER" "$RM_HOME" "$FILES_DIR" "$RM_HOME/tmp"
chmod 750 "$RM_HOME"

# ---------------------------------------------------------- 3. PostgreSQL ---
log "3/10 PostgreSQL"
systemctl enable --now postgresql >/dev/null 2>&1 || true
for _ in {1..30}; do pg_up && break; sleep 1; done
pg_up || die "PostgreSQL is not answering on its local socket."
DB_PORT="$(pg -c 'show port')"
echo "PostgreSQL $(pg -c 'show server_version') on port $DB_PORT (listen: $(pg -c 'show listen_addresses'))"

pg <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  ELSE
    ALTER ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL
if [[ "$(pg -c "select 1 from pg_database where datname='${DB_NAME}'")" != "1" ]]; then
  pg -c "CREATE DATABASE ${DB_NAME} WITH ENCODING 'UTF8' TEMPLATE template0 OWNER ${DB_USER}"
fi

if ! tcp_login_ok; then
  HBA_FILE="$(pg -c 'show hba_file')"
  [[ "$(pg -c 'show password_encryption')" == scram-sha-256 ]] && HBA_METHOD=scram-sha-256 || HBA_METHOD=md5
  cp -a "$HBA_FILE" "$HBA_FILE.bak.$(date +%Y%m%d%H%M%S)"
  sed -i "1i host    ${DB_NAME}    ${DB_USER}    127.0.0.1/32    ${HBA_METHOD}" "$HBA_FILE"
  pg -c 'select pg_reload_conf()' >/dev/null
  sleep 1
  tcp_login_ok || die "Login as ${DB_USER}@127.0.0.1:${DB_PORT} failed. Check $HBA_FILE."
fi
echo "Database '${DB_NAME}' ready, TCP login verified."

# ---------------------------------------------------------------- 4. Ruby ---
log "4/10 Ruby $RUBY_SERIES.x, private copy in $RUBY_DIR (first run compiles: 10-20 min at low priority)"
if [[ ! -x $RUBY_DIR/bin/ruby ]] \
  || ! "$RUBY_DIR/bin/ruby" -e "exit(RUBY_VERSION.start_with?('${RUBY_SERIES}.') ? 0 : 1)"; then
  if [[ -d $RM_HOME/.ruby-build/.git ]]; then
    as_rm "$RM_HOME" "git -C .ruby-build pull -q --ff-only" || warn "ruby-build update failed, using existing checkout"
  else
    as_rm "$RM_HOME" "git clone -q --depth 1 https://github.com/rbenv/ruby-build.git .ruby-build"
  fi
  RUBY_FULL="$(as_rm "$RM_HOME" ".ruby-build/bin/ruby-build --definitions" \
    | grep -E "^${RUBY_SERIES//./\\.}\.[0-9]+$" | sort -V | tail -1 || true)"
  [[ -n $RUBY_FULL ]] || die "No ruby-build definition found for Ruby $RUBY_SERIES.x"
  echo "Building Ruby $RUBY_FULL with $BUILD_JOBS jobs ..."
  rm -rf "$RUBY_DIR"
  as_rm "$RM_HOME" "MAKE_OPTS=-j$BUILD_JOBS RUBY_CONFIGURE_OPTS=--disable-install-doc .ruby-build/bin/ruby-build $RUBY_FULL $RUBY_DIR"
fi
as_rm "$RM_HOME" "ruby -v"

# ------------------------------------------------------------- 5. Redmine ---
log "5/10 Redmine $REDMINE_VERSION -> $APP_DIR"
if [[ ! -f $APP_DIR/Gemfile ]]; then
  TGZ="$RM_HOME/tmp/redmine-$REDMINE_VERSION.tar.gz"
  curl -fsSL -o "$TGZ" "https://www.redmine.org/releases/redmine-$REDMINE_VERSION.tar.gz"
  WANT="${REDMINE_SHA256:-${SHA256[$REDMINE_VERSION]:-}}"
  [[ -n $WANT ]] || die "No SHA256 known for Redmine $REDMINE_VERSION — set REDMINE_SHA256=<sum>."
  echo "$WANT  $TGZ" | sha256sum -c - || die "SHA256 mismatch for $TGZ"
  tar -xzf "$TGZ" -C "$RM_HOME"
  rm -f "$TGZ"
fi

# keep the session secret when upgrading into a new release directory
if [[ -f $CURRENT/config/initializers/secret_token.rb && ! -f $APP_DIR/config/initializers/secret_token.rb ]]; then
  cp -a "$CURRENT/config/initializers/secret_token.rb" "$APP_DIR/config/initializers/secret_token.rb"
fi

cat > "$APP_DIR/config/database.yml" <<EOF
production:
  adapter: postgresql
  database: ${DB_NAME}
  host: 127.0.0.1
  port: ${DB_PORT}
  username: ${DB_USER}
  password: "${DB_PASS}"
  encoding: utf8
EOF
chmod 640 "$APP_DIR/config/database.yml"

if [[ ! -f $APP_DIR/config/configuration.yml ]]; then
  cat > "$APP_DIR/config/configuration.yml" <<EOF
# SMTP: copy the email_delivery block from config/configuration.yml.example,
#       then: systemctl restart redmine
default:
  attachments_storage_path: ${FILES_DIR}
EOF
fi

echo "gem 'puma'" > "$APP_DIR/Gemfile.local"

if (( PUMA_WORKERS > 0 )); then
  PUMA_CLUSTER="workers ${PUMA_WORKERS}
worker_timeout 120
preload_app!"
else
  PUMA_CLUSTER="# single mode (PUMA_WORKERS=0)"
fi
cat > "$APP_DIR/config/puma.rb" <<EOF
environment "production"
directory "${CURRENT}"
bind "tcp://127.0.0.1:${APP_PORT}"
threads 1, 5
${PUMA_CLUSTER}
EOF

mkdir -p "$APP_DIR/tmp/pdf" "$APP_DIR/public/assets" "$APP_DIR/log"
chown -R "$RM_USER:$RM_USER" "$APP_DIR"

# ---------------------------------------------------- 6. gems + database ---
log "6/10 Gems, schema, default data, assets"
as_rm "$APP_DIR" "bundle config set --local without 'development test'"
as_rm "$APP_DIR" "bundle install --jobs $BUILD_JOBS"
[[ -f $APP_DIR/config/initializers/secret_token.rb ]] || as_rm "$APP_DIR" "bundle exec rake generate_secret_token"
as_rm "$APP_DIR" "bundle exec rake db:migrate"

FIRST_INSTALL=0
if [[ "$(pg -d "$DB_NAME" -c 'select count(*) from trackers')" == "0" ]]; then
  as_rm "$APP_DIR" "bundle exec rake redmine:load_default_data"
  FIRST_INSTALL=1
fi
as_rm "$APP_DIR" "bundle exec rake redmine:plugins:migrate"
as_rm "$APP_DIR" "bundle exec rake assets:precompile"

ln -sfn "$APP_DIR" "$CURRENT"
chown -h "$RM_USER:$RM_USER" "$CURRENT"

# ------------------------------------------------------------- 7. systemd ---
log "7/10 systemd service + logrotate + helper"
cat > /etc/systemd/system/redmine.service <<EOF
[Unit]
Description=Redmine (Puma) - ${DOMAIN}
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${RM_USER}
Group=${RM_USER}
WorkingDirectory=${CURRENT}
Environment=RAILS_ENV=production
Environment=LANG=C.UTF-8
Environment=PATH=${RUBY_DIR}/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${RUBY_DIR}/bin/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=5
SyslogIdentifier=redmine
MemoryMax=${MEMORY_MAX}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/logrotate.d/redmine <<EOF
${RM_HOME}/redmine-*/log/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su ${RM_USER} ${RM_USER}
}
EOF

# redmine-run <cmd...>   e.g.  redmine-run bundle exec rake redmine:plugins:migrate
cat > /usr/local/bin/redmine-run <<EOF
#!/usr/bin/env bash
exec runuser -u ${RM_USER} -- env -i HOME=${RM_HOME} USER=${RM_USER} LANG=C.UTF-8 RAILS_ENV=production \\
  PATH=${RUBY_DIR}/bin:/usr/local/bin:/usr/bin:/bin \\
  bash -c 'cd ${CURRENT} && exec "\$@"' _ "\$@"
EOF
chmod 755 /usr/local/bin/redmine-run

systemctl daemon-reload
systemctl enable redmine >/dev/null 2>&1
systemctl restart redmine

echo -n "Waiting for Puma on 127.0.0.1:$APP_PORT "
UP=0
for _ in {1..60}; do
  if curl -fsS -o /dev/null "http://127.0.0.1:$APP_PORT/" 2>/dev/null; then UP=1; break; fi
  echo -n "."; sleep 2
done
echo
if [[ $UP -ne 1 ]]; then
  journalctl -u redmine -n 60 --no-pager || true
  die "Redmine did not answer on 127.0.0.1:$APP_PORT (nginx was NOT touched)."
fi

# ----------------------------------------------------- 8. nginx vhost ---
log "8/10 nginx vhost (new file only; rolled back if 'nginx -t' fails)"
PROTO=http
if [[ -f $VHOST ]] && grep -q 'ssl_certificate' "$VHOST"; then
  echo "$VHOST already has TLS configured — left untouched."
  PROTO=https
else
  cat > "$VHOST" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 100m;
    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_redirect off;
    }
}
EOF
  ln -sfn "$VHOST" "$VHOST_LINK"
  if ! nginx -t; then
    rm -f "$VHOST_LINK" "$VHOST"
    die "nginx rejected the new vhost — it was removed again; nginx keeps running with its previous config."
  fi
  systemctl reload nginx
  echo "nginx reloaded with $VHOST"
fi

# ----------------------------------------------------------------- 9. TLS ---
log "9/10 TLS (Let's Encrypt, this domain only)"
if [[ $PROTO == https ]]; then
  echo "Already on HTTPS."
elif [[ $TLS_OK -eq 1 ]]; then
  CB_ARGS=(--nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect)
  if ! compgen -G "/etc/letsencrypt/accounts/*/directory/*/regr.json" >/dev/null; then
    if [[ -n $LE_EMAIL ]]; then CB_ARGS+=(-m "$LE_EMAIL"); else CB_ARGS+=(--register-unsafely-without-email); fi
  fi
  if certbot "${CB_ARGS[@]}"; then
    PROTO=https
  else
    warn "certbot failed — site stays on HTTP (certbot reverts its own nginx edits). Re-run this script to retry."
  fi
else
  warn "TLS skipped (see pre-flight). Site is on HTTP."
fi

# ------------------------------------------------------ 10. app settings ---
log "10/10 Redmine settings"
if [[ $FIRST_INSTALL -eq 1 && -z $ADMIN_PASS ]]; then
  ADMIN_PASS="Rm$(rand_hex 10)"
  SET_ADMIN="$ADMIN_PASS"
  save_state
else
  SET_ADMIN=""
fi
BOOT="$RM_HOME/tmp/bootstrap.rb"
cat > "$BOOT" <<'EOF'
Setting.host_name = ENV.fetch('RM_DOMAIN')
Setting.protocol  = ENV.fetch('RM_PROTO')
if ENV['RM_ADMIN_PASS'].to_s != ''
  u = User.find_by(login: 'admin')
  u.password = u.password_confirmation = ENV['RM_ADMIN_PASS']
  u.must_change_passwd = false
  u.save!
end
EOF
chown "$RM_USER:$RM_USER" "$BOOT"
as_rm "$APP_DIR" "RM_DOMAIN=$DOMAIN RM_PROTO=$PROTO RM_ADMIN_PASS=$SET_ADMIN bundle exec rails runner $BOOT"
rm -f "$BOOT"

# ----------------------------------------------------------------- summary ---
cat <<EOF

===============================================================================
 Redmine $REDMINE_VERSION installed
-------------------------------------------------------------------------------
 URL          : ${PROTO}://${DOMAIN}/
 Admin login  : admin / ${ADMIN_PASS:-<unchanged — already set>}
 App          : ${CURRENT} -> ${APP_DIR}
 Attachments  : ${FILES_DIR}
 Ruby         : ${RUBY_DIR} ($("$RUBY_DIR/bin/ruby" -e 'print RUBY_VERSION'))
 Puma         : 127.0.0.1:${APP_PORT}  (systemctl status|restart redmine, cap ${MEMORY_MAX})
 Database     : postgresql://${DB_USER}@127.0.0.1:${DB_PORT}/${DB_NAME}
 nginx vhost  : ${VHOST}
 Credentials  : ${STATE}  (root only)
 Logs         : ${APP_DIR}/log/production.log | journalctl -u redmine | ${LOG}
-------------------------------------------------------------------------------
 Plugins : copy into ${CURRENT}/plugins, then
             redmine-run bundle install
             redmine-run bundle exec rake redmine:plugins:migrate
             systemctl restart redmine
 Backup  : sudo -u postgres pg_dump ${DB_NAME} | gzip > redmine.sql.gz   +   ${FILES_DIR}
 Remove  : systemctl disable --now redmine; rm -f ${VHOST_LINK} ${VHOST}
           /etc/systemd/system/redmine.service /etc/logrotate.d/redmine /usr/local/bin/redmine-run
           nginx -t && systemctl reload nginx; rm -rf ${RM_HOME}; userdel ${RM_USER}
           sudo -u postgres dropdb ${DB_NAME}; sudo -u postgres dropuser ${DB_USER}
===============================================================================
EOF
