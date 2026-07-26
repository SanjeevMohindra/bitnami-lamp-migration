#!/bin/bash
#
# restore-site.sh — Rebuild a site from an export-site.sh bundle onto a different
#                   LAMP stack, then verify it against the numbers recorded at
#                   export time.
#
# Usage:  sudo ./restore-site.sh --dry-run        # probe, validate, print the plan
#         sudo ./restore-site.sh                  # do it
#         sudo ./restore-site.sh --force          # overwrite an existing site (backs it up)
#         sudo ./restore-site.sh <bundle.tar.gz>  # extract and restore in one step
#
# Options:
#   --dry-run          Change nothing. Print every path, database, and vhost it
#                      would write. Always run this first.
#   --force            Replace an existing document root and database. Both are
#                      backed up next to the bundle before anything is touched.
#   --docroot DIR      Install here instead of the probed default.
#   --domain d1,d2     Override the domains from the manifest.
#   --skip-verify      Skip the post-restore checks (not recommended).
#   --selftest-tls     Also write a throwaway HTTPS vhost with a self-signed
#                      certificate. A WordPress site whose siteurl is https
#                      redirects every plain HTTP request, so without this you
#                      cannot view the restored site before DNS moves — and
#                      certbot cannot run yet, because HTTP-01 validation needs
#                      DNS pointing here already. Browse it via /etc/hosts,
#                      click through the warning, then disable it before certbot:
#                        sudo a2dissite {site}-selftest && sudo systemctl reload apache2
#
# Runs on the NEW server, from inside the extracted bundle. Nothing about the
# target stack is assumed: paths, vhost convention, web user, PHP, and database
# access are all probed via probe-target.sh, which ships in the bundle.
#
set -euo pipefail

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

DRY_RUN=0
FORCE=0
SKIP_VERIFY=0
SELFTEST_TLS=0
OVERRIDE_DOCROOT=""
OVERRIDE_DOMAINS=""
BUNDLE_TARBALL=""

usage() {
    grep '^#' "$0" | sed -n '2,25p' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --force)       FORCE=1; shift ;;
        --skip-verify)   SKIP_VERIFY=1; shift ;;
        --selftest-tls)  SELFTEST_TLS=1; shift ;;
        --docroot)     OVERRIDE_DOCROOT="${2:-}"; shift 2 ;;
        --domain)      OVERRIDE_DOMAINS="${2:-}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *.tar.gz)      BUNDLE_TARBALL="$1"; shift ;;
        *)             echo "Unknown option: $1"; usage 1 ;;
    esac
done

# --- Given a tarball, unpack it and hand over to the copy inside --------------
if [ -n "$BUNDLE_TARBALL" ]; then
    [ -f "$BUNDLE_TARBALL" ] || { echo "Error: $BUNDLE_TARBALL not found."; exit 1; }
    WORK=$(mktemp -d)
    echo "==> Extracting $(basename "$BUNDLE_TARBALL") ..."
    tar -xzf "$BUNDLE_TARBALL" -C "$WORK"
    INNER=$(find "$WORK" -maxdepth 2 -name manifest.env -printf '%h\n' | head -1)
    [ -n "$INNER" ] || { echo "Error: no manifest.env inside the bundle."; exit 1; }
    ARGS=()
    [ "$DRY_RUN" -eq 1 ]     && ARGS+=(--dry-run)
    [ "$FORCE" -eq 1 ]       && ARGS+=(--force)
    [ "$SKIP_VERIFY" -eq 1 ] && ARGS+=(--skip-verify)
    [ -n "$OVERRIDE_DOCROOT" ] && ARGS+=(--docroot "$OVERRIDE_DOCROOT")
    [ -n "$OVERRIDE_DOMAINS" ] && ARGS+=(--domain "$OVERRIDE_DOMAINS")
    exec bash "${INNER}/restore-site.sh" ${ARGS[@]+"${ARGS[@]}"}
fi

# --- Require root -------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run with sudo."
    exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '    %-22s %s\n' "$1" "$2"; }

# =============================================================================
# 1. Verify the bundle before touching anything
# =============================================================================
echo "==> Verifying bundle ..."
[ -f "${BUNDLE_DIR}/manifest.env" ] || { echo "Error: manifest.env not found. Run this from inside an extracted bundle."; exit 1; }

if [ -f "${BUNDLE_DIR}/checksums.sha256" ]; then
    if ( cd "$BUNDLE_DIR" && sha256sum --quiet -c checksums.sha256 2>/dev/null ); then
        say "Checksums" "OK"
    else
        echo "Error: checksum mismatch — the bundle is corrupt or was modified."
        echo "       Re-copy it from the source server and try again."
        exit 1
    fi
else
    say "Checksums" "no checksums.sha256 in bundle (skipped)"
fi

# shellcheck disable=SC1091
. "${BUNDLE_DIR}/manifest.env"

SITE="${EXP_SITE}"
SITE_TYPE="${EXP_SITE_TYPE}"
DOMAINS="${OVERRIDE_DOMAINS//,/ }"
[ -z "$DOMAINS" ] && DOMAINS="${EXP_DOMAINS}"

