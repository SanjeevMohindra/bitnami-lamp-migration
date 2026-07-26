#!/bin/bash
#
# export-site.sh — Package one site (files + database + vhost + metadata) into a
#                  single self-contained .tar.gz that restore-site.sh can rebuild
#                  on a different LAMP stack.
#
# Usage:  sudo ./export-site.sh <site>              # site folder name, or an absolute path
#         sudo ./export-site.sh <site> --maintenance # WP maintenance mode during the dump
#         sudo ./export-site.sh <site> --freeze      # as above, but LEAVE it on afterwards,
#                                                   # so the old copy cannot accept orders or
#                                                   # comments while DNS propagates. Use this
#                                                   # for the final cutover export of any
#                                                   # transactional site. Lift with:
#                                                   #   sudo rm {site}/.maintenance
#         sudo ./export-site.sh <site> --out DIR     # where to write the bundle
#         sudo ./export-site.sh --list               # show the sites it can find
#
# Runs on the OLD server. The site stays live and serving throughout (unless you
# pass --maintenance); safe to run as many times as you like.
#
# Nothing about any particular server is hardcoded — the Bitnami stack root,
# Apache root, web root, vhosts, domains, database credentials, and WP-CLI are
# all discovered. It works on any Bitnami LAMP or WordPress stack regardless of
# where it came from (Lightsail, EC2/Marketplace, Azure, GCP, or the standalone
# native installer under /opt/lampstack-* or ~/stack), on single-site and
# multi-site hosts alike, and on a stock /var/www layout too.
#
# Output: <out-dir>/<site>-YYYYMMDD-HHMMSS.tar.gz, mode 600, containing:
#
#   manifest.env        every fact restore-site.sh needs, plus content counts
#   files.tar.gz        the site tree (caches and logs excluded)
#   database.sql.gz     mysqldump — WordPress sites only
#   wp-config.php.orig  preserved verbatim so salts survive the move
#   vhosts/             the site's vhost files, for reference
#   reference/          plugins, themes, php modules, .htaccess, server-parity.md
#   restore-site.sh     the restore script travels with the bundle
#   probe-target.sh     sourced by restore-site.sh on the new server
#   checksums.sha256
#
# The bundle contains a full database dump (including user password hashes) and
# database credentials. It is written 0600. Delete it from every machine once the
# migration is signed off.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# --- Defaults ----------------------------------------------------------------
SITE=""
OUT_DIR=""
MAINTENANCE=0
FREEZE=0
KEEP_DIR=0

usage() {
    grep '^#' "$0" | sed -n '2,32p' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- Parse arguments ---------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --maintenance) MAINTENANCE=1; shift ;;
        --freeze)      MAINTENANCE=1; FREEZE=1; shift ;;
        --keep-dir)    KEEP_DIR=1; shift ;;
        --out)         OUT_DIR="${2:-}"; shift 2 ;;
        --list)        SITE="--list"; shift ;;
        -h|--help)     usage 0 ;;
        -*)            echo "Unknown option: $1"; usage 1 ;;
        *)
            [ -n "$SITE" ] && { echo "Error: more than one site given."; usage 1; }
            SITE="$1"; shift
            ;;
    esac
done

[ -z "$SITE" ] && usage 1

# --- Require root ------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run with sudo (it reads wp-config.php and dumps the database)."
    exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

# --- Discover the source stack ------------------------------------------------
#
# Bitnami LAMP/WordPress ships in several shapes depending on where it came from
# — a cloud marketplace image (Lightsail, EC2, Azure, GCP) installs under
# /opt/bitnami, while the standalone native installer uses a versioned directory
# such as /opt/lampstack-8.2.12-0 or ~/stack. Older images put applications under
# apps/{name}/htdocs; newer ones put a single app straight in the web root.
# Find the stack rather than assuming any one of those.

# contains <needle> <haystack...> — the globs below overlap, so dedupe as we go
contains() {
    local n="$1" e; shift
    for e in "$@"; do [ "$e" = "$n" ] && return 0; done
    return 1
}

