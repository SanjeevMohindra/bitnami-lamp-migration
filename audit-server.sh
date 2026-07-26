#!/bin/bash
#
# audit-server.sh — Inventory server-level configuration that a per-site bundle
#                   does NOT carry, and emit it as a migration checklist.
#
# Usage:  sudo ./audit-server.sh              # write server-parity.md to the cwd
#         sudo ./audit-server.sh -o FILE      # write somewhere else ("-" = stdout)
#
# Read-only: it changes nothing. Run it on the OLD server.
#
# export-site.sh calls this automatically and drops the output into every
# bundle's reference/ directory, so each bundle carries a record of the server it
# came from.
#
# Why this exists: export-site.sh moves a *site* — files, database, vhost. It
# does not move HTTP/2, PHP ini tuning, MariaDB tuning, Redis, cron, or firewall
# state. Those are server-wide, they have to be redone by hand on the new box,
# and they are exactly what gets forgotten.
#
set -uo pipefail

OUT="server-parity.md"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) OUT="${2:-}"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed -n '2,20p' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)  echo "Usage: sudo $0 [-o FILE]"; exit 1 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
# Locate the source stack — detected, never assumed.
#
# Bitnami ships in several shapes: cloud marketplace images (Lightsail, EC2,
# Azure, GCP) install under /opt/bitnami, while the standalone native installer
# uses a versioned directory such as /opt/lampstack-8.2.12-0, or ~/stack. Apache
# is `apache` in some versions and `apache2` in others. Find the stack, then work
# out from it; fall back to a stock distro layout if there is no Bitnami stack.
# =============================================================================

STACK_ROOTS=()
for d in /opt/bitnami /opt/lampstack-* /opt/*stack-* "${HOME:-/root}/stack" /home/*/stack; do
    [ -d "$d" ] || continue
    case " ${STACK_ROOTS[*]-} " in *" $d "*) continue ;; esac
    STACK_ROOTS+=("$d")
done

# stack_path <relative> [relative...] — first path that exists under any stack root
stack_path() {
    local r rel
    for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
        for rel in "$@"; do
            [ -e "${r}/${rel}" ] && { echo "${r}/${rel}"; return 0; }
        done
    done
    return 1
}

APACHE_ROOT=$(stack_path apache apache2 2>/dev/null || true)
if [ -z "$APACHE_ROOT" ]; then
    for d in /etc/apache2 /etc/httpd; do
        [ -d "$d" ] && { APACHE_ROOT="$d"; break; }
    done
fi

HTTPD=""
[ -n "$APACHE_ROOT" ] && [ -x "${APACHE_ROOT}/bin/httpd" ] && HTTPD="${APACHE_ROOT}/bin/httpd"
if [ -z "$HTTPD" ]; then
    for c in /usr/sbin/apache2ctl /usr/sbin/httpd; do
        [ -x "$c" ] && { HTTPD="$c"; break; }
    done
fi
[ -z "$HTTPD" ] && have apache2ctl && HTTPD=$(command -v apache2ctl)
[ -z "$HTTPD" ] && have apachectl  && HTTPD=$(command -v apachectl)

APACHE_CONF_DIR=""
if [ -n "$APACHE_ROOT" ]; then
    for d in "${APACHE_ROOT}/conf" "${APACHE_ROOT}"; do
        [ -d "$d" ] && { APACHE_CONF_DIR="$d"; break; }
    done
fi

PHP_BIN=$(stack_path php/bin/php 2>/dev/null || true)
[ -z "$PHP_BIN" ] && [ -x /usr/bin/php ] && PHP_BIN=/usr/bin/php
[ -z "$PHP_BIN" ] && have php && PHP_BIN=$(command -v php)

PHP_INI=""
[ -n "$PHP_BIN" ] && PHP_INI=$("$PHP_BIN" -i 2>/dev/null \
    | awk -F'=> ' '/^Loaded Configuration File/ {print $2}' | tr -d ' ')