say "Site"        "$SITE"
say "Type"        "$SITE_TYPE"
say "Exported"    "${EXP_STAMP} from ${EXP_SOURCE_HOST}"
say "Domains"     "${DOMAINS:-(none)}"

if [ -z "$DOMAINS" ]; then
    echo "Error: no domains in the manifest and none given. Pass --domain example.com,www.example.com"
    exit 1
fi
PRIMARY_DOMAIN=$(echo "$DOMAINS" | awk '{print $1}')

# =============================================================================
# 2. Probe the target — never guess a path
# =============================================================================
echo ""
echo "==> Probing this server ..."
if [ -f "${BUNDLE_DIR}/probe-target.sh" ]; then
    # shellcheck disable=SC1091
    . "${BUNDLE_DIR}/probe-target.sh"
else
    echo "Error: probe-target.sh missing from the bundle. Copy it in and re-run."
    exit 1
fi
probe_target

if [ -n "$TGT_PROBLEMS" ]; then
    echo ""
    echo "==> BLOCKERS — this server is not ready:"
    echo "$TGT_PROBLEMS" | sed '/^$/d' | sed 's/^/    - /'
    echo ""
    echo "    Fix these, then re-run. ./probe-target.sh prints the full picture."
    exit 1
fi

say "Apache"      "${TGT_APACHE_CTL} (${TGT_VHOST_STYLE} vhosts in ${TGT_VHOST_DIR})"
say "PHP"         "${TGT_PHP_BIN} ${TGT_PHP_VERSION}"
say "MySQL auth"  "$TGT_MYSQL_AUTH"
say "Web user"    "${TGT_WEB_USER}:${TGT_WEB_GROUP}"

# --- Where the site lands -----------------------------------------------------
DOCROOT="${OVERRIDE_DOCROOT:-${TGT_DOCROOT_BASE}/${SITE}}"

# --- Who owns the files -------------------------------------------------------
# Mirror the Bitnami convention: a login user owns them, the web server group can
# write. That is what makes FS_METHOD 'direct' work without FTP prompts.
OWNER_USER="${SUDO_USER:-}"
if [ -z "$OWNER_USER" ] || ! id "$OWNER_USER" >/dev/null 2>&1; then
    OWNER_USER="$TGT_WEB_USER"
fi
OWNER_GROUP="$TGT_WEB_GROUP"

# =============================================================================
# 3. Compatibility checks
# =============================================================================
echo ""
echo "==> Compatibility ..."
WARNINGS=""
warn() { WARNINGS="${WARNINGS}${1}"$'\n'; echo "    WARNING: $1"; }

if [ -n "${EXP_SRC_PHP_VERSION:-}" ] && [ -n "$TGT_PHP_VERSION" ] \
   && [ "$EXP_SRC_PHP_VERSION" != "$TGT_PHP_VERSION" ]; then
    warn "PHP ${EXP_SRC_PHP_VERSION} on the old server, ${TGT_PHP_VERSION} here. Usually fine, but check any plugin with a version floor."
fi

# Lowercase both sides: php -m mixes cases (SimpleXML, PDO, SPL, Zend OPcache),
# so a literal comparison invents missing extensions that are actually present.
MISSING_EXT=""
TGT_MODULES_LC=" $(echo "${TGT_PHP_MODULES:-}" | tr 'A-Z' 'a-z') "
for m in ${EXP_SRC_PHP_MODULES:-}; do
    m_lc=$(echo "$m" | tr 'A-Z' 'a-z')
    case "$TGT_MODULES_LC" in
        *" $m_lc "*) ;;
        *) MISSING_EXT="${MISSING_EXT} ${m}" ;;
    esac
done
if [ -n "$MISSING_EXT" ]; then
    warn "PHP extensions missing here:${MISSING_EXT}"
    # Extension name != package name: pdo_pgsql and pgsql both ship in php-pgsql,
    # pdo_sqlite in php-sqlite3. Strip the pdo_ prefix and dedupe so the hint is
    # a command that actually resolves.
    PKG_HINT=$(echo "$MISSING_EXT" | tr ' ' '\n' | sed 's/^pdo_//; s/^sqlite$/sqlite3/' \
               | grep -v '^$' | sort -u | sed 's/^/php-/' | tr '\n' ' ')
    echo "             Install with: sudo apt-get install -y ${PKG_HINT}"
fi

if [ "$TGT_MOD_REWRITE" = "no" ]; then
    echo "    mod_rewrite is off — it will be enabled (WordPress permalinks need it)."
fi
if [ "$TGT_MOD_HEADERS" = "no" ]; then
    echo "    mod_headers is off — it will be enabled (browser cache headers need it)."
fi
if [ -n "${EXP_REDIS_DB:-}" ] && [ "$TGT_REDIS" = "no" ]; then
    warn "This site used a Redis object cache (db ${EXP_REDIS_DB}); Redis is not installed here. The site will run without it — see reference/server-parity.md."
fi

# --- Existing installation? ---------------------------------------------------
DB_EXISTS=0
SITE_EXISTS=0
[ -d "$DOCROOT" ] && [ -n "$(ls -A "$DOCROOT" 2>/dev/null)" ] && SITE_EXISTS=1

