# Redmine Installer for Ubuntu 24.04

Automated deployment of **Redmine 7.0.2** with a private Ruby 3.4 build,
PostgreSQL, Puma, systemd, Nginx, and optional Let's Encrypt TLS.

> **Target OS:** Ubuntu Server 24.04. The installer checks the OS
> release and exits on other versions.
>
> **Default URL:** `https://pm.netaport.com`
>
> This installer is tailored for a server with an existing Nginx
> installation. Review the script and take backups before running it on
> a production server.

## Features

-   Installs Redmine under `/opt/redmine`.
-   Builds a private Ruby 3.4.x runtime under `/opt/redmine/ruby`.
-   Uses a dedicated PostgreSQL database and role named `redmine`.
-   Runs Puma on `127.0.0.1:3080` by default.
-   Creates a systemd service and log rotation configuration.
-   Adds a separate Nginx virtual host.
-   Attempts Let's Encrypt TLS when DNS and Certbot prerequisites are
    met.
-   Provides preflight checks and installation logs.

## Requirements

-   Ubuntu Server **24.04**.
-   Root/sudo access and internet connectivity.
-   Nginx already installed, running, and using
    `/etc/nginx/sites-available` and `/etc/nginx/sites-enabled`.
-   At least 1,500 MB available memory and 4,000 MB free disk space on
    the filesystem containing `/opt` (the script's minimum checks).
-   Free Puma port (default `3080`).
-   For HTTPS, the domain must resolve publicly to this server, ports
    80/443 must be reachable, and Certbot with the Nginx plugin must be
    available.

The installer simulates APT package installation first. It aborts if
packages would be removed and checks for selected critical package
upgrades. Review the script before changing `ALLOW_UPGRADES`.

## Quick start

``` bash
git clone https://github.com/redhatmurali/redmine.git
cd redmine
less install-redmine.sh
```

### 1. Run preflight checks

``` bash
sudo PREFLIGHT_ONLY=1 bash install-redmine.sh
```

Preflight checks the OS, memory/disk, Nginx, port availability, DNS/TLS
conditions, and APT's proposed package changes. It does not install
Redmine or its dependencies. **It does run `apt-get update`, refreshing
local package indexes**, so it is not strictly read-only.

Resolve reported issues and run preflight again before installation.

### 2. Install

``` bash
sudo bash install-redmine.sh
```

The first run may take approximately **15--25 minutes**, depending on
hardware and network speed, because Ruby is compiled locally. Progress
is written to `/var/log/redmine-install.log`.

## Configuration options

Example using a custom domain:

``` bash
sudo env DOMAIN=redmine.example.com LE_EMAIL=admin@example.com bash install-redmine.sh
```

  -----------------------------------------------------------------------
  Variable                Default                 Purpose
  ----------------------- ----------------------- -----------------------
  `DOMAIN`                `pm.netaport.com`       Host name and Redmine
                                                  URL

  `REDMINE_VERSION`       `7.0.2`                 Redmine release; a
                                                  verified SHA-256
                                                  checksum is required

  `RUBY_SERIES`           `3.4`                   Ruby minor series to
                                                  build

  `APP_PORT`              `3080`                  Puma loopback port

  `PUMA_WORKERS`          `2`                     Puma workers; `0`
                                                  selects single mode

  `BUILD_JOBS`            `2`                     Parallel build jobs

  `MEMORY_MAX`            `1500M`                 systemd memory limit

  `REDMINE_LANG`          `en`                    Language for default
                                                  data

  `ENABLE_TLS`            `yes`                   Set to `no` to skip the
                                                  TLS attempt

  `LE_EMAIL`              empty                   Optional Let's Encrypt
                                                  registration email

  `ALLOW_UPGRADES`        `0`                     Set to `1` only after
                                                  reviewing flagged
                                                  package upgrades

  `PREFLIGHT_ONLY`        `0`                     Set to `1` to stop
                                                  after preflight
  -----------------------------------------------------------------------

**Checksum note:** Only selected Redmine releases have checksums built
into the script. If selecting another version, set `REDMINE_SHA256` only
after verifying it against a trusted official release source. Do not
bypass checksum validation.

## After installation

The installer prints the URL, paths, database port, and credentials
location. The default state file is:

``` text
/root/.redmine-pm.netaport.com.env
```

For a custom domain, the filename includes that domain. It contains
database credentials and, on first installation, the generated
administrator password. Keep it root-only and never commit or share it.

The initial administrator login is `admin`. Change the generated
password immediately after signing in. On an existing installation, the
script may leave an existing administrator password unchanged.

## Verify the installation

``` bash
sudo systemctl status redmine --no-pager
sudo journalctl -u redmine -n 100 --no-pager
sudo nginx -t
curl -I http://127.0.0.1:3080/
curl -I https://pm.netaport.com/
```

Replace the domain and port if customized. If TLS was skipped, test the
HTTP URL instead.

## Important paths

  Item                              Path
  --------------------------------- ----------------------------------------------
  Current application symlink       `/opt/redmine/current`
  Versioned application directory   `/opt/redmine/redmine-7.0.2`
  Private Ruby                      `/opt/redmine/ruby`
  Attachments                       `/opt/redmine/files`
  Nginx virtual host                `/etc/nginx/sites-available/pm.netaport.com`
  systemd unit                      `/etc/systemd/system/redmine.service`
  Installer log                     `/var/log/redmine-install.log`
  Redmine production log            `/opt/redmine/current/log/production.log`

Paths containing the default domain or version differ if you customize
those settings.

## Service commands

``` bash
sudo systemctl status redmine --no-pager
sudo systemctl restart redmine
sudo systemctl stop redmine
sudo systemctl start redmine
sudo systemctl enable redmine
sudo journalctl -fu redmine
```

## Email configuration

SMTP is not fully configured automatically. Add your SMTP settings to
Redmine's configuration, protect the file, and restart the service:

``` bash
sudo nano /opt/redmine/current/config/configuration.yml
sudo systemctl restart redmine
```

Do not publish SMTP credentials in this repository.

## Backups

Back up **both** the PostgreSQL database and uploaded attachments. Store
backups off-server and test restoration regularly.

``` bash
sudo -u postgres pg_dump redmine | gzip > redmine-db-$(date +%F).sql.gz
sudo tar -czf redmine-files-$(date +%F).tar.gz -C /opt/redmine files
```

Protect backups because they may contain sensitive project data.

## Plugins

Install only plugins compatible with your Redmine version. Review plugin
code and instructions, and back up the database before changing plugins.

The script creates a `redmine-run` helper. Example:

``` bash
sudo redmine-run bundle install
sudo redmine-run bundle exec rake redmine:plugins:migrate
sudo systemctl restart redmine
```

## Important cautions

-   The installer is specifically tailored for Ubuntu 24.04 and exits on
    other OS versions.
-   It expects existing Nginx and does not configure public DNS.
-   It creates a new Nginx virtual host; check existing configurations
    before running.
-   It attempts to avoid upgrading existing packages and aborts if APT
    proposes removals. Do not set `ALLOW_UPGRADES=1` casually.
-   PostgreSQL may be installed or reused. Review the script if the
    server already has a PostgreSQL deployment.
-   Preflight refreshes APT package indexes even though it does not
    install Redmine.
-   Re-running is intended to be idempotent, but is not a substitute for
    backups or a recovery plan.
-   Test on a staging VM before production deployment.

## Troubleshooting

1.  OS: `cat /etc/os-release`
2.  Memory and disk: `free -h` and `df -h /opt`
3.  Nginx syntax: `sudo nginx -t`
4.  Puma port: `sudo ss -ltnp | grep ':3080'`
5.  Service log: `sudo journalctl -u redmine -n 100 --no-pager`
6.  Production log:
    `sudo tail -n 100 /opt/redmine/current/log/production.log`
7.  Installer log: `sudo tail -n 150 /var/log/redmine-install.log`
8.  For HTTPS, confirm public DNS points to this server and ports 80/443
    are reachable.

## Official references

-   [Official Redmine installation
    guide](https://www.redmine.org/projects/redmine/wiki/RedmineInstall)
-   [Official Redmine
    downloads](https://www.redmine.org/projects/redmine/wiki/Download)

## License

This repository does not currently specify a license. Do not assume the
installer scripts are licensed for redistribution or reuse unless a
license is added.
