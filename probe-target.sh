#!/bin/bash
#
# probe-target.sh — Detect the layout of a target LAMP server. Read-only.
#
# Usage:  sudo ./probe-target.sh            # print a report of what was found
#         sudo ./probe-target.sh --env      # print TGT_* variables only (machine readable)
#
# Run this FIRST on the new server, before any migration. It changes nothing — it
# only reports what the stack looks like so restore-site.sh can adapt to it
# instead of guessing paths. Works against any standard Apache + PHP + MySQL or
# MariaDB host: Debian/Ubuntu (sites-available), RHEL/Amazon Linux (conf.d), or a
# cloud-vendor image built on either.
#
# This file is also SOURCED by restore-site.sh (it ships in every bundle), so the
# probe logic exists in exactly one place. When sourced it defines functions and
# does nothing else.
#
# Sets, via probe_target():
#   TGT_OS_NAME TGT_OS_VERSION
#   TGT_APACHE_CTL TGT_APACHE_SVC TGT_APACHE_CONF_ROOT TGT_VHOST_DIR TGT_VHOST_STYLE
#   TGT_DEFAULT_DOCROOT TGT_DOCROOT_BASE TGT_LOG_DIR
#   TGT_WEB_USER TGT_WEB_GROUP
#   TGT_MPM TGT_MOD_REWRITE TGT_MOD_HEADERS TGT_MOD_HTTP2 TGT_MOD_DEFLATE
#   TGT_PHP_BIN TGT_PHP_VERSION TGT_PHP_MODULES TGT_PHP_FPM
#   TGT_MYSQL_BIN TGT_MYSQL_DUMP TGT_MYSQL_VERSION TGT_MYSQL_AUTH
#   TGT_WP_CLI TGT_REDIS TGT_CERTBOT
#   TGT_DISK_FREE TGT_RAM_TOTAL
#   TGT_PROBLEMS   (newline-separated list of blockers; empty means good to go)
#

set -uo pipefail

# --- Small helpers -----------------------------------------------------------