MY_CNF=$(stack_path mariadb/conf/my.cnf mysql/conf/my.cnf 2>/dev/null || true)
if [ -z "$MY_CNF" ]; then
    for f in /etc/mysql/my.cnf /etc/my.cnf; do
        [ -r "$f" ] && { MY_CNF="$f"; break; }
    done
fi

MYSQL_BIN=$(stack_path mariadb/bin/mysql mysql/bin/mysql 2>/dev/null || true)
if [ -z "$MYSQL_BIN" ]; then
    for c in /usr/bin/mysql /usr/bin/mariadb; do
        [ -x "$c" ] && { MYSQL_BIN="$c"; break; }
    done
fi

REDIS_CONF=$(stack_path redis/etc/redis.conf 2>/dev/null || true)
[ -z "$REDIS_CONF" ] && [ -r /etc/redis/redis.conf ] && REDIS_CONF=/etc/redis/redis.conf

MODS=""
[ -n "$HTTPD" ] && MODS=$("$HTTPD" -M 2>/dev/null || true)

# =============================================================================
# Gather everything into variables FIRST.
# The report at the bottom is then a plain template with no logic in it.
# =============================================================================

# conf_grep <extended-regex> — search the Apache config tree, skipping comments
#                              and our own vhost backup directories
conf_grep() {
    [ -n "$APACHE_CONF_DIR" ] || return 0
    grep -rhE "$1" "$APACHE_CONF_DIR" 2>/dev/null \
        | grep -vE '^[[:space:]]*#' | grep -v '/backup-' \
        | sed 's/^[[:space:]]*//' | sort -u
}

# ini_value <key> — the value set in the loaded php.ini (empty = using default)
ini_value() {
    [ -n "$PHP_INI" ] && [ -r "$PHP_INI" ] || return 0
    grep -E "^[[:space:]]*${1}[[:space:]]*=" "$PHP_INI" 2>/dev/null | tail -1 \
        | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# row <setting> <default> <note> — one checklist row; bold when it differs
row() {
    local setting="$1" default="$2" note="$3" current
    current=$(ini_value "$setting")
    if [ -z "$current" ]; then
        printf '| `%s` | _not set (default `%s`)_ | `%s` | %s |\n' \
               "$setting" "$default" "$default" "$note"
    elif [ "$current" != "$default" ]; then
        printf '| `%s` | **%s** | `%s` | %s |\n' "$setting" "$current" "$default" "$note"
    else
        printf '| `%s` | %s | `%s` | %s |\n' "$setting" "$current" "$default" "$note"
    fi
}

# --- HTTP/2 ------------------------------------------------------------------
PROTOCOLS=$(conf_grep '^[[:space:]]*Protocols[[:space:]]' | head -5)
MPM=$(echo "$MODS" | grep -oE 'mpm_[a-z]+' | head -1)
[ -z "$MPM" ] && MPM="unknown"
HTTP2_LOADED="no"; echo "$MODS" | grep -q 'http2_module' && HTTP2_LOADED="yes"
HTTP2_IN_USE="no"
{ [ -n "$PROTOCOLS" ] || [ "$HTTP2_LOADED" = "yes" ]; } && HTTP2_IN_USE="yes"

# --- Compression -------------------------------------------------------------
DEFLATE_LOADED="no"; echo "$MODS" | grep -q 'deflate_module' && DEFLATE_LOADED="yes"
BROTLI_LOADED="no";  echo "$MODS" | grep -q 'brotli_module'  && BROTLI_LOADED="yes"
COMPRESSION_CONF=$(conf_grep '^[[:space:]]*(AddOutputFilterByType|SetOutputFilter|BrotliCompressionQuality)' | head -20)

# --- PHP ---------------------------------------------------------------------
PHP_VERSION_FULL=""
[ -n "$PHP_BIN" ] && PHP_VERSION_FULL=$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)
PHP_MODULES=""
[ -n "$PHP_BIN" ] && PHP_MODULES=$("$PHP_BIN" -m 2>/dev/null \
    | grep -v '^\[' | grep -v '^$' | sort | tr '\n' ' ')