# mysql_admin — run a statement with whichever admin auth the probe found
ADMIN_CNF=""
mysql_admin() {
    case "$TGT_MYSQL_AUTH" in
        socket)   "$TGT_MYSQL_BIN" -u root "$@" ;;
        root-cnf) "$TGT_MYSQL_BIN" --defaults-file=/root/.my.cnf "$@" ;;
        password-env)
            if [ -z "$ADMIN_CNF" ]; then
                ADMIN_CNF=$(mktemp); chmod 600 "$ADMIN_CNF"
                printf '[client]\nuser=root\npassword=%s\n' "$MYSQL_ROOT_PASSWORD" > "$ADMIN_CNF"
            fi
            "$TGT_MYSQL_BIN" --defaults-file="$ADMIN_CNF" "$@"
            ;;
        *) return 1 ;;
    esac
}
cleanup() { [ -n "$ADMIN_CNF" ] && rm -f "$ADMIN_CNF"; return 0; }
trap cleanup EXIT

if [ "$SITE_TYPE" = "wordpress" ]; then
    if mysql_admin -N -B -e "SHOW DATABASES LIKE '${EXP_DB_NAME}'" 2>/dev/null | grep -q .; then
        DB_EXISTS=1
    fi
fi

# --- Database engine compatibility -------------------------------------------
# Migrating to a *newer* database is not a safe assumption: vendor images pin
# whatever LTS they shipped with, so the new server is often OLDER than the one
# you are leaving. A dump from a newer MariaDB can carry collations the older
# server has never heard of, and the import then dies part-way through — after
# the files are already in place.
if [ "$SITE_TYPE" = "wordpress" ] && [ -n "${EXP_DB_SERVER_VERSION:-}" ]; then
    TGT_DB_VERSION=$(mysql_admin -N -B -e "SELECT VERSION()" 2>/dev/null | head -1 || true)
    say "DB engine" "${EXP_DB_SERVER_VERSION} -> ${TGT_DB_VERSION:-unknown}"

    # major*1000 + minor, so 10.11 sorts below 12.2 rather than above it.
    ver_key() { echo "${1:-0}" | awk -F. '{printf "%d", $1*1000 + $2}'; }
    if [ -n "$TGT_DB_VERSION" ] && [ "$(ver_key "$EXP_DB_SERVER_VERSION")" -gt "$(ver_key "$TGT_DB_VERSION")" ]; then
        warn "The new server runs an OLDER database (${TGT_DB_VERSION}) than the dump came from (${EXP_DB_SERVER_VERSION})."
    fi

    # The decisive test is not the version number but whether every collation in
    # the dump actually exists here.
    if [ -n "${EXP_DB_COLLATIONS:-}" ]; then
        TGT_COLLATIONS=$(mysql_admin -N -B -e "SELECT COLLATION_NAME FROM information_schema.COLLATIONS" 2>/dev/null | tr '\n' ' ' || true)
        UNSUPPORTED=""
        for c in $EXP_DB_COLLATIONS; do
            case " $TGT_COLLATIONS " in
                *" $c "*) ;;
                *) UNSUPPORTED="${UNSUPPORTED} ${c}" ;;
            esac
        done
        if [ -n "$UNSUPPORTED" ]; then
            echo ""
            echo "Error: this server does not support collations the dump uses:${UNSUPPORTED}"
            echo "       The import would fail part-way and leave a half-restored database."
            echo "       Fix by upgrading MariaDB here to match ${EXP_DB_SERVER_VERSION}."
            echo "       Nothing has been changed."
            exit 1
        fi
        say "Collations" "all $(echo "$EXP_DB_COLLATIONS" | wc -w | tr -d ' ') supported here"
    fi
fi

if { [ "$SITE_EXISTS" -eq 1 ] || [ "$DB_EXISTS" -eq 1 ]; } && [ "$FORCE" -eq 0 ]; then
    echo ""
    echo "Error: this site already exists here."
    [ "$SITE_EXISTS" -eq 1 ] && echo "       Document root: ${DOCROOT} (not empty)"
    [ "$DB_EXISTS" -eq 1 ]   && echo "       Database:      ${EXP_DB_NAME}"
    echo "       Re-run with --force to replace it. Both are backed up first."
    exit 1
fi

# =============================================================================
# 4. The plan
# =============================================================================
echo ""
echo "==> Plan"
say "Document root"  "$DOCROOT"
say "Ownership"      "${OWNER_USER}:${OWNER_GROUP} (dirs 775, files 664)"
if [ "$SITE_TYPE" = "wordpress" ]; then
say "Database"       "${EXP_DB_NAME} (charset ${EXP_DB_DEFAULT_CHARSET:-${EXP_DB_CHARSET:-utf8mb4}}${EXP_DB_DEFAULT_COLLATION:+, collation ${EXP_DB_DEFAULT_COLLATION}})"
if [ -f "${BUNDLE_DIR}/reference/table-counts.txt" ]; then
say "Row verification"  "$(wc -l < "${BUNDLE_DIR}/reference/table-counts.txt" | tr -d ' ') tables will be row-counted after import"
else
say "Row verification"  "NOT AVAILABLE — bundle predates per-table row counts"
fi
say "Database user"  "${EXP_DB_USER}@localhost, new password generated"
say "wp-config.php"  "from wp-config.php.orig, DB constants replaced, salts kept"
fi
say "Vhost"          "${TGT_VHOST_DIR}/${SITE}.conf (HTTP only — no certificate yet)"
say "ServerName"     "$PRIMARY_DOMAIN"
say "ServerAlias"    "$(echo "$DOMAINS" | sed "s/^${PRIMARY_DOMAIN} *//")"
[ "$SITE_EXISTS" -eq 1 ] && say "Existing files" "backed up, then replaced (--force)"
[ "$DB_EXISTS" -eq 1 ]   && say "Existing DB"    "dumped to a backup, then replaced (--force)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "==> Dry run — nothing was changed."
    [ -n "$WARNINGS" ] && { echo "    Warnings above are worth reading before the real run."; }
    exit 0