STACK_ROOTS=()
for d in /opt/bitnami /opt/lampstack-* /opt/*stack-* "${HOME:-/root}/stack" /home/*/stack; do
    [ -d "$d" ] || continue
    contains "$d" ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"} || STACK_ROOTS+=("$d")
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

WEB_ROOTS=()
for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
    for a in apache apache2; do
        [ -d "${r}/${a}/htdocs" ] || continue
        contains "${r}/${a}/htdocs" ${WEB_ROOTS[@]+"${WEB_ROOTS[@]}"} || WEB_ROOTS+=("${r}/${a}/htdocs")
    done
done
for d in /var/www /var/www/html; do
    [ -d "$d" ] || continue
    contains "$d" ${WEB_ROOTS[@]+"${WEB_ROOTS[@]}"} || WEB_ROOTS+=("$d")
done

# Bitnami's per-application layout: {root}/apps/{name}/htdocs
APP_ROOTS=()
for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
    [ -d "${r}/apps" ] || continue
    contains "${r}/apps" ${APP_ROOTS[@]+"${APP_ROOTS[@]}"} || APP_ROOTS+=("${r}/apps")
done

VHOST_DIRS=()
for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
    for a in apache apache2; do
        for sub in conf/vhosts conf/bitnami; do
            [ -d "${r}/${a}/${sub}" ] || continue
            contains "${r}/${a}/${sub}" ${VHOST_DIRS[@]+"${VHOST_DIRS[@]}"} || VHOST_DIRS+=("${r}/${a}/${sub}")
        done
    done
done
for d in /etc/apache2/sites-available /etc/apache2/sites-enabled /etc/httpd/conf.d; do
    [ -d "$d" ] || continue
    contains "$d" ${VHOST_DIRS[@]+"${VHOST_DIRS[@]}"} || VHOST_DIRS+=("$d")
done

