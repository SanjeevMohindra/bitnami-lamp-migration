# Migration Runbook — Bitnami LAMP → standard LAMP

Moves a site off a Bitnami stack onto a plain Apache + PHP + MariaDB server, at
full fidelity: files, database, vhost, and permissions, verified against counts
taken at export time.

> **What prompted this:** AWS stopped shipping newer Bitnami-packaged Lightsail
> blueprints on **19 May 2026**, and deprecates the WordPress / WordPress
> Multisite / LAMP / Nginx / Node.js Bitnami blueprints on **19 Nov 2026**.
> Existing instances keep running, but stop getting updated images.

## Scope — this is not Lightsail-specific

Bitnami stacks are laid out the same way wherever they came from, so the scripts
work for any of them:

| Source | Layout the scripts detect |
|---|---|
| Lightsail blueprint | `/opt/bitnami/apache/htdocs/{site}` |
| EC2 / AWS Marketplace AMI | `/opt/bitnami/apache2/htdocs`, `/opt/bitnami/apps/{app}/htdocs` |
| Azure / GCP marketplace image | same as above |
| Native installer | `/opt/lampstack-8.2.x-0/…`, `~/stack/…` |
| Already migrated / stock | `/var/www`, `/var/www/html` |

Nothing is hardcoded — the stack root, Apache root, web root, vhost directory,
domains, database credentials, and WP-CLI are all discovered. Single-site and
multi-site hosts both work. `sudo ./export-site.sh --list` shows what it found;
if your layout is unusual, pass an absolute path instead of a site name.

The **target** is equally open: any Debian/Ubuntu (`sites-available` + `a2ensite`)
or RHEL/Amazon Linux (`conf.d`) Apache host. `probe-target.sh` works it out.

AWS's official migration path is WordPress **Tools → Export → Import XML**. It
carries posts and media and **loses** plugin settings, theme customizer state,
widgets, user password hashes, custom tables, and anything a plugin stores
outside the standard post tables. This does a full-fidelity move instead.

---

## The scripts

| Script | Runs on | What it does |
|---|---|---|
| `probe-target.sh` | new server | Read-only. Reports the target's layout; refuses nothing, changes nothing. |
| `audit-server.sh` | old server | Read-only. Emits `server-parity.md` — the server-wide settings a bundle cannot carry. |
| `export-site.sh` | old server | Packages one site into a single `.tar.gz`. Site stays live. |
| `restore-site.sh` | new server | Rebuilds the site from a bundle, then verifies it. Ships inside every bundle. |

All four take the site as an argument and discover everything else. Nothing about
any particular server is hardcoded.

---

## Per-site procedure

### 0. Before you start (once)

- Snapshot the old server first.
- Build the new one: any Ubuntu/Debian or RHEL host with Apache, PHP, and MariaDB. On Lightsail that is **Create instance → LAMP → Blueprint provider: Lightsail**, same region, same size or larger.
- Confirm ports 22, 80 and 443 are reachable — remember cloud firewalls (Lightsail instance firewall, EC2 security group) are separate from anything on the host.

> ⚠️ **Lightsail-packaged blueprints restrict port 22 to Lightsail's browser SSH
> client on launch.** Until you change it, `ssh` and `scp` from your own machine
> both fail, and you cannot get the scripts onto the server at all. On the
> instance's **Networking** tab, edit the SSH rule to allow your own IP — or
> `0.0.0.0/0` if your address is dynamic, in which case use key authentication
> only and narrow it back down once the migration is done. Ports 80 and 443 are
> already open on these images; SSH is the only rule you need to change.

### 1. Probe the new server (once)

```bash
scp probe-target.sh ubuntu@NEW_IP:~/ && ssh ubuntu@NEW_IP 'sudo ./probe-target.sh'
```

It prints the detected paths and exits non-zero on a blocker. Fix blockers before
going further — the most common one is that it cannot authenticate to MariaDB as
root, in which case export `MYSQL_ROOT_PASSWORD` (the LAMP blueprint stores it in
`~/application_credentials`) before running restore.

### 2. Audit the old server (once)

```bash
sudo ./audit-server.sh          # writes server-parity.md
```