# first_existing <path> [path...] -> echoes the first path that exists
first_existing() {
    local p
    for p in "$@"; do
        [ -e "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# have <command> -> true if the command is on PATH
have() { command -v "$1" >/dev/null 2>&1; }

# --- The probe ---------------------------------------------------------------

probe_target() {
    # Probing is all best-effort lookups that are *expected* to fail sometimes.
    # restore-site.sh sources this file under `set -e`, so turn errexit off for
    # the duration and put it back exactly as we found it.
    local _errexit=0
    case "$-" in *e*) _errexit=1; set +e ;; esac

    TGT_PROBLEMS=""
    _problem() { TGT_PROBLEMS="${TGT_PROBLEMS}${1}"$'\n'; }

    # --- OS ---------------------------------------------------------------
    TGT_OS_NAME="unknown"; TGT_OS_VERSION=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        TGT_OS_NAME=$(. /etc/os-release && echo "${NAME:-unknown}")
        TGT_OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-}")
    fi

    # --- Apache: control binary, service name, config root ----------------
    TGT_APACHE_CTL=""
    for c in apache2ctl apachectl httpd; do
        have "$c" && { TGT_APACHE_CTL=$(command -v "$c"); break; }
    done
    [ -z "$TGT_APACHE_CTL" ] && _problem "Apache control binary not found (looked for apache2ctl, apachectl, httpd)."

    TGT_APACHE_CONF_ROOT=$(first_existing /etc/apache2 /etc/httpd /usr/local/apache2/conf || echo "")
    [ -z "$TGT_APACHE_CONF_ROOT" ] && _problem "Apache config root not found (looked for /etc/apache2, /etc/httpd)."

    TGT_APACHE_SVC="apache2"
    [ "$TGT_APACHE_CONF_ROOT" = "/etc/httpd" ] && TGT_APACHE_SVC="httpd"

    # --- Vhost convention --------------------------------------------------
    # Debian style: sites-available + a2ensite symlinks into sites-enabled.
    # RedHat style: drop .conf files straight into conf.d.
    TGT_VHOST_STYLE="unknown"; TGT_VHOST_DIR=""
    if [ -d "${TGT_APACHE_CONF_ROOT}/sites-available" ]; then
        TGT_VHOST_STYLE="debian"
        TGT_VHOST_DIR="${TGT_APACHE_CONF_ROOT}/sites-available"
    elif [ -d "${TGT_APACHE_CONF_ROOT}/conf.d" ]; then
        TGT_VHOST_STYLE="conf.d"
        TGT_VHOST_DIR="${TGT_APACHE_CONF_ROOT}/conf.d"
    elif [ -d "${TGT_APACHE_CONF_ROOT}/vhosts" ]; then
        TGT_VHOST_STYLE="vhosts"
        TGT_VHOST_DIR="${TGT_APACHE_CONF_ROOT}/vhosts"
    else
        _problem "No vhost directory found under ${TGT_APACHE_CONF_ROOT} (sites-available / conf.d / vhosts)."
    fi

    # --- Document root -----------------------------------------------------
    # Take the first DocumentRoot in the shipped config; the site goes in a
    # sibling directory of it, so we adapt to whatever base the image uses.
    TGT_DEFAULT_DOCROOT=""
    if [ -n "$TGT_APACHE_CONF_ROOT" ]; then
        TGT_DEFAULT_DOCROOT=$(grep -rhE '^[[:space:]]*DocumentRoot[[:space:]]' "$TGT_APACHE_CONF_ROOT" 2>/dev/null \
                              | head -1 | awk '{print $2}' | tr -d '"' || true)
    fi
    [ -z "$TGT_DEFAULT_DOCROOT" ] && TGT_DEFAULT_DOCROOT="/var/www/html"
    TGT_DOCROOT_BASE=$(dirname "$TGT_DEFAULT_DOCROOT")

    TGT_LOG_DIR=$(first_existing /var/log/apache2 /var/log/httpd || echo "/var/log/apache2")

    # --- Web server user / group ------------------------------------------
    TGT_WEB_USER=""; TGT_WEB_GROUP=""
    if [ -r "${TGT_APACHE_CONF_ROOT}/envvars" ]; then
        # `set +u` matters: Debian's envvars dereferences APACHE_CONFDIR, which is
        # unset outside an apache2ctl run. Under nounset that aborts the source
        # before it ever reaches APACHE_RUN_USER.
        # shellcheck disable=SC1091
        TGT_WEB_USER=$(set +u; . "${TGT_APACHE_CONF_ROOT}/envvars" >/dev/null 2>&1; echo "${APACHE_RUN_USER:-}")
        TGT_WEB_GROUP=$(set +u; . "${TGT_APACHE_CONF_ROOT}/envvars" >/dev/null 2>&1; echo "${APACHE_RUN_GROUP:-}")
    fi
    if [ -z "$TGT_WEB_USER" ] && [ -n "$TGT_APACHE_CONF_ROOT" ]; then
        TGT_WEB_USER=$(grep -rhE '^[[:space:]]*User[[:space:]]' "$TGT_APACHE_CONF_ROOT" 2>/dev/null | head -1 | awk '{print $2}' || true)
        TGT_WEB_GROUP=$(grep -rhE '^[[:space:]]*Group[[:space:]]' "$TGT_APACHE_CONF_ROOT" 2>/dev/null | head -1 | awk '{print $2}' || true)
    fi
    # Debian's apache2.conf says `User ${APACHE_RUN_USER}`. If a placeholder is
    # what we ended up with, the value is unresolved — don't hand a literal
    # "${APACHE_RUN_USER}" to chown.
    case "$TGT_WEB_USER"  in *'${'*) TGT_WEB_USER=""  ;; esac
    case "$TGT_WEB_GROUP" in *'${'*) TGT_WEB_GROUP="" ;; esac
    [ -z "$TGT_WEB_USER" ]  && TGT_WEB_USER="www-data"
    [ -z "$TGT_WEB_GROUP" ] && TGT_WEB_GROUP="$TGT_WEB_USER"

    # --- Apache modules and MPM -------------------------------------------
    local mods=""
    [ -n "$TGT_APACHE_CTL" ] && mods=$("$TGT_APACHE_CTL" -M 2>/dev/null || true)
    _mod() { echo "$mods" | grep -q "$1" && echo "yes" || echo "no"; }
    TGT_MOD_REWRITE=$(_mod 'rewrite_module')
    TGT_MOD_HEADERS=$(_mod 'headers_module')
    TGT_MOD_HTTP2=$(_mod 'http2_module')
    TGT_MOD_DEFLATE=$(_mod 'deflate_module')
    TGT_MPM=$(echo "$mods" | grep -oE 'mpm_[a-z]+' | head -1 || true)
    [ -z "$TGT_MPM" ] && TGT_MPM="unknown"

    # --- PHP ---------------------------------------------------------------
    TGT_PHP_BIN=""; TGT_PHP_VERSION=""; TGT_PHP_MODULES=""; TGT_PHP_FPM="no"
    if have php; then
        TGT_PHP_BIN=$(command -v php)
        TGT_PHP_VERSION=$("$TGT_PHP_BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
        TGT_PHP_MODULES=$("$TGT_PHP_BIN" -m 2>/dev/null | grep -v '^\[' | grep -v '^$' | sort | tr '\n' ' ' || true)
    else
        _problem "PHP CLI not found on PATH."
    fi
    echo "$mods" | grep -q 'proxy_fcgi_module' && TGT_PHP_FPM="yes"

    # Which PHP does APACHE run? Not necessarily the one on PATH. A box can
    # happily have PHP 8.5 as the CLI while mod_php 8.4 serves every request —
    # and the web SAPI is the one that decides whether the site works. Read the
    # enabled module/conf filenames, which carry the version explicitly.
    TGT_PHP_WEB=""; TGT_PHP_SAPI="unknown"
    if [ -n "$TGT_APACHE_CONF_ROOT" ]; then
        for f in "${TGT_APACHE_CONF_ROOT}"/mods-enabled/php*.load; do
            [ -e "$f" ] || continue
            TGT_PHP_SAPI="mod_php"
            TGT_PHP_WEB=$(basename "$f" .load | sed -E 's/^php//')
            break
        done
        if [ -z "$TGT_PHP_WEB" ] && [ "$TGT_PHP_FPM" = "yes" ]; then
            for f in "${TGT_APACHE_CONF_ROOT}"/conf-enabled/php*-fpm.conf; do
                [ -e "$f" ] || continue
                TGT_PHP_SAPI="php-fpm"
                TGT_PHP_WEB=$(basename "$f" .conf | sed -E 's/^php//; s/-fpm$//')
                break
            done
        fi
    fi
    [ -z "$TGT_PHP_WEB" ] && TGT_PHP_WEB="$TGT_PHP_VERSION"

    # --- MariaDB / MySQL ---------------------------------------------------
    TGT_MYSQL_BIN=""; TGT_MYSQL_DUMP=""; TGT_MYSQL_VERSION=""; TGT_MYSQL_AUTH="none"
    for c in mysql mariadb; do
        have "$c" && { TGT_MYSQL_BIN=$(command -v "$c"); break; }
    done
    for c in mysqldump mariadb-dump; do
        have "$c" && { TGT_MYSQL_DUMP=$(command -v "$c"); break; }
    done
    [ -z "$TGT_MYSQL_BIN" ] && _problem "No mysql/mariadb client found."

    if [ -n "$TGT_MYSQL_BIN" ]; then
        TGT_MYSQL_VERSION=$("$TGT_MYSQL_BIN" --version 2>/dev/null | head -1 || true)
        # How can we reach the server as an admin? Try cheapest first.
        if "$TGT_MYSQL_BIN" -u root -e 'SELECT 1' >/dev/null 2>&1; then
            TGT_MYSQL_AUTH="socket"                     # unix_socket auth as root
        elif [ -r /root/.my.cnf ] && "$TGT_MYSQL_BIN" --defaults-file=/root/.my.cnf -e 'SELECT 1' >/dev/null 2>&1; then
            TGT_MYSQL_AUTH="root-cnf"                   # credentials in /root/.my.cnf
        elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && \
             "$TGT_MYSQL_BIN" -u root -p"${MYSQL_ROOT_PASSWORD}" -e 'SELECT 1' >/dev/null 2>&1; then
            TGT_MYSQL_AUTH="password-env"               # MYSQL_ROOT_PASSWORD in the environment
        else
            _problem "Cannot authenticate to MariaDB/MySQL as root. Set MYSQL_ROOT_PASSWORD in the environment, or create /root/.my.cnf. On a Lightsail blueprint the password is usually in ~/application_credentials or ~/bitnami_application_password."
        fi
    fi

    # --- PHP extensions WordPress actually needs ---------------------------
    # A minimal PHP build will run WordPress far enough to look fine and then
    # fail at the first image upload or plugin install. Check up front.
    # Compare lowercased: php -m prints SimpleXML, PDO, SPL, Zend OPcache with
    # capitals and everything else lowercase, so a literal match reports
    # extensions as missing when they are right there in the list.
    TGT_PHP_MODULES_LC=$(echo "$TGT_PHP_MODULES" | tr 'A-Z' 'a-z')
    TGT_PHP_MISSING=""
    if [ -n "$TGT_PHP_MODULES" ]; then
        for ext in curl mbstring xml dom simplexml zip gd intl bcmath exif fileinfo; do
            case " $TGT_PHP_MODULES_LC " in
                *" $ext "*) ;;
                *) TGT_PHP_MISSING="${TGT_PHP_MISSING} ${ext}" ;;
            esac
        done
        # gd and imagick are alternatives — only complain if neither is present.
        case " $TGT_PHP_MODULES_LC " in
            *" imagick "*) TGT_PHP_MISSING=$(echo "$TGT_PHP_MISSING" | sed 's/ gd\b//') ;;
        esac
    fi

    # --- Optional tooling --------------------------------------------------
    TGT_WP_CLI=""
    for c in wp wp-cli; do
        have "$c" && { TGT_WP_CLI=$(command -v "$c"); break; }
    done
    [ -z "$TGT_WP_CLI" ] && [ -x /usr/local/bin/wp ] && TGT_WP_CLI=/usr/local/bin/wp

    TGT_REDIS="no"
    { have redis-server || have redis-cli; } && TGT_REDIS="yes"
    TGT_CERTBOT="no"
    have certbot && TGT_CERTBOT="yes"

    # --- Capacity ----------------------------------------------------------
    TGT_DISK_FREE=$(df -Ph "$TGT_DOCROOT_BASE" 2>/dev/null | awk 'NR==2 {print $4}' || echo "?")
    TGT_RAM_TOTAL=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "?")

    [ "$_errexit" -eq 1 ] && set -e
    return 0
}