list_sites() {
    echo "Sites found:"
    local r e name type
    # A site per directory under a web root — the multi-site layout.
    for r in ${WEB_ROOTS[@]+"${WEB_ROOTS[@]}"}; do
        for e in "$r"/*/; do
            [ -d "$e" ] || continue
            name=$(basename "$e")
            type="static"; [ -f "${e}wp-config.php" ] && type="wordpress"
            printf '    %-24s %-10s %s\n' "$name" "$type" "${e%/}"
        done
        # Single-site image: the web root itself is the site.
        [ -f "${r}/wp-config.php" ] && printf '    %-24s %-10s %s\n' "$(basename "$(dirname "$r")")" "wordpress" "$r"
    done
    # Bitnami's apps/{name}/htdocs layout.
    for r in ${APP_ROOTS[@]+"${APP_ROOTS[@]}"}; do
        for e in "$r"/*/htdocs; do
            [ -d "$e" ] || continue
            name=$(basename "$(dirname "$e")")
            type="static"; [ -f "${e}/wp-config.php" ] && type="wordpress"
            printf '    %-24s %-10s %s\n' "$name" "$type" "$e"
        done
    done
    # Newer single-app images: {root}/wordpress
    for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
        for e in "$r"/*/; do
            [ -f "${e}wp-config.php" ] || continue
            printf '    %-24s %-10s %s\n' "$(basename "$e")" "wordpress" "${e%/}"
        done
    done
    if [ "${#WEB_ROOTS[@]}" -eq 0 ] && [ "${#STACK_ROOTS[@]}" -eq 0 ]; then
        echo "    (none — no Bitnami stack or standard web root found on this host)"
        echo "    Pass an absolute path instead: sudo $0 /path/to/site"
    fi
}

if [ "$SITE" = "--list" ]; then
    list_sites
    exit 0
fi

# --- Locate the site ----------------------------------------------------------
SITE_DIR=""
if [ "${SITE:0:1}" = "/" ]; then
    SITE_DIR="${SITE%/}"
    SITE=$(basename "$SITE_DIR")
else
    # A directory named after the site under a web root — the usual case.
    for r in ${WEB_ROOTS[@]+"${WEB_ROOTS[@]}"}; do
        [ -d "${r}/${SITE}" ] && { SITE_DIR="${r}/${SITE}"; break; }
    done
    # Bitnami's apps/{name}/htdocs layout.
    if [ -z "$SITE_DIR" ]; then
        for r in ${APP_ROOTS[@]+"${APP_ROOTS[@]}"}; do
            [ -d "${r}/${SITE}/htdocs" ] && { SITE_DIR="${r}/${SITE}/htdocs"; break; }
        done
    fi
    # A single-app image: {stack}/wordpress, or the web root itself.
    if [ -z "$SITE_DIR" ]; then
        for r in ${STACK_ROOTS[@]+"${STACK_ROOTS[@]}"}; do
            [ -d "${r}/${SITE}" ] && [ -f "${r}/${SITE}/wp-config.php" ] && { SITE_DIR="${r}/${SITE}"; break; }
        done
    fi
    # Single-site image: the web root IS the site. Only accept this when there is
    # exactly one such web root, so a typo can never silently export the wrong
    # thing on a multi-site host.
    if [ -z "$SITE_DIR" ]; then
        SINGLE=""
        SINGLE_COUNT=0
        for r in ${WEB_ROOTS[@]+"${WEB_ROOTS[@]}"}; do
            if [ -f "${r}/wp-config.php" ]; then
                SINGLE="$r"; SINGLE_COUNT=$((SINGLE_COUNT + 1))
            fi
        done
        if [ "$SINGLE_COUNT" -eq 1 ]; then
            SITE_DIR="$SINGLE"
            echo "    Note: single-site image — using the web root ${SITE_DIR} as '${SITE}'."
        fi
    fi
fi

if [ -z "$SITE_DIR" ] || [ ! -d "$SITE_DIR" ]; then
    echo "Error: could not find a site called '${SITE}'."
    echo ""
    list_sites
    exit 1
fi

# --- Site type and ownership --------------------------------------------------
SITE_TYPE="static"
[ -f "${SITE_DIR}/wp-config.php" ] && SITE_TYPE="wordpress"

SRC_OWNER_USER=$(stat -c '%U' "$SITE_DIR")
SRC_OWNER_GROUP=$(stat -c '%G' "$SITE_DIR")

echo "==> Exporting '${SITE}'"
printf '    %-20s %s\n' "Path"       "$SITE_DIR"
printf '    %-20s %s\n' "Type"       "$SITE_TYPE"
printf '    %-20s %s\n' "Ownership"  "${SRC_OWNER_USER}:${SRC_OWNER_GROUP}"

# --- Find the vhost files and the domains they serve --------------------------
VHOST_FILES=()
for d in "${VHOST_DIRS[@]}"; do
    while IFS= read -r f; do
        [ -n "$f" ] && VHOST_FILES+=("$f")
    done < <(grep -lE "DocumentRoot[[:space:]]+\"?${SITE_DIR}/?\"?[[:space:]]*$" "$d"/*.conf 2>/dev/null || true)
done

DOMAINS=""
if [ "${#VHOST_FILES[@]}" -gt 0 ]; then
    DOMAINS=$(grep -hE '^[[:space:]]*(ServerName|ServerAlias)[[:space:]]' "${VHOST_FILES[@]}" 2>/dev/null \
              | awk '{$1=""; print}' | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
fi

# --- WP-CLI -------------------------------------------------------------------
WP_BIN=$(stack_path wp-cli/bin/wp bin/wp 2>/dev/null || true)
if [ -z "$WP_BIN" ]; then
    for c in /usr/local/bin/wp /usr/bin/wp; do
        [ -x "$c" ] && { WP_BIN="$c"; break; }
    done
fi
[ -z "$WP_BIN" ] && have wp && WP_BIN=$(command -v wp)

# wp_run — always as the file owner, never as root (WP-CLI refuses root anyway)
wp_run() {
    [ -n "$WP_BIN" ] || return 1
    sudo -u "$SRC_OWNER_USER" "$WP_BIN" --path="$SITE_DIR" --skip-plugins --skip-themes "$@" 2>/dev/null
}

# --- WordPress specifics ------------------------------------------------------
DB_NAME=""; DB_USER=""; DB_PASSWORD=""; DB_HOST=""; DB_CHARSET=""; DB_COLLATE=""
DB_SERVER_VERSION=""; DB_COLLATIONS=""; DB_DEFAULT_CHARSET=""; DB_DEFAULT_COLLATION=""
TABLE_PREFIX=""; WP_VERSION=""; PERMALINK=""; REDIS_DB=""; REDIS_SALT=""; SITE_URL=""; HOME_URL=""
COUNT_POSTS=""; COUNT_PAGES=""; COUNT_USERS=""; COUNT_COMMENTS=""; COUNT_PLUGINS=""; COUNT_TABLES=""

# wpconfig_get <CONSTANT> — regex fallback for when WP-CLI is unavailable
wpconfig_get() {
    sed -n "s/^[[:space:]]*define([[:space:]]*['\"]${1}['\"][[:space:]]*,[[:space:]]*['\"]\(.*\)['\"][[:space:]]*)[[:space:]]*;.*/\1/p" \
        "${SITE_DIR}/wp-config.php" | head -1
}

