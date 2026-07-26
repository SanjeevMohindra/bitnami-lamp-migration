# bitnami-lamp-migrate

Move a site off a **Bitnami LAMP or WordPress stack** onto a plain Apache + PHP +
MariaDB server — at full fidelity, and verified.

Four bash scripts. No dependencies beyond what a stock Bitnami image already
ships. Site name is the only argument you pass.

```bash
# On the old (Bitnami) server
sudo ./audit-server.sh                # once — server-parity checklist
sudo ./export-site.sh mysite          # per site; site stays live

# On the new server, from inside the extracted bundle
sudo ./restore-site.sh --dry-run      # always first — changes nothing
sudo ./restore-site.sh
```

---

## Why this exists

AWS stopped shipping newer Bitnami-packaged Lightsail blueprints on **19 May
2026** and deprecates the WordPress, WordPress Multisite, LAMP, Nginx and Node.js
blueprints on **19 November 2026**. Existing instances keep running — AWS is
explicit that you are not required to migrate — but they stop receiving updated
images.

The officially suggested route is the WordPress **Tools → Export → Import XML**
path. It carries posts and media, and loses plugin settings, theme customizer
state, widget placement, user password hashes, and any custom database table. On
a WooCommerce store it misses orders entirely, because HPOS moved them out of
`wp_posts` into `wc_orders`.

These scripts move the whole site instead — files, database, vhost, permissions —
and then prove it worked.

---

## Not just Lightsail

Bitnami looks nearly identical wherever it came from, so the scripts detect the
stack rather than assuming a path:

| Source | Layout detected |
|---|---|
| Lightsail blueprint | `/opt/bitnami/apache/htdocs/{site}` |
| EC2 / AWS Marketplace AMI | `/opt/bitnami/apache2/htdocs` |
| Azure / GCP marketplace image | `/opt/bitnami/apps/{app}/htdocs` |
| Native installer | `/opt/lampstack-*/…`, `~/stack/…` |
| Single-app image | `/opt/bitnami/wordpress` |
| Stock / already migrated | `/var/www`, `/var/www/html` |

`sudo ./export-site.sh --list` shows what it found on your machine. If your
layout is stranger than all of these, pass an absolute path instead of a site
name.

The **target** is equally open — any Debian/Ubuntu host using
`sites-available` + `a2ensite`, or RHEL/Amazon Linux using `conf.d`.
`probe-target.sh` works it out and `restore-site.sh` adapts to what it finds.

Static (non-WordPress) sites work too. The database, WP-CLI and Redis steps are
skipped automatically based on whether `wp-config.php` exists.

---

## The scripts

| Script | Runs on | What it does |
|---|---|---|
| `probe-target.sh` | new server | **Read-only.** Reports Apache paths, vhost convention, doc-root base, web user, PHP (CLI *and* web SAPI), MariaDB, Redis, WP-CLI, certbot. |
| `audit-server.sh` | old server | **Read-only.** Emits `server-parity.md` — the server-wide settings a per-site bundle cannot carry. |
| `export-site.sh` | old server | Packages one site into a single `.tar.gz`. The site stays live. |
| `restore-site.sh` | new server | Rebuilds the site from a bundle, then verifies it against counts taken at export time. |

`restore-site.sh` and `probe-target.sh` are packed **inside every bundle**, so on
the new server you extract a tarball and run the copy already sitting in it.

### What's in a bundle

```
mysite-20260115-093000/
├── manifest.env          # shell-sourceable — no jq dependency
├── files.tar.gz          # the site tree (caches and logs excluded)
├── database.sql.gz       # mysqldump, WordPress sites only
├── wp-config.php.orig    # preserved verbatim, so salts survive the move
├── vhosts/               # the site's vhost files
├── reference/            # plugins, themes, php modules, table row counts,
│                         #   server-parity.md
├── checksums.sha256
├── restore-site.sh
└── probe-target.sh
```

---

## How it verifies the move

This is the part most migration guides skip entirely.

After restoring, the script checks the home page, a permalink, `wp core
is-installed`, `wp db check`, content counts — and **an exact row count for every
table in the database**, compared against counts taken at export time.

Row counts are the only check that works regardless of what the site is built
from. Post and page counts describe a blog; they say nothing about products,
orders, membership records, or course progress. A WooCommerce store can report
zero posts while its entire catalogue is missing.

Volatile tables (`*options`, `*_queue`, `*_log`, `*cache`, `*_sessions`,
`actionscheduler_*`) are allowed to *grow* — WordPress writes transients and cron
entries simply by booting — but a table that **shrinks** still fails the run.
Transients are excluded from options counts on both sides so cache churn never
reads as data loss.

Any mismatch prints with `<--` and the script exits non-zero.

---

## Things that will bite you

Full detail in [MIGRATION.md](MIGRATION.md). The short version:

- **HTTP/2 dies silently.** Bitnami runs `mpm_event` + PHP-FPM. Stock Ubuntu/Debian `apache2` defaults to `mpm_prefork` + `mod_php`, which cannot serve HTTP/2 at all. Sites work fine and quietly fall back to HTTP/1.1.
- **`php -v` may not be the PHP serving your pages.** A box can run PHP 8.5 on the CLI and mod_php 8.4 under Apache. Extensions install per version. `probe-target.sh` reports both and warns when they differ.
- **The new database can be older than the old one.** Vendor images pin whatever LTS they shipped with. A dump from a newer MariaDB can carry collations the target has never heard of; `restore-site.sh` refuses to import rather than failing halfway.
- **A restored HTTPS site shows you a *different* site.** With no `:443` vhost yet, Apache falls back to the first HTTPS vhost on the box. Use `--selftest-tls`.
- **SSL certificates cannot be transferred.** Reissue with certbot after DNS moves.
- **Redis is usually not on the new image.** The object-cache drop-in is deliberately never carried in the bundle, so sites come up working either way. Restore re-enables it automatically when the target has Redis.

---

## Requirements

- bash, tar, gzip, `mysqldump`, and ideally WP-CLI on the source
- root (via `sudo`) on both servers
- WP-CLI on the target for content-count verification (row counts work without it)

---

## Safety

- Every script that changes anything has `--dry-run`, and it prints every path, database and vhost it would touch.
- `probe-target.sh` and `audit-server.sh` never write anything.
- `restore-site.sh --force` backs up the existing document root and database before replacing them.
- The source server is never modified. Rollback is a DNS change.
- Bundles are written mode `600` and contain a full database dump, including user password hashes, plus the original `wp-config.php`. **Delete them from every machine once the migration is signed off.**
- Database passwords are regenerated on the new server. The old one never leaves the old server.

---

## Licence

MIT — see [LICENSE](LICENSE).

Written while moving six sites off a Bitnami stack. Issues and pull requests
welcome, particularly for Bitnami layouts the detection doesn't recognise yet.