# --- Report ------------------------------------------------------------------

print_probe_report() {
    echo "==> Target server probe"
    echo ""
    printf '  %-24s %s\n' "OS"                "${TGT_OS_NAME} ${TGT_OS_VERSION}"
    printf '  %-24s %s\n' "Apache control"    "${TGT_APACHE_CTL:-(none)}"
    printf '  %-24s %s\n' "Apache service"    "$TGT_APACHE_SVC"
    printf '  %-24s %s\n' "Apache config"     "${TGT_APACHE_CONF_ROOT:-(none)}"
    printf '  %-24s %s\n' "Vhost style"       "$TGT_VHOST_STYLE"
    printf '  %-24s %s\n' "Vhost directory"   "${TGT_VHOST_DIR:-(none)}"
    printf '  %-24s %s\n' "Default DocumentRoot" "$TGT_DEFAULT_DOCROOT"
    printf '  %-24s %s\n' "Site install base" "$TGT_DOCROOT_BASE"
    printf '  %-24s %s\n' "Apache log dir"    "$TGT_LOG_DIR"
    printf '  %-24s %s\n' "Web user:group"    "${TGT_WEB_USER}:${TGT_WEB_GROUP}"
    echo ""
    printf '  %-24s %s\n' "MPM"               "$TGT_MPM"
    printf '  %-24s %s\n' "mod_rewrite"       "$TGT_MOD_REWRITE"
    printf '  %-24s %s\n' "mod_headers"       "$TGT_MOD_HEADERS"
    printf '  %-24s %s\n' "mod_http2"         "$TGT_MOD_HTTP2"
    printf '  %-24s %s\n' "mod_deflate"       "$TGT_MOD_DEFLATE"
    printf '  %-24s %s\n' "PHP-FPM (proxy_fcgi)" "$TGT_PHP_FPM"
    echo ""
    printf '  %-24s %s\n' "PHP binary"        "${TGT_PHP_BIN:-(none)}"
    printf '  %-24s %s\n' "PHP version (CLI)" "${TGT_PHP_VERSION:-?}"
    printf '  %-24s %s\n' "PHP version (web)" "${TGT_PHP_WEB:-?} via ${TGT_PHP_SAPI}"
    printf '  %-24s %s\n' "MySQL client"      "${TGT_MYSQL_BIN:-(none)}"
    printf '  %-24s %s\n' "MySQL version"     "${TGT_MYSQL_VERSION:-?}"
    printf '  %-24s %s\n' "MySQL admin auth"  "$TGT_MYSQL_AUTH"
    printf '  %-24s %s\n' "WP-CLI"            "${TGT_WP_CLI:-(not installed)}"
    printf '  %-24s %s\n' "Redis"             "$TGT_REDIS"
    printf '  %-24s %s\n' "certbot"           "$TGT_CERTBOT"
    echo ""
    printf '  %-24s %s\n' "Free disk"         "$TGT_DISK_FREE"
    printf '  %-24s %s\n' "Total RAM"         "$TGT_RAM_TOTAL"
    echo ""
    printf '  %-24s %s\n' "PHP modules"       "${TGT_PHP_MODULES:-?}"
    echo ""

    # Advisory notes — not blockers, but they are the things people miss.
    if [ "$TGT_MPM" = "mpm_prefork" ] && [ "$TGT_MOD_HTTP2" = "no" ]; then
        echo "  NOTE: mpm_prefork is in use, so HTTP/2 is NOT available. If the old"
        echo "        server served HTTP/2, switch to mpm_event + PHP-FPM here."
        echo "        See the HTTP/2 row in server-parity.md from audit-server.sh."
        echo ""
    fi
    if [ "$TGT_REDIS" = "no" ]; then
        echo "  NOTE: Redis is not installed. restore-site.sh will disable the object"
        echo "        cache so the site works; install Redis later if you want it back."
        echo ""
    fi
    if [ -n "${TGT_PHP_WEB:-}" ] && [ "$TGT_PHP_WEB" != "${TGT_PHP_VERSION:-}" ]; then
        echo "  NOTE: Apache serves PHP ${TGT_PHP_WEB} (${TGT_PHP_SAPI}) but the CLI is"
        echo "        PHP ${TGT_PHP_VERSION}. The WEB version is the one that runs the site."
        echo "        Extensions installed as php${TGT_PHP_VERSION}-* are invisible to it;"
        echo "        install php${TGT_PHP_WEB}-* too, or switch the web SAPI to match."
        echo ""
    fi
    if [ -n "${TGT_PHP_MISSING:-}" ]; then
        echo "  NOTE: PHP extensions WordPress expects are missing:${TGT_PHP_MISSING}"
        echo "        The site will install and load without them and then fail at"
        echo "        image resizing, plugin installs, or REST calls. Install with:"
        echo "          sudo apt-get install -y$(echo "$TGT_PHP_MISSING" | sed 's/ \([a-z]\)/ php-\1/g')"
        echo ""
    fi
    if [ -z "$TGT_WP_CLI" ]; then
        echo "  NOTE: WP-CLI is not installed, so restore-site.sh cannot verify content"
        echo "        counts against the manifest — you would be trusting the restore"
        echo "        rather than checking it. Install it before restoring:"
        echo "          curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
        echo "          sudo install -m 755 wp-cli.phar /usr/local/bin/wp"
        echo ""
    fi

    if [ -n "$TGT_PROBLEMS" ]; then
        echo "==> BLOCKERS — fix these before restoring:"
        echo "$TGT_PROBLEMS" | sed '/^$/d' | sed 's/^/    - /'
        return 1
    fi

    echo "==> No blockers found. This server is ready for restore-site.sh."
    return 0
}