if [ "$SITE_TYPE" = "wordpress" ]; then
    if [ -n "$WP_BIN" ]; then
        DB_NAME=$(wp_run config get DB_NAME || true)
        DB_USER=$(wp_run config get DB_USER || true)
        DB_PASSWORD=$(wp_run config get DB_PASSWORD || true)
        DB_HOST=$(wp_run config get DB_HOST || true)
        DB_CHARSET=$(wp_run config get DB_CHARSET || true)
        DB_COLLATE=$(wp_run config get DB_COLLATE || true)
        TABLE_PREFIX=$(wp_run config get table_prefix || true)
    fi
    # Regex fallback for anything WP-CLI could not give us.
    [ -z "$DB_NAME" ]     && DB_NAME=$(wpconfig_get DB_NAME)
    [ -z "$DB_USER" ]     && DB_USER=$(wpconfig_get DB_USER)
    [ -z "$DB_PASSWORD" ] && DB_PASSWORD=$(wpconfig_get DB_PASSWORD)
    [ -z "$DB_HOST" ]     && DB_HOST=$(wpconfig_get DB_HOST)
    [ -z "$DB_CHARSET" ]  && DB_CHARSET=$(wpconfig_get DB_CHARSET)
    [ -z "$DB_COLLATE" ]  && DB_COLLATE=$(wpconfig_get DB_COLLATE)
    [ -z "$TABLE_PREFIX" ] && TABLE_PREFIX=$(sed -n "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\"]\(.*\)['\"][[:space:]]*;.*/\1/p" \
                                             "${SITE_DIR}/wp-config.php" | head -1)

    if [ -z "$DB_NAME" ]; then
        echo "Error: could not determine DB_NAME from ${SITE_DIR}/wp-config.php."
        exit 1
    fi
    [ -z "$DB_HOST" ] && DB_HOST="localhost"

    # Redis object cache constants, if this site uses one.
    REDIS_DB=$(grep -E "WP_REDIS_DATABASE" "${SITE_DIR}/wp-config.php" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)
    REDIS_SALT=$(wpconfig_get WP_CACHE_KEY_SALT || true)

    printf '    %-20s %s\n' "Database" "$DB_NAME"
    printf '    %-20s %s\n' "Table prefix" "${TABLE_PREFIX:-?}"
fi

# --- Where to write -----------------------------------------------------------
if [ -z "$OUT_DIR" ]; then
    # Default to the invoking user's home, never inside the web root.
    HOME_DIR=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
    if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
        OUT_DIR="${HOME_DIR}/migration"
    else
        OUT_DIR="/var/tmp/migration"
    fi
fi
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

STAMP=$(date +%Y%m%d-%H%M%S)
BUNDLE_NAME="${SITE}-${STAMP}"
STAGE="${OUT_DIR}/${BUNDLE_NAME}"
mkdir -p "${STAGE}/vhosts" "${STAGE}/reference"

# --- Maintenance mode (cutover runs only) -------------------------------------
MAINT_FILE="${SITE_DIR}/.maintenance"
MAINT_ON=0
cleanup() {
    if [ "$MAINT_ON" -eq 1 ] && [ -f "$MAINT_FILE" ]; then
        if [ "$FREEZE" -eq 1 ]; then
            echo "==> Maintenance mode LEFT IN PLACE (--freeze)."
            echo "    This copy can no longer take orders or comments, so nothing"
            echo "    written here during DNS propagation will be orphaned."
            echo "    Lift it with:  sudo rm ${MAINT_FILE}"
        else
            rm -f "$MAINT_FILE"
            echo "==> (cleanup) Maintenance mode lifted."
        fi
    fi
}
trap cleanup EXIT