fi

# =============================================================================
# 5. Restore
# =============================================================================
BACKUP_DIR="${BUNDLE_DIR}/pre-restore-backup-$(date +%Y%m%d-%H%M%S)"

if [ "$SITE_EXISTS" -eq 1 ] || [ "$DB_EXISTS" -eq 1 ]; then
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    echo ""
    echo "==> Backing up what is already here to ${BACKUP_DIR} ..."
    if [ "$SITE_EXISTS" -eq 1 ]; then
        tar -czf "${BACKUP_DIR}/files-before.tar.gz" -C "$DOCROOT" . 2>/dev/null || true
    fi
    if [ "$DB_EXISTS" -eq 1 ] && [ -n "$TGT_MYSQL_DUMP" ]; then
        case "$TGT_MYSQL_AUTH" in
            socket)   "$TGT_MYSQL_DUMP" -u root --single-transaction --no-tablespaces "$EXP_DB_NAME" ;;
            root-cnf) "$TGT_MYSQL_DUMP" --defaults-file=/root/.my.cnf --single-transaction --no-tablespaces "$EXP_DB_NAME" ;;
            *)        "$TGT_MYSQL_DUMP" --defaults-file="$ADMIN_CNF" --single-transaction --no-tablespaces "$EXP_DB_NAME" ;;
        esac | gzip > "${BACKUP_DIR}/database-before.sql.gz" || true
    fi
fi

# --- Files --------------------------------------------------------------------
echo ""
echo "==> Restoring files to ${DOCROOT} ..."
if [ "$SITE_EXISTS" -eq 1 ]; then
    rm -rf "${DOCROOT:?}"/{*,.[!.]*} 2>/dev/null || true
fi
mkdir -p "$DOCROOT"
tar -xzf "${BUNDLE_DIR}/files.tar.gz" -C "$DOCROOT" --no-same-owner
say "Files" "$(find "$DOCROOT" -type f | wc -l | tr -d ' ') restored (manifest recorded ${EXP_FILE_COUNT:-?})"

# --- Database -----------------------------------------------------------------
DB_PASSWORD=""
if [ "$SITE_TYPE" = "wordpress" ]; then
    echo ""
    echo "==> Restoring database '${EXP_DB_NAME}' ..."

    # New password: the old one stays on the old server.
    if have openssl; then
        DB_PASSWORD=$(openssl rand -hex 20)
    else
        DB_PASSWORD=$(head -c 40 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-40)
    fi

    # Prefer the database's real default over wp-config's DB_CHARSET, which is
    # the connection charset and is often stale.
    CHARSET="${EXP_DB_DEFAULT_CHARSET:-${EXP_DB_CHARSET:-utf8mb4}}"
    COLLATE="${EXP_DB_DEFAULT_COLLATION:-${EXP_DB_COLLATE:-}}"
    COLLATE_SQL=""
    [ -n "$COLLATE" ] && COLLATE_SQL=" COLLATE ${COLLATE}"

    mysql_admin <<SQL