print_probe_env() {
    local v
    for v in TGT_OS_NAME TGT_OS_VERSION TGT_APACHE_CTL TGT_APACHE_SVC \
             TGT_APACHE_CONF_ROOT TGT_VHOST_DIR TGT_VHOST_STYLE \
             TGT_DEFAULT_DOCROOT TGT_DOCROOT_BASE TGT_LOG_DIR \
             TGT_WEB_USER TGT_WEB_GROUP TGT_MPM TGT_MOD_REWRITE TGT_MOD_HEADERS \
             TGT_MOD_HTTP2 TGT_MOD_DEFLATE TGT_PHP_BIN TGT_PHP_VERSION TGT_PHP_FPM \
             TGT_MYSQL_BIN TGT_MYSQL_DUMP TGT_MYSQL_VERSION TGT_MYSQL_AUTH \
             TGT_WP_CLI TGT_REDIS TGT_CERTBOT TGT_DISK_FREE TGT_RAM_TOTAL; do
        printf '%s=%q\n' "$v" "${!v:-}"
    done
}

# --- Run directly, or just define the functions when sourced -----------------
#
# BASH_SOURCE is unset when bash reads a script from stdin (`ssh host bash -s <
# probe-target.sh`), so default it to $0 — that keeps this true when piped and
# when executed as a file, and false only when genuinely sourced by another
# script, which is what restore-site.sh relies on.

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    case "${1:-}" in
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --env)
            probe_target
            print_probe_env
            exit 0
            ;;
        "")
            probe_target
            print_probe_report
            exit $?
            ;;
        *)
            echo "Usage: sudo $0 [--env]"
            exit 1
            ;;
    esac
fi