if [ "$MAINTENANCE" -eq 1 ] && [ "$SITE_TYPE" = "wordpress" ]; then
    echo "==> Enabling maintenance mode for the duration of the dump ..."
    printf '<?php $upgrading = %s; ?>\n' "$(date +%s)" > "$MAINT_FILE"
    chown "${SRC_OWNER_USER}:${SRC_OWNER_GROUP}" "$MAINT_FILE"
    MAINT_ON=1
fi

# --- Database dump ------------------------------------------------------------
if [ "$SITE_TYPE" = "wordpress" ]; then
    # Prefer mariadb-dump where it exists — MariaDB 11+ prints a deprecation
    # warning for the mysqldump name, and a warning in migration output is a
    # warning people learn to ignore.
    MYSQLDUMP=$(stack_path mariadb/bin/mariadb-dump mariadb/bin/mysqldump mysql/bin/mysqldump 2>/dev/null || true)
    if [ -z "$MYSQLDUMP" ]; then
        for c in /usr/bin/mariadb-dump /usr/bin/mysqldump; do
            [ -x "$c" ] && { MYSQLDUMP="$c"; break; }
        done
    fi
    [ -z "$MYSQLDUMP" ] && have mysqldump && MYSQLDUMP=$(command -v mysqldump)
    if [ -z "$MYSQLDUMP" ]; then
        echo "Error: mysqldump not found."
        exit 1
    fi

    # Credentials via a 0600 defaults file so they never appear in ps output.
    DUMP_CNF=$(mktemp)
    chmod 600 "$DUMP_CNF"
    {
        echo "[client]"
        echo "user=${DB_USER}"
        echo "password=${DB_PASSWORD}"
        echo "host=${DB_HOST%%:*}"
    } > "$DUMP_CNF"
    trap 'rm -f "$DUMP_CNF"; cleanup' EXIT

    echo "==> Dumping database '${DB_NAME}' ..."
    "$MYSQLDUMP" --defaults-file="$DUMP_CNF" \
                 --single-transaction --quick --routines --events \
                 --no-tablespaces --default-character-set=utf8mb4 \
                 "$DB_NAME" | gzip -9 > "${STAGE}/database.sql.gz"

    COUNT_TABLES=$(gunzip -c "${STAGE}/database.sql.gz" | grep -c '^CREATE TABLE' || true)
    printf '    %-20s %s\n' "Tables dumped" "$COUNT_TABLES"

    # Record the server version and the collations actually in use. A dump only
    # restores cleanly onto a server that understands both — and migrating to a
    # *newer* host is not guaranteed, since vendor images pin whatever LTS they
    # shipped with. restore-site.sh checks this before it imports anything.
    MYSQL_CLIENT=$(stack_path mariadb/bin/mysql mysql/bin/mysql 2>/dev/null || true)
    [ -z "$MYSQL_CLIENT" ] && have mysql && MYSQL_CLIENT=$(command -v mysql)
    if [ -n "$MYSQL_CLIENT" ]; then
        DB_SERVER_VERSION=$("$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B \
                            -e "SELECT VERSION()" 2>/dev/null | head -1 || true)
        # The database's OWN default charset/collation, not what wp-config claims.
        # DB_CHARSET in wp-config is the *connection* charset and is frequently
        # stale ('utf8' on installs whose tables were long since moved to
        # utf8mb4). Creating the database from the stale value would leave any
        # table a plugin adds later on utf8mb3 — the classic silent emoji bug.
        DB_DEFAULT_CHARSET=$("$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B \
                             -e "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA
                                 WHERE SCHEMA_NAME='${DB_NAME}'" 2>/dev/null | head -1 || true)
        DB_DEFAULT_COLLATION=$("$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B \
                               -e "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA
                                   WHERE SCHEMA_NAME='${DB_NAME}'" 2>/dev/null | head -1 || true)
        printf '    %-20s %s / %s\n' "DB default" \
               "${DB_DEFAULT_CHARSET:-?}" "${DB_DEFAULT_COLLATION:-?}"
        if [ -n "$DB_DEFAULT_CHARSET" ] && [ -n "$DB_CHARSET" ] && \
           [ "$DB_DEFAULT_CHARSET" != "$DB_CHARSET" ]; then
            echo "    NOTE: wp-config says DB_CHARSET='${DB_CHARSET}' but the database default is"
            echo "          '${DB_DEFAULT_CHARSET}'. Carried across as-is — not changed here, since"
            echo "          altering the connection charset is a separate decision."
        fi

        DB_COLLATIONS=$("$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B \
                        -e "SELECT DISTINCT table_collation FROM information_schema.tables
                            WHERE table_schema='${DB_NAME}' AND table_collation IS NOT NULL" \
                        2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
        printf '    %-20s %s\n' "DB server" "${DB_SERVER_VERSION:-?}"
        printf '    %-20s %s\n' "Collations" "${DB_COLLATIONS:-?}"

        # Exact row count for every table. WordPress post/page/user counts only
        # describe a blog: a WooCommerce catalogue lives in product post types
        # and, under HPOS, orders are in wc_orders rather than wp_posts at all.
        # Counting every table is content-agnostic, so it verifies WooCommerce,
        # LearnDash, membership plugins, and custom tables without knowing
        # anything about them.
        # (COUNT(*) is a scan per table on InnoDB — fine for typical sites,
        # noticeably slower on multi-million-row tables.)
        # count_rows <table> — transients are excluded from any *options table.
        # They are cache with an expiry: they churn constantly on a live site,
        # and WordPress deletes the expired ones the instant a restored site is
        # first loaded. Counting them makes options look like it lost hundreds of
        # rows on arrival. What is left is the part that matters — real settings.
        count_rows() {
            local tbl="$1" sql
            case "$tbl" in
                *options) sql="SELECT COUNT(*) FROM \`${tbl}\` WHERE option_name NOT LIKE '\\_transient\\_%' AND option_name NOT LIKE '\\_site\\_transient\\_%'" ;;
                *)        sql="SELECT COUNT(*) FROM \`${tbl}\`" ;;
            esac
            "$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B -e "$sql" "$DB_NAME" 2>/dev/null \
              || "$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B -e "SELECT COUNT(*) FROM \`${tbl}\`" "$DB_NAME" 2>/dev/null \
              || echo "?"
        }

        echo "==> Counting rows in every table ..."
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            printf '%s %s\n' "$t" "$(count_rows "$t")"
        done < <("$MYSQL_CLIENT" --defaults-file="$DUMP_CNF" -N -B \
                 -e "SHOW TABLES" "$DB_NAME" 2>/dev/null) > "${STAGE}/reference/table-counts.txt"
        TOTAL_ROWS=$(awk '{s+=$2} END {print s+0}' "${STAGE}/reference/table-counts.txt")
        printf '    %-20s %s rows across %s tables\n' "Row counts" \
               "$TOTAL_ROWS" "$(wc -l < "${STAGE}/reference/table-counts.txt" | tr -d ' ')"
    fi
fi

# --- Content counts (the numbers restore-site.sh verifies against) ------------
if [ "$SITE_TYPE" = "wordpress" ] && [ -n "$WP_BIN" ]; then
    echo "==> Recording content counts ..."
    WP_VERSION=$(wp_run core version || true)
    SITE_URL=$(wp_run option get siteurl || true)
    HOME_URL=$(wp_run option get home || true)
    PERMALINK=$(wp_run option get permalink_structure || true)
    COUNT_POSTS=$(wp_run post list --post_type=post --post_status=any --format=count || true)
    COUNT_PAGES=$(wp_run post list --post_type=page --post_status=any --format=count || true)
    COUNT_USERS=$(wp_run user list --format=count || true)
    COUNT_COMMENTS=$(wp_run comment list --format=count || true)
    COUNT_PLUGINS=$(wp_run plugin list --status=active --format=count || true)

    # If no vhost gave us domains, take them from the site URL.
    if [ -z "$DOMAINS" ] && [ -n "$HOME_URL" ]; then
        DOMAINS=$(echo "$HOME_URL" | sed -E 's#^https?://##; s#/.*##')
    fi

    printf '    %-20s posts=%s pages=%s users=%s comments=%s plugins=%s\n' \
           "Counts" "${COUNT_POSTS:-?}" "${COUNT_PAGES:-?}" "${COUNT_USERS:-?}" \
           "${COUNT_COMMENTS:-?}" "${COUNT_PLUGINS:-?}"
elif [ "$SITE_TYPE" = "wordpress" ]; then
    echo "    WARNING: WP-CLI not found — content counts will not be recorded,"
    echo "             so restore-site.sh cannot self-verify. Files and database"
    echo "             still export correctly."
fi

# --- Reference material -------------------------------------------------------
echo "==> Collecting reference material ..."

for f in "${VHOST_FILES[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && cp -p "$f" "${STAGE}/vhosts/"
done

if [ "$SITE_TYPE" = "wordpress" ]; then
    cp -p "${SITE_DIR}/wp-config.php" "${STAGE}/wp-config.php.orig"
    chmod 600 "${STAGE}/wp-config.php.orig"
    if [ -n "$WP_BIN" ]; then
        wp_run plugin list > "${STAGE}/reference/plugins.txt" || true
        wp_run theme list  > "${STAGE}/reference/themes.txt"  || true
    fi
fi
[ -f "${SITE_DIR}/.htaccess" ] && cp -p "${SITE_DIR}/.htaccess" "${STAGE}/reference/htaccess.orig"

SRC_PHP_BIN=$(stack_path php/bin/php 2>/dev/null || true)
[ -z "$SRC_PHP_BIN" ] && [ -x /usr/bin/php ] && SRC_PHP_BIN=/usr/bin/php
[ -z "$SRC_PHP_BIN" ] && have php && SRC_PHP_BIN=$(command -v php)

SRC_PHP_VERSION=""; SRC_PHP_MODULES=""
if [ -n "$SRC_PHP_BIN" ]; then
    SRC_PHP_VERSION=$("$SRC_PHP_BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    SRC_PHP_MODULES=$("$SRC_PHP_BIN" -m 2>/dev/null | grep -v '^\[' | grep -v '^$' | sort | tr '\n' ' ' || true)
    echo "$SRC_PHP_MODULES" | tr ' ' '\n' > "${STAGE}/reference/php-modules.txt"
fi

crontab -l -u "$SRC_OWNER_USER" > "${STAGE}/reference/crontab-${SRC_OWNER_USER}.txt" 2>/dev/null || true
crontab -l -u root > "${STAGE}/reference/crontab-root.txt" 2>/dev/null || true

# Server-wide parity checklist — the things this bundle cannot carry.
if [ -x "${SCRIPT_DIR}/audit-server.sh" ]; then
    "${SCRIPT_DIR}/audit-server.sh" -o "${STAGE}/reference/server-parity.md" >/dev/null 2>&1 \
        || echo "    WARNING: audit-server.sh failed; server-parity.md not included."
else
    echo "    WARNING: audit-server.sh not found next to this script — bundle will"
    echo "             not include the server parity checklist (HTTP/2, PHP ini, ...)."
fi

# --- File tree ----------------------------------------------------------------
echo "==> Archiving files ..."
FILE_BYTES=$(du -sb "$SITE_DIR" 2>/dev/null | awk '{print $1}')

tar -czf "${STAGE}/files.tar.gz" \
    --exclude='./wp-content/cache' \
    --exclude='./wp-content/upgrade' \
    --exclude='./wp-content/uploads/cache' \
    --exclude='./wp-content/ai1wm-backups' \
    --exclude='./wp-content/updraft' \
    --exclude='./wp-content/backups-*' \
    --exclude='./wp-content/object-cache.php' \
    --exclude='./.maintenance' \
    --exclude='./.git' \
    --exclude='*.log' \
    -C "$SITE_DIR" . 2>/dev/null || true

# Lift maintenance mode as early as possible — the slow part is over.
cleanup; MAINT_ON=0

# Count what is actually IN the archive, not what is on disk. Counting the source
# tree includes the caches and logs the excludes above deliberately drop, so the
# manifest would record a number the new server can never match, and every
# restore would report a phantom shortfall.
FILE_COUNT=$(tar -tzf "${STAGE}/files.tar.gz" 2>/dev/null | grep -vc '/$' || true)

printf '    %-20s %s files, %s\n' "Archived" "$FILE_COUNT" \
       "$(du -h "${STAGE}/files.tar.gz" | awk '{print $1}')"

# --- Ship the restore tooling inside the bundle --------------------------------
for s in restore-site.sh probe-target.sh; do
    if [ -f "${SCRIPT_DIR}/${s}" ]; then
        cp "${SCRIPT_DIR}/${s}" "${STAGE}/${s}"
        chmod +x "${STAGE}/${s}"
    else
        echo "    WARNING: ${s} not found next to this script — the bundle will not"
        echo "             be self-restoring. Copy it in manually."
    fi
done

# --- Manifest -----------------------------------------------------------------
echo "==> Writing manifest ..."
{
    echo "# manifest.env — generated by export-site.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "# Shell-sourceable. Every value is quoted with printf %q."
    echo ""
    for v in SITE SITE_TYPE SITE_DIR DOMAINS \
             SRC_OWNER_USER SRC_OWNER_GROUP SRC_PHP_VERSION SRC_PHP_MODULES \
             DB_NAME DB_USER DB_HOST DB_CHARSET DB_COLLATE TABLE_PREFIX \
             DB_SERVER_VERSION DB_COLLATIONS DB_DEFAULT_CHARSET DB_DEFAULT_COLLATION \
             WP_VERSION SITE_URL HOME_URL PERMALINK REDIS_DB REDIS_SALT \
             COUNT_POSTS COUNT_PAGES COUNT_USERS COUNT_COMMENTS COUNT_PLUGINS \
             COUNT_TABLES FILE_COUNT FILE_BYTES STAMP; do
        printf 'EXP_%s=%q\n' "$v" "${!v:-}"
    done
    printf 'EXP_SOURCE_HOST=%q\n' "$(hostname)"
    printf 'EXP_BUNDLE_VERSION=%q\n' "1"
} > "${STAGE}/manifest.env"
chmod 600 "${STAGE}/manifest.env"

# The old database password never goes in the manifest — restore generates a new
# one. It stays only in wp-config.php.orig, which is 0600 inside the bundle.

# --- Checksums ----------------------------------------------------------------
( cd "$STAGE" && find . -type f ! -name checksums.sha256 -print0 \
  | sort -z | xargs -0 sha256sum > checksums.sha256 )

# --- Seal ---------------------------------------------------------------------
echo "==> Sealing bundle ..."
BUNDLE="${OUT_DIR}/${BUNDLE_NAME}.tar.gz"
tar -czf "$BUNDLE" -C "$OUT_DIR" "$BUNDLE_NAME"
chmod 600 "$BUNDLE"
[ "$KEEP_DIR" -eq 0 ] && rm -rf "$STAGE"

# Hand the bundle back to whoever invoked sudo. Everything above runs as root,
# so without this the output directory and the bundle are root:root 0600 — and
# the login user cannot scp off the machine the file they just created.
if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$OUT_DIR" "$BUNDLE" 2>/dev/null || true
fi

echo ""
echo "==> Done."
printf '    %-20s %s\n' "Bundle"  "$BUNDLE"
printf '    %-20s %s\n' "Size"    "$(du -h "$BUNDLE" | awk '{print $1}')"
printf '    %-20s %s\n' "Domains" "${DOMAINS:-(none found — restore will ask)}"
echo ""
echo "    Next:"
echo "      scp <this-server>:${BUNDLE} ."
echo "      scp $(basename "$BUNDLE") <new-server>:~/"
echo "      ssh <new-server> 'tar -xzf $(basename "$BUNDLE") && cd ${BUNDLE_NAME} && sudo ./restore-site.sh --dry-run'"
echo ""
echo "    The bundle holds a full database dump and credentials. Delete it from"
echo "    every machine once the migration is signed off."