# PHP-FPM pool sizing. Bitnami runs PHP-FPM; if the target moves to mpm_event +
# PHP-FPM for HTTP/2 it gets a *stock* pool config, and pm.max_children is the
# setting that decides whether the box survives a traffic spike or OOMs.
FPM_CONF=$(stack_path php/etc/php-fpm.d/www.conf php/etc/php-fpm.conf 2>/dev/null || true)
if [ -z "$FPM_CONF" ]; then
    for f in /etc/php/*/fpm/pool.d/www.conf /etc/php-fpm.d/www.conf; do
        [ -r "$f" ] && { FPM_CONF="$f"; break; }
    done
fi
FPM_SETTINGS=""
[ -n "$FPM_CONF" ] && FPM_SETTINGS=$(grep -hE '^[[:space:]]*(pm|listen|user|group)[.[:space:]=]' "$FPM_CONF" 2>/dev/null | sed 's/^[[:space:]]*//')
[ -z "$FPM_SETTINGS" ] && FPM_SETTINGS="(no PHP-FPM pool config found)"

# What a worker actually costs, measured rather than guessed: average RSS across
# running pool workers. RSS over-counts shared memory (opcache is shared by every
# child), so treat it as a ceiling, not a true per-worker figure.
FPM_WORKERS=$(ps -eo rss,comm 2>/dev/null | awk '$2 ~ /php-fpm/ {n++; s+=$1} END {if (n) printf "%d workers, avg RSS %.0f MB (shared memory counted in each — real marginal cost is lower)", n, s/n/1024; else print "(none running)"}')

PHP_ROWS=$(
    row memory_limit                    "128M"  "Set it in the new php.ini *and* the FPM pool if you move to PHP-FPM"
    row upload_max_filesize             "2M"    "Media uploads fail above this"
    row post_max_size                   "8M"    "Must be >= upload_max_filesize"
    row max_execution_time              "30"    "Imports and backups need the headroom"
    row max_input_time                  "60"    ""
    row max_input_vars                  "1000"  "Large menus and theme option pages silently truncate below this"
    row opcache.enable                  "1"     ""
    row opcache.memory_consumption      "128"   ""
    row opcache.max_accelerated_files   "10000" ""
    row opcache.revalidate_freq         "2"     ""
    row opcache.interned_strings_buffer "8"     "8 MB fills up on a single WordPress site — check Site Health for '100% used, 0 B free' and raise to 32"
)

# --- MariaDB -----------------------------------------------------------------
MYSQL_VERSION=""
[ -n "$MYSQL_BIN" ] && MYSQL_VERSION=$("$MYSQL_BIN" --version 2>/dev/null | head -1)
MYSQL_TUNING=""
[ -n "$MY_CNF" ] && MYSQL_TUNING=$(grep -hE \
    '^[[:space:]]*(innodb_buffer_pool_size|innodb_log_file_size|innodb_flush_method|innodb_flush_log_at_trx_commit|max_connections|max_allowed_packet|query_cache|table_open_cache|tmp_table_size|max_heap_table_size|key_buffer_size|character-set-server|collation-server)' \
    "$MY_CNF" 2>/dev/null | sed 's/^[[:space:]]*//')
[ -z "$MYSQL_TUNING" ] && MYSQL_TUNING="(nothing non-default found in ${MY_CNF:-my.cnf})"