Work through that checklist on the new instance **before the first restore**, so
the pilot site is tested on a like-for-like machine. See
[Server parity](#server-parity-the-part-the-bundle-cannot-carry) below.

### 3. Export

```bash
sudo ./export-site.sh --list          # what can be exported
sudo ./export-site.sh example         # site stays live and serving
```

Writes `~/migration/example-YYYYMMDD-HHMMSS.tar.gz` (mode 600). Repeat as often
as you like — it is non-destructive.

### 4. Transfer

```bash
scp bitnami@OLD_IP:~/migration/example-20260115-093000.tar.gz .
scp example-20260115-093000.tar.gz ubuntu@NEW_IP:~/
```

> SSH users differ by image — `bitnami` on Lightsail Bitnami blueprints,
> `ubuntu` / `ec2-user` / `azureuser` elsewhere. The scripts don't care: they read
> file ownership off the site directory rather than assuming a username.

### 5. Restore

```bash
ssh ubuntu@NEW_IP
tar -xzf example-20260115-093000.tar.gz
cd example-20260115-093000
sudo ./restore-site.sh --dry-run      # ALWAYS first — changes nothing
sudo ./restore-site.sh
```

The dry run prints every path it will write, the database it will create, and the
vhost it will generate. Nothing runs for real until that output is right.

Restore then verifies itself: home page, a permalink, `wp core is-installed`,
`wp db check`, content counts, and — the check that actually proves it — an
**exact row count for every table**, compared against the counts taken at export
time.

That last one is content-agnostic, so it verifies a WooCommerce catalogue, orders
in `wc_orders`, LearnDash progress, or any plugin's custom tables without knowing
anything about them. It matters because WordPress post and page counts only
describe a blog: on a WooCommerce store both can read zero while the entire
catalogue is missing.

Any mismatch is printed with `<--` and the script exits non-zero.

### 6. Verify before touching DNS

On your own machine, add to `/etc/hosts`:

```
NEW_IP  example.com www.example.com
```

Browse the site and `/wp-admin`. Check a few posts, a form, an image, and a
plugin settings page. **Remove the line afterwards.**

> ⚠️ **An HTTPS site needs `--selftest-tls` or you will be shown the wrong site.**
> WordPress redirects plain HTTP to its `siteurl`. If the site has no `:443`
> vhost on the new server yet, Apache falls back to the *first* HTTPS vhost it
> has — typically a site you migrated earlier — and that site's WordPress then
> redirects you to *its* domain. The symptom is "example.com sends me to
> the-site-i-migrated-last-week.com", which looks like a database problem and
> isn't. `sudo apache2ctl -S` shows which vhosts exist per port. Restore with
> `--selftest-tls`, and `a2dissite {site}-selftest` before running certbot.

### 7. Cut over

```bash
# On the old server, a final export capturing anything posted since step 3:
sudo ./export-site.sh example --maintenance
```

`--maintenance` puts WordPress in maintenance mode for the duration of the dump
so files and database are consistent. Transfer, then on the new server:

```bash
sudo ./restore-site.sh --force        # backs up the first restore before replacing it
```

Then point the domain at the new server. Which method depends on how many sites
share the old IP:

**One site on the server** — move the static IP. Detach it from the old instance,
attach it to the new one. DNS already points at that IP, so there is no
propagation delay at all, and rollback is moving it back.

**Several sites sharing one IP** — do **not** move the IP. It would send every
domain to the new server at once, including the ones you haven't migrated yet.
Instead:

1. Attach a **new** static IP to the new instance. Do this before any DNS change: a
   fresh instance has a dynamic public IP that changes whenever it is stopped and
   started.
2. Change only the migrated domain's `A` records — apex and `www` — from the old
   static IP to the new one.
3. Leave every other domain pointing at the old IP. They keep serving from the
   old server, untouched.
4. Repeat per site. Rollback for any one site is changing that A record back.

The cost is DNS propagation per site instead of an instant IP swap. Keep the TTL
low (60–300s) on the records you are about to move, and lower it a day ahead if
it is currently high.

Once all sites are migrated you can leave DNS as it is — the old static IP is
then free to release.

### 8. Certificate

Certificates cannot be moved between instances.

```bash
sudo apt-get install -y certbot python3-certbot-apache
sudo certbot --apache -d example.com -d www.example.com
```

certbot installs its own renewal timer — the monthly cron entry for
`renew-ssl-certs.sh` does **not** carry over (that script is lego/Bitnami-specific
and will not work on the new stack).

### 9. Confirm HTTP/2

Only possible once the certificate is in place — h2 only negotiates over TLS:

```bash
curl -sI --http2 https://example.com | head -1     # want: HTTP/2 200
```

If it says `HTTP/1.1`, see the HTTP/2 section below.

---

## Server parity — the part the bundle cannot carry

`server-parity.md` (from `audit-server.sh`, also included in every bundle under
`reference/`) covers these. They are server-wide, so do them **once**, not per
site.

### HTTP/2 — the one that fails silently

Bitnami ships `mpm_event` + PHP-FPM, so HTTP/2 works out of the box. A stock
Ubuntu `apache2` defaults to **`mpm_prefork` + `mod_php`, which cannot serve
HTTP/2 at all**. Your sites will work perfectly and quietly drop to HTTP/1.1.
Nothing warns you.

```bash
PHPVER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
sudo apt-get update && sudo apt-get install -y "php${PHPVER}-fpm"
sudo a2dismod "php${PHPVER}" mpm_prefork
sudo a2enmod mpm_event proxy_fcgi setenvif http2
sudo a2enconf "php${PHPVER}-fpm"
sudo systemctl restart "php${PHPVER}-fpm" apache2
```

Then add `Protocols h2 h2c http/1.1` to the HTTPS vhosts (or once, globally).

Moving to PHP-FPM also relocates the PHP settings: after the switch, the ini that
matters is `/etc/php/${PHPVER}/fpm/php.ini`, not the CLI one.

### The rest

| Item | Where it's covered |
|---|---|
| PHP ini values (`memory_limit`, `upload_max_filesize`, `max_input_vars`, OPcache) | `server-parity.md` §3 |
| Missing PHP extensions (`redis`, `imagick`) | `restore-site.sh` warns; §3 lists them |
| MariaDB tuning (`innodb_buffer_pool_size`) | `server-parity.md` §4 |
| Redis — not installed on the new image | `server-parity.md` §5 |
| Compression (`mod_deflate` / `mod_brotli`) | `server-parity.md` §2 |
| KeepAlive, security headers, module list | `server-parity.md` §6 |
| Cron, swap, timezone, fail2ban, firewall | `server-parity.md` §7 |
| SSL — reissue, never copy | `server-parity.md` §8 |

### Redis object cache

The object-cache drop-in is deliberately **not** restored, so a site always comes
up working whether or not Redis exists on the new server. Once Redis is installed:

```bash
sudo apt-get install -y redis-server php-redis
sudo -u ubuntu wp --path=/var/www/example redis enable
```

Keep the per-site database indexes from `server-parity.md` §5 so the sites stay
isolated from each other.

---

## Rollback

The old server is never modified. At any point before step 7 there is nothing to
roll back. After step 7, move the static IP back to the old instance.

`restore-site.sh --force` backs up the existing document root and database into
`pre-restore-backup-<timestamp>/` inside the bundle directory before replacing
anything.

---

## What order to migrate in

With more than one site on the server, the order matters more than it looks. Work
from lowest risk to highest:

1. **Pilot with a low-traffic WordPress site.** Not a static one — you want the database, permissions, and WP-CLI verification all exercised before you trust the tooling. Whatever is going to go wrong surfaces here.
2. **Then the rest of the quiet sites**, WordPress before static. Static sites are the fastest of all (files and vhost only, no database) but they prove the least.
3. **Busiest site last.** By then the server-wide work — HTTP/2, PHP settings, the FPM pool, Redis — is done and proven, so your most important site meets a machine that has already been shaken out.

The server-wide items only need doing once. After the pilot, each additional site
is just export, transfer, dry run, restore, verify, DNS.

Do not delete the old server until every site has been verified and has run on
the new one for a few days.

---

## Bundle hygiene

Every bundle contains a full database dump — including user password hashes — and
the original `wp-config.php`. They are written mode 600. **Delete them from your local
machine and from both servers once the migration is signed off.**

```bash
rm -f ~/migration/*.tar.gz                 # old server
rm -rf ~/example-*/ ~/example-*.tar.gz     # new server
```