DROP DATABASE IF EXISTS \`${EXP_DB_NAME}\`;
CREATE DATABASE \`${EXP_DB_NAME}\` CHARACTER SET ${CHARSET}${COLLATE_SQL};
CREATE USER IF NOT EXISTS '${EXP_DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${EXP_DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${EXP_DB_NAME}\`.* TO '${EXP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    gunzip -c "${BUNDLE_DIR}/database.sql.gz" | mysql_admin --default-character-set=utf8mb4 "$EXP_DB_NAME"
    RESTORED_TABLES=$(mysql_admin -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${EXP_DB_NAME}'")
    say "Tables" "${RESTORED_TABLES} restored (manifest recorded ${EXP_COUNT_TABLES:-?})"

    # --- wp-config.php --------------------------------------------------------
    # Start from the original so salts, and every custom constant, survive. Only
    # the four database constants change — nobody gets logged out.
    echo "==> Writing wp-config.php ..."
    cp "${BUNDLE_DIR}/wp-config.php.orig" "${DOCROOT}/wp-config.php"

    # set_define <file> <CONSTANT> <value>
    # Replaces the whole define() line, keeping everything else in the file byte
    # for byte. The constant name and the replacement line go through ENVIRON so
    # nothing has to be escaped, and the quote character comes in as a variable
    # so the awk source needs no \x or \0 escapes (mawk on Ubuntu is fussy).
    set_define() {
        local f="$1" k="$2" v="$3" rc=0 line
        line=$(printf "define( '%s', '%s' );" "$k" "$v")

        K="$k" LINE="$line" awk -v q="'" '
            BEGIN {
                k = ENVIRON["K"]; line = ENVIRON["LINE"]; done = 0
                re = "^[ \t]*define[ \t]*\\([ \t]*[" q "\"]" k "[" q "\"]"
            }
            { if (!done && $0 ~ re) { print line; done = 1 } else print }
            END { if (!done) exit 3 }
        ' "$f" > "${f}.tmp" || rc=$?

        if [ "$rc" -eq 0 ]; then
            mv "${f}.tmp" "$f"
        else
            rm -f "${f}.tmp"
            # Constant was absent — add it right after the opening tag.
            LINE="$line" awk '
                BEGIN { line = ENVIRON["LINE"]; added = 0 }
                !added && /^<\?php/ { print; print line; added = 1; next }
                { print }
            ' "$f" > "${f}.tmp"
            mv "${f}.tmp" "$f"
        fi
    }

    set_define "${DOCROOT}/wp-config.php" DB_NAME     "$EXP_DB_NAME"
    set_define "${DOCROOT}/wp-config.php" DB_USER     "$EXP_DB_USER"
    set_define "${DOCROOT}/wp-config.php" DB_PASSWORD "$DB_PASSWORD"
    set_define "${DOCROOT}/wp-config.php" DB_HOST     "localhost"

    # Direct filesystem access — without this WordPress prompts for FTP on every
    # plugin and theme update.
    if ! grep -q "FS_METHOD" "${DOCROOT}/wp-config.php"; then
        set_define "${DOCROOT}/wp-config.php" FS_METHOD "direct"
    fi

    # Store the generated password where only root and the owner can read it.
    CRED_FILE="$(getent passwd "$OWNER_USER" | cut -d: -f6)/.${SITE}-db-credentials"
    [ -d "$(dirname "$CRED_FILE")" ] || CRED_FILE="/root/.${SITE}-db-credentials"
    {
        echo "# Generated by restore-site.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "DB_NAME=${EXP_DB_NAME}"
        echo "DB_USER=${EXP_DB_USER}"
        echo "DB_PASSWORD=${DB_PASSWORD}"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    chown "$OWNER_USER" "$CRED_FILE" 2>/dev/null || true
    say "Credentials" "$CRED_FILE"
fi

# --- Permissions --------------------------------------------------------------
echo ""
echo "==> Setting ownership and permissions ..."
chown -R "${OWNER_USER}:${OWNER_GROUP}" "$DOCROOT"
find "$DOCROOT" -type d -exec chmod 775 {} \;
find "$DOCROOT" -type f -exec chmod 664 {} \;
[ -f "${DOCROOT}/wp-config.php" ] && chmod 640 "${DOCROOT}/wp-config.php"
say "Ownership" "${OWNER_USER}:${OWNER_GROUP}, dirs 775, files 664"

# --- Redis object cache -------------------------------------------------------
# The object-cache.php drop-in is deliberately never carried in the bundle, so a
# site always comes up working whether or not the new server has Redis. When it
# does, re-enable it here rather than leaving it as a manual follow-up: the point
# of the verification below is to test the configuration the site will actually
# run in, not a temporary one.
if [ "$SITE_TYPE" = "wordpress" ] && [ -n "${EXP_REDIS_DB:-}" ] && \
   [ "$TGT_REDIS" = "yes" ] && [ -n "$TGT_WP_CLI" ]; then
    echo ""
    echo "==> Re-enabling the Redis object cache (database ${EXP_REDIS_DB}) ..."
    # Note: no --skip-plugins here. `wp redis` is provided BY the Redis Object
    # Cache plugin, so skipping plugins would make the command vanish.
    if sudo -u "$OWNER_USER" "$TGT_WP_CLI" --path="$DOCROOT" redis enable >/dev/null 2>&1; then
        chown "${OWNER_USER}:${OWNER_GROUP}" "${DOCROOT}/wp-content/object-cache.php" 2>/dev/null || true
        say "Redis" "enabled on database ${EXP_REDIS_DB}"
    else
        say "Redis" "could not enable — check the Redis Object Cache plugin is active, then run 'wp redis enable'"
    fi
fi

# --- Apache modules -----------------------------------------------------------
# Newly enabled modules need a full restart, not a graceful reload.
MODULES_CHANGED=0
if [ "$TGT_VHOST_STYLE" = "debian" ] && have a2enmod; then
    for m in rewrite:$TGT_MOD_REWRITE headers:$TGT_MOD_HEADERS deflate:$TGT_MOD_DEFLATE; do
        if [ "${m#*:}" = "no" ]; then
            a2enmod "${m%%:*}" >/dev/null 2>&1 && MODULES_CHANGED=1
            say "Enabled module" "${m%%:*}"
        fi
    done
fi

# --- Vhost --------------------------------------------------------------------
echo ""
echo "==> Writing vhost ..."
SERVER_ALIASES=$(echo "$DOMAINS" | sed "s/^${PRIMARY_DOMAIN} *//")
VHOST_FILE="${TGT_VHOST_DIR}/${SITE}.conf"

# Browser cache policy differs by site type: WordPress appends ?ver= to CSS/JS on
# update so a month is safe; a static site needs a filename change to bust cache,
# so a year is only safe if you rename files (style.v2.css).
if [ "$SITE_TYPE" = "wordpress" ]; then
    ASSET_MAXAGE="2592000"      # 1 month
    ASSET_COMMENT="WordPress appends ?ver= on update, so a month is safe here"
else
    ASSET_MAXAGE="31536000"     # 1 year
    ASSET_COMMENT="static site: rename the file to bust this (style.v2.css)"
fi

LOGREF="$TGT_LOG_DIR"
[ "$TGT_VHOST_STYLE" = "debian" ] && LOGREF='${APACHE_LOG_DIR}'

[ -f "$VHOST_FILE" ] && cp -p "$VHOST_FILE" "${VHOST_FILE}.bak-$(date +%Y%m%d-%H%M%S)"

cat > "$VHOST_FILE" <<VHOST
# ${SITE} — generated by restore-site.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
# HTTP only. Run certbot after DNS points here; it adds the HTTPS vhost itself.
<VirtualHost *:80>
    ServerName ${PRIMARY_DOMAIN}$( [ -n "$SERVER_ALIASES" ] && printf '\n    ServerAlias %s' "$SERVER_ALIASES" || true )
    DocumentRoot "${DOCROOT}"

    <Directory "${DOCROOT}">
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <IfModule mod_headers.c>
        <FilesMatch "\.(ico|jpg|jpeg|png|gif|webp|svg|woff|woff2)\$">
            Header set Cache-Control "public, max-age=31536000, immutable"
        </FilesMatch>
        # ${ASSET_COMMENT}
        <FilesMatch "\.(css|js)\$">
            Header set Cache-Control "public, max-age=${ASSET_MAXAGE}"
        </FilesMatch>
        <FilesMatch "\.html\$">
            Header set Cache-Control "public, max-age=3600"
        </FilesMatch>
    </IfModule>

    ErrorLog ${LOGREF}/${SITE}-error.log
    CustomLog ${LOGREF}/${SITE}-access.log combined
</VirtualHost>
VHOST

say "Vhost" "$VHOST_FILE"

if [ "$TGT_VHOST_STYLE" = "debian" ] && have a2ensite; then
    a2ensite "${SITE}.conf" >/dev/null 2>&1 || true
    say "Enabled" "a2ensite ${SITE}.conf"
fi

# --- Throwaway HTTPS vhost, so the site can be seen before DNS moves ----------
if [ "$SELFTEST_TLS" -eq 1 ] && [ "$TGT_VHOST_STYLE" = "debian" ]; then
    have a2enmod && a2enmod ssl >/dev/null 2>&1 || true
    SNAKE_CRT="/etc/ssl/certs/ssl-cert-snakeoil.pem"
    SNAKE_KEY="/etc/ssl/private/ssl-cert-snakeoil.key"
    if [ ! -f "$SNAKE_CRT" ] || [ ! -f "$SNAKE_KEY" ]; then
        if have make-ssl-cert; then
            make-ssl-cert generate-default-snakeoil --force-overwrite >/dev/null 2>&1 || true
        fi
    fi
    if [ ! -f "$SNAKE_CRT" ] || [ ! -f "$SNAKE_KEY" ]; then
        SNAKE_CRT="/etc/ssl/certs/${SITE}-selftest.crt"
        SNAKE_KEY="/etc/ssl/private/${SITE}-selftest.key"
        openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
            -subj "/CN=${PRIMARY_DOMAIN}" -keyout "$SNAKE_KEY" -out "$SNAKE_CRT" >/dev/null 2>&1 || true
        chmod 600 "$SNAKE_KEY" 2>/dev/null || true
    fi

    if [ -f "$SNAKE_CRT" ] && [ -f "$SNAKE_KEY" ]; then
        cat > "${TGT_VHOST_DIR}/${SITE}-selftest.conf" <<SELFTEST
# ${SITE} — TEMPORARY self-signed HTTPS, for verification before DNS moves.
# Disable before running certbot:
#   sudo a2dissite ${SITE}-selftest && sudo systemctl reload ${TGT_APACHE_SVC}
<VirtualHost *:443>
    ServerName ${PRIMARY_DOMAIN}$( [ -n "$SERVER_ALIASES" ] && printf '\n    ServerAlias %s' "$SERVER_ALIASES" || true )
    DocumentRoot "${DOCROOT}"

    <Directory "${DOCROOT}">
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile    ${SNAKE_CRT}
    SSLCertificateKeyFile ${SNAKE_KEY}

    ErrorLog ${LOGREF}/${SITE}-selftest-error.log
</VirtualHost>
SELFTEST
        have a2ensite && a2ensite "${SITE}-selftest.conf" >/dev/null 2>&1 || true
        say "Self-test TLS" "enabled (self-signed — expect a browser warning)"
    else
        say "Self-test TLS" "could not create a certificate — skipped"
    fi
fi

# --- Config test, then reload -------------------------------------------------
echo ""
echo "==> Testing Apache config ..."
if ! "$TGT_APACHE_CTL" -t; then
    echo "Error: Apache config test failed. The vhost is at ${VHOST_FILE}."
    echo "       Apache has NOT been reloaded, so the server is still serving."
    exit 1
fi
if [ "$MODULES_CHANGED" -eq 1 ]; then
    echo "==> Restarting Apache (modules were enabled) ..."
    systemctl restart "$TGT_APACHE_SVC" 2>/dev/null || "$TGT_APACHE_CTL" -k restart
else
    echo "==> Reloading Apache ..."
    systemctl reload "$TGT_APACHE_SVC" 2>/dev/null || "$TGT_APACHE_CTL" -k graceful
fi

# =============================================================================
# 6. Verify
# =============================================================================
VERIFY_FAILED=0
if [ "$SKIP_VERIFY" -eq 0 ]; then
    echo ""
    echo "==> Verifying ..."
    sleep 2

    check_http() {
        local path="$1" label="$2" code
        if ! have curl; then say "$label" "curl not installed — skipped"; return 0; fi
        code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${PRIMARY_DOMAIN}" \
               "http://127.0.0.1${path}" 2>/dev/null || echo "000")
        if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
            say "$label" "HTTP ${code}"
        else
            say "$label" "HTTP ${code}  <-- FAILED"
            VERIFY_FAILED=1
        fi
    }
    check_http "/" "Home page"

    if [ "$SITE_TYPE" = "wordpress" ] && [ -n "$TGT_WP_CLI" ]; then
        wp_run() { sudo -u "$OWNER_USER" "$TGT_WP_CLI" --path="$DOCROOT" --skip-plugins --skip-themes "$@" 2>/dev/null; }

        if wp_run core is-installed; then
            say "WordPress" "installed and reachable"
        else
            say "WordPress" "wp core is-installed FAILED  <--"
            VERIFY_FAILED=1
        fi

        # Permalinks: rewrite rules that lived in the old vhost need to exist as
        # .htaccess here. This is the single most common thing to break.
        PERMA=$(wp_run option get permalink_structure || true)
        if [ -n "$PERMA" ]; then
            wp_run rewrite flush --hard >/dev/null 2>&1 || true
            chown "${OWNER_USER}:${OWNER_GROUP}" "${DOCROOT}/.htaccess" 2>/dev/null || true
            # Any pretty URL will do — fall back to a page when the site has no
            # posts, otherwise a pages-only site silently skips the one check
            # that catches broken rewrite rules.
            POST_URL=$(wp_run post list --post_type=post --post_status=publish --posts_per_page=1 --field=url | head -1 || true)
            [ -z "$POST_URL" ] && POST_URL=$(wp_run post list --post_type=page --post_status=publish --posts_per_page=1 --field=url | head -1 || true)
            if [ -n "$POST_URL" ]; then
                check_http "$(echo "$POST_URL" | sed -E 's#^https?://[^/]+##')" "Permalink"
            else
                say "Permalink" "no published post or page to test — check a pretty URL by hand"
            fi
        fi

        # Counts against the manifest — this is the actual proof of a good restore.
        compare() {
            local label="$1" expected="$2" actual="$3"
            if [ -z "$expected" ]; then
                say "$label" "${actual} (nothing recorded at export)"
            elif [ "$expected" = "$actual" ]; then
                say "$label" "${actual} = ${expected} OK"
            else
                say "$label" "${actual}, expected ${expected}  <-- MISMATCH"
                VERIFY_FAILED=1
            fi
        }
        compare "Posts"    "${EXP_COUNT_POSTS:-}"    "$(wp_run post list --post_type=post --post_status=any --format=count || echo '?')"
        compare "Pages"    "${EXP_COUNT_PAGES:-}"    "$(wp_run post list --post_type=page --post_status=any --format=count || echo '?')"
        compare "Users"    "${EXP_COUNT_USERS:-}"    "$(wp_run user list --format=count || echo '?')"
        compare "Comments" "${EXP_COUNT_COMMENTS:-}" "$(wp_run comment list --format=count || echo '?')"
        compare "Plugins"  "${EXP_COUNT_PLUGINS:-}"  "$(wp_run plugin list --status=active --format=count || echo '?')"

        wp_run db check >/dev/null 2>&1 && say "Database check" "OK" || say "Database check" "reported issues — run 'wp db check'"
    elif [ "$SITE_TYPE" = "wordpress" ]; then
        say "WP-CLI" "not installed here — content counts not verified"
        echo "             Install it to get self-verification: https://wp-cli.org"
    fi

    # --- Per-table row counts -------------------------------------------------
    # The real proof. Content-type counts above only describe a blog; this
    # catches a WooCommerce catalogue, orders in wc_orders, or any plugin's
    # custom tables arriving short. Runs with or without WP-CLI.
    if [ "$SITE_TYPE" = "wordpress" ] && [ -f "${BUNDLE_DIR}/reference/table-counts.txt" ]; then
        # Some tables are inherently volatile: WordPress writes transients, cron
        # schedules and rewrite rules into the options table simply by booting,
        # and the checks above (wp core is-installed, rewrite flush, two HTTP
        # requests) all boot it. Growth there is the verification observing its
        # own side effects, not data loss.
        #
        # The asymmetry is the useful part: MORE rows than expected in a volatile
        # table is noise; FEWER is real and still fails.
        is_volatile() {
            case "$1" in
                *options|*wc_sessions|*actionscheduler_*|*wc_admin_note*) return 0 ;;
                *queue|*_queue|*_log|*_logs|*cache|*_cache|*_sessions) return 0 ;;
                *) return 1 ;;
            esac
        }

        # Must match export-site.sh exactly, or the two counts describe different
        # things: transients are excluded from any *options table.
        count_rows() {
            local tbl="$1" sql
            case "$tbl" in
                *options) sql="SELECT COUNT(*) FROM \`${tbl}\` WHERE option_name NOT LIKE '\\_transient\\_%' AND option_name NOT LIKE '\\_site\\_transient\\_%'" ;;
                *)        sql="SELECT COUNT(*) FROM \`${tbl}\`" ;;
            esac
            mysql_admin -N -B -e "$sql" "$EXP_DB_NAME" 2>/dev/null \
              || mysql_admin -N -B -e "SELECT COUNT(*) FROM \`${tbl}\`" "$EXP_DB_NAME" 2>/dev/null \
              || echo "MISSING"
        }

        TABLES_OK=0; TABLES_BAD=0; TABLES_DRIFT=0; BAD_LIST=""; DRIFT_LIST=""
        while read -r t expected; do
            [ -n "$t" ] || continue
            actual=$(count_rows "$t")
            if [ "$actual" = "$expected" ]; then
                TABLES_OK=$((TABLES_OK + 1))
            elif is_volatile "$t" && [ "$actual" -gt "$expected" ] 2>/dev/null; then
                TABLES_DRIFT=$((TABLES_DRIFT + 1))
                DRIFT_LIST="${DRIFT_LIST}      ${t}: ${actual} vs ${expected} (+$((actual - expected)) rows — volatile table, written by the site simply running)"$'\n'
            else
                TABLES_BAD=$((TABLES_BAD + 1))
                BAD_LIST="${BAD_LIST}      ${t}: got ${actual}, expected ${expected}"$'\n'
            fi
        done < "${BUNDLE_DIR}/reference/table-counts.txt"

        if [ "$TABLES_BAD" -eq 0 ]; then
            if [ "$TABLES_DRIFT" -eq 0 ]; then
                say "Table row counts" "all ${TABLES_OK} tables match"
            else
                say "Table row counts" "${TABLES_OK} match, ${TABLES_DRIFT} volatile (OK)"
                printf '%s' "$DRIFT_LIST"
            fi
        else
            say "Table row counts" "${TABLES_OK} match, ${TABLES_BAD} DO NOT  <-- MISMATCH"
            printf '%s' "$BAD_LIST"
            [ "$TABLES_DRIFT" -gt 0 ] && printf '%s' "$DRIFT_LIST"
            VERIFY_FAILED=1
        fi
    fi
fi

# =============================================================================
# 7. Report
# =============================================================================
echo ""
if [ "$VERIFY_FAILED" -eq 1 ]; then
    echo "==> Restored, but VERIFICATION FAILED. Read the lines marked <-- above."
    echo "    The old server is untouched, so nothing is lost."
else
    echo "==> Restored and verified."
fi

echo ""
echo "    Next steps:"
echo "      1. Test before any DNS change — on your own machine add to /etc/hosts:"
echo "           <this server's PUBLIC IP>  ${DOMAINS}"
echo "         then browse the site and /wp-admin. Remove the line afterwards."
if [ "$SELFTEST_TLS" -eq 0 ] && [ -n "${EXP_HOME_URL:-}" ] && \
   [ "${EXP_HOME_URL#https://}" != "${EXP_HOME_URL}" ]; then
echo "         NOTE: this site's URL is https, so plain HTTP redirects straight to"
echo "         HTTPS — and there is no :443 vhost for it here yet. Apache will fall"
echo "         back to the first HTTPS vhost on the server, so you will be shown a"
echo "         DIFFERENT SITE, not an error. Re-run with --selftest-tls to get a"
echo "         temporary self-signed HTTPS vhost, or add one by hand before testing."
fi
echo "      2. Point the domain here — move the static/elastic IP to this server"
echo "         if you have one, otherwise update the DNS A records."
echo "      3. Issue a certificate — certs cannot be copied from the old server:"
echo "           sudo certbot --apache$(for d in $DOMAINS; do printf ' -d %s' "$d"; done)"
if [ -n "${EXP_REDIS_DB:-}" ]; then
    if [ "$TGT_REDIS" = "yes" ]; then
echo "      4. Re-enable the object cache:  sudo -u ${OWNER_USER} wp --path=${DOCROOT} redis enable"
    else
echo "      4. Install Redis if you want the object cache back — see reference/server-parity.md."
    fi
fi
echo ""
echo "    Do not skip reference/server-parity.md. HTTP/2 in particular does not"
echo "    survive this move on its own, and it fails silently."

if [ -n "$WARNINGS" ]; then
    echo ""
    echo "    Warnings raised during this run:"
    echo "$WARNINGS" | sed '/^$/d' | sed 's/^/      - /'
fi

[ "$VERIFY_FAILED" -eq 1 ] && exit 1
exit 0