# --- Redis -------------------------------------------------------------------
REDIS_SETTINGS=""
REDIS_SITE_MAP=""
if [ -n "$REDIS_CONF" ]; then
    REDIS_SETTINGS=$(grep -hE '^[[:space:]]*(bind|port|maxmemory|maxmemory-policy|requirepass|databases)' \
        "$REDIS_CONF" 2>/dev/null | sed 's/^[[:space:]]*//')
    # Which site uses which Redis database index, read straight from wp-config.php
    while IFS= read -r wpc; do
        [ -n "$wpc" ] || continue
        site=$(basename "$(dirname "$wpc")")
        # Anchor on a real define() at the start of a line. A loose grep picks up
        # commented-out lines and unrelated salt constants, which is worse than
        # reporting nothing — it looks like a working config when it isn't.
        rdb=$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]WP_REDIS_DATABASE['\"][[:space:]]*,[[:space:]]*\([0-9]*\).*/\1/p" "$wpc" 2>/dev/null | head -1)
        salt=$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]WP_CACHE_KEY_SALT['\"][[:space:]]*,[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$wpc" 2>/dev/null | head -1)
        # Flag a salt that is present but commented out — a silent cache collision
        # waiting to happen once two sites share a Redis database.
        if [ -z "$salt" ] && grep -q "WP_CACHE_KEY_SALT" "$wpc" 2>/dev/null; then
            salt="(!) present but commented out or malformed — no salt in effect"
        fi
        if [ -n "$rdb" ] || [ -n "$salt" ]; then
            REDIS_SITE_MAP="${REDIS_SITE_MAP}$(printf '%-24s db=%-4s salt=%s' "$site" "${rdb:-?}" "${salt:-?}")"$'\n'
        fi
    done < <(find ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"} /var/www -maxdepth 4 -name wp-config.php 2>/dev/null)
    [ -z "$REDIS_SITE_MAP" ] && REDIS_SITE_MAP="(no per-site Redis constants found in any wp-config.php)"
fi

# --- Apache global -----------------------------------------------------------
APACHE_GLOBAL=$(conf_grep '^[[:space:]]*(KeepAlive|MaxKeepAliveRequests|KeepAliveTimeout|Timeout|ServerTokens|ServerSignature|TraceEnable|Header set|Header always)' | head -30)
APACHE_MODULES=$(echo "$MODS" | grep -oE '[a-z0-9_]+_module' | sort | tr '\n' ' ')

# --- System ------------------------------------------------------------------
SYS_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "?")
SYS_SWAP=$(free -h 2>/dev/null | awk '/^Swap:/ {print $2 " total, " $3 " used"}')
SYS_UNATTENDED=$( [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && echo "configured" || echo "not configured" )
SYS_FAIL2BAN=$(have fail2ban-client && echo "installed" || echo "not installed")

CRON_ROOT=$(crontab -l -u root 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -v '^$')
[ -z "$CRON_ROOT" ] && CRON_ROOT="(empty)"

CRON_USERS=""
while IFS= read -r u; do
    c=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -v '^$')
    [ -n "$c" ] && CRON_USERS="${CRON_USERS}--- ${u} ---"$'\n'"${c}"$'\n'
done < <(cut -d: -f1 /etc/passwd)
[ -z "$CRON_USERS" ] && CRON_USERS="(none)"

LISTENING=$( (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) \
    | tail -n +2 | awk '{print $1, $4}' | sort -u)

# --- Certificates ------------------------------------------------------------
CERT_DIRS=()
for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
    [ -d "${r}/letsencrypt/certificates" ] && CERT_DIRS+=("${r}/letsencrypt/certificates")
done
[ -d /etc/letsencrypt/live ] && CERT_DIRS+=(/etc/letsencrypt/live)

CERT_LIST=""
if [ "${#CERT_DIRS[@]}" -gt 0 ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        CERT_LIST="${CERT_LIST}$(printf '%-40s %s' \
            "$(basename "$f")" "$(openssl x509 -in "$f" -noout -enddate 2>/dev/null)")"$'\n'
    done < <(find "${CERT_DIRS[@]}" \
                  \( -name '*.crt' -o -name 'fullchain.pem' \) 2>/dev/null | head -20)
fi
[ -z "$CERT_LIST" ] && CERT_LIST="(no certificates found in the usual locations)"

# =============================================================================
# Report
# =============================================================================

generate() {

cat <<EOF
# Server parity checklist

Generated by \`audit-server.sh\` on **$(date '+%Y-%m-%d %H:%M:%S %Z')** from \`$(hostname)\`.

Per-site migration bundles carry files, database, and vhost. **They do not carry
anything below.** Work through this list on the new server — ideally *before* the
first restore, so the pilot site is tested on a like-for-like machine.

Values in **bold** differ from the stock default, which means someone set them
deliberately and they need to be reproduced.

Source stack detected:

| | |
|---|---|
| Apache root | \`${APACHE_ROOT:-?}\` |
| Apache config | \`${APACHE_CONF_DIR:-?}\` |
| PHP | \`${PHP_BIN:-?}\` (${PHP_VERSION_FULL:-?}) |
| php.ini | \`${PHP_INI:-?}\` |
| MariaDB config | \`${MY_CNF:-?}\` |
| MPM | \`${MPM}\` |

---

## 1. HTTP/2 — the one that gets lost silently

EOF

if [ "$HTTP2_IN_USE" = "yes" ]; then
cat <<EOF
**This server serves HTTP/2.**

- \`mod_http2\` loaded: **${HTTP2_LOADED}**
- MPM in use: **${MPM}**
- \`Protocols\` directives found:

\`\`\`apache
${PROTOCOLS:-(none explicit — served via mod_http2 defaults)}
\`\`\`

### What breaks on the new server

Bitnami ships \`mpm_event\` + PHP-FPM, so HTTP/2 works out of the box. A stock
Ubuntu \`apache2\` defaults to **\`mpm_prefork\` + \`mod_php\`, which cannot serve
HTTP/2 at all** — \`mod_http2\` refuses to negotiate h2 under prefork. The site
works perfectly and quietly falls back to HTTP/1.1. Nothing warns you.

To restore HTTP/2 on the new instance:

\`\`\`bash
PHPVER=\$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
sudo apt-get update && sudo apt-get install -y "php\${PHPVER}-fpm"
sudo a2dismod "php\${PHPVER}" mpm_prefork
sudo a2enmod mpm_event proxy_fcgi setenvif http2
sudo a2enconf "php\${PHPVER}-fpm"
sudo systemctl restart "php\${PHPVER}-fpm" apache2
\`\`\`

Then add to each HTTPS vhost, or once globally:

\`\`\`apache
Protocols h2 h2c http/1.1
\`\`\`

Verify **after** the certificate is in place — h2 only negotiates over TLS:

\`\`\`bash
curl -sI --http2 https://example.com | head -1     # want: HTTP/2 200
\`\`\`

Note that moving to PHP-FPM also changes where PHP settings live: pool values in
\`/etc/php/\${PHPVER}/fpm/php.ini\` and \`pool.d/www.conf\`, not the CLI ini. Re-check
section 3 against the FPM ini, not just \`php -i\` on the command line.
EOF
else
cat <<EOF
No HTTP/2 configuration detected (no \`Protocols\` directive, \`mod_http2\` not
loaded). Nothing to reproduce — though the new server is a good moment to enable
it. MPM in use: \`${MPM}\`.
EOF
fi

cat <<EOF

---

## 2. Compression

| Module | Loaded |
|---|---|
| \`mod_deflate\` | ${DEFLATE_LOADED} |
| \`mod_brotli\` | ${BROTLI_LOADED} |

Configured output filters:

\`\`\`apache
${COMPRESSION_CONF:-(none found)}
\`\`\`

On the new server: \`sudo a2enmod deflate\` (and \`brotli\` if used), then copy the
directives above into the equivalent config.

---

## 3. PHP settings

Loaded ini: \`${PHP_INI:-not found}\`

| Setting | Current | Stock default | Note |
|---|---|---|---|
${PHP_ROWS}

Extensions loaded on the old server:

\`\`\`
${PHP_MODULES:-?}
\`\`\`

\`restore-site.sh\` diffs this list against the new server for you and warns about
anything missing, but installing them is manual. Watch for \`redis\`, \`imagick\`,
and \`opcache\` — none are guaranteed on a fresh image.

### PHP-FPM pool

Pool config: \`${FPM_CONF:-not found}\`
Measured now: ${FPM_WORKERS}

\`\`\`ini
${FPM_SETTINGS}
\`\`\`

This matters more than it looks. If you switch the new server to
\`mpm_event\` + PHP-FPM to get HTTP/2 back (section 1), the pool arrives with
*stock* defaults — and \`pm.max_children\` is what decides whether a traffic spike
degrades gracefully or OOM-kills MariaDB. Set it from real numbers:

\`\`\`
pm.max_children  ≈  (RAM available to PHP) / (marginal cost per worker)
\`\`\`

Use available RAM after MariaDB's buffer pool and the OS, not total RAM. And do
not take the average RSS above at face value — most of it is the shared opcache
segment, counted once per process. The honest marginal figure is usually 30–60 MB
per WordPress worker; measure with \`smem -P php-fpm\` (PSS) if you want it exact.

---

## 4. MariaDB / MySQL

Config: \`${MY_CNF:-not found}\`
Version: \`${MYSQL_VERSION:-?}\`

Non-default tuning found:

\`\`\`ini
${MYSQL_TUNING}
\`\`\`

Copy the relevant lines into the new server's
\`/etc/mysql/mariadb.conf.d/50-server.cnf\` and restart. For WordPress,
\`innodb_buffer_pool_size\` is the one that matters — size it to the new
instance's RAM rather than copying the number blindly.

---

## 5. Redis object cache

EOF

if [ -n "$REDIS_CONF" ]; then
cat <<EOF
Redis **is** in use here (\`${REDIS_CONF}\`):

\`\`\`ini
${REDIS_SETTINGS}
\`\`\`

Per-site database index assignments currently in use:

\`\`\`
${REDIS_SITE_MAP}
\`\`\`

Redis is **not** installed on the Lightsail-packaged image by default:

\`\`\`bash
sudo apt-get install -y redis-server php-redis
sudo sed -i 's/^# *maxmemory .*/maxmemory 512mb/; s/^# *maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
sudo systemctl enable --now redis-server
\`\`\`

\`restore-site.sh\` disables the object cache automatically when Redis is absent,
so sites come up working either way. Re-enable per site afterwards with
\`wp redis enable\`, keeping the database indexes above so sites stay isolated
from each other.
EOF
else
    echo "Redis is not configured on this server. Nothing to reproduce."
fi

cat <<EOF

---

## 6. Apache global settings

\`\`\`apache
${APACHE_GLOBAL:-(nothing non-default found)}
\`\`\`

Modules loaded on the old server:

\`\`\`
${APACHE_MODULES}
\`\`\`

Diff that against \`apache2ctl -M\` on the new server and \`a2enmod\` whatever is
both missing and actually used.

---

## 7. System

| | |
|---|---|
| Timezone | \`${SYS_TZ}\` |
| Swap | \`${SYS_SWAP:-none}\` |
| Unattended upgrades | ${SYS_UNATTENDED} |
| fail2ban | ${SYS_FAIL2BAN} |

Root crontab:

\`\`\`
${CRON_ROOT}
\`\`\`

Other user crontabs:

\`\`\`
${CRON_USERS}
\`\`\`

Listening ports:

\`\`\`
${LISTENING}
\`\`\`

The Lightsail **instance firewall** is separate from anything on the host — open
22, 80, and 443 on the new instance in the console.

---

## 8. SSL / TLS

Certificates cannot be moved between instances; they have to be reissued.

This server uses lego via \`renew-ssl-certs.sh\`, which is Bitnami-specific and
will not work on the new stack. Use certbot there instead:

\`\`\`bash
sudo apt-get install -y certbot python3-certbot-apache
sudo certbot --apache -d example.com -d www.example.com
\`\`\`

certbot installs its own systemd timer, so the monthly cron entry for
\`renew-ssl-certs.sh\` is not carried over.

Certificates currently on this server:

\`\`\`
${CERT_LIST}
\`\`\`
EOF
}

# =============================================================================
# Emit
# =============================================================================

if [ "$OUT" = "-" ]; then
    generate
else
    generate > "$OUT"
    # Same reason as the bundle in export-site.sh: written as root under sudo,
    # but the person who has to read and copy it is the login user.
    if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$OUT" 2>/dev/null || true
    fi
    echo "==> Wrote $OUT"
    echo "    Read section 1 (HTTP/2) before restoring any site — it is the setting"
    echo "    most likely to be lost without anyone noticing."
fi
