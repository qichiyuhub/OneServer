# OneServer

[![Build](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml/badge.svg)](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml)
[![Latest release](https://img.shields.io/github/v/release/qichiyuhub/OneServer?display_name=tag&sort=semver)](https://github.com/qichiyuhub/OneServer/releases/latest)
[![License](https://img.shields.io/github/license/qichiyuhub/OneServer)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%204.3%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

[简体中文](README.md) | English

## Overview

OneServer is a Bash administration tool for a single Debian or Ubuntu server. It sets up and maintains web services, databases, containers, and baseline security, from an interactive menu or a scriptable CLI.

- **Changes happen in the terminal.** The web dashboard is read-only, and passwords live in a root-only store.
- **Small footprint.** Plain Bash, no third-party runtime. With the dashboard off, nothing of OneServer stays resident.
- **Stays out of the way.** Services remain under systemd, APT, and their own config files.
- **Predictable.** Preview a change before it runs, re-run it safely. When something fails, steps that can be undone safely are rolled back, and everything else is listed exactly as it happened.
- **Removes cleanly.** Every package and file it installs is recorded, so uninstalling reverses it. Your data stays.
- **Menu or CLI.** Interactive menus for day-to-day work, JSON output for scripts.
- **One place to look.** The read-only dashboard shows components, services, ports, firewall rules, and logs.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/qichiyuhub/OneServer/main/install.sh | bash
```

Run `os` for the interactive menu, or list everything from the CLI:

```bash
oneserver --help
oneserver <command> --help
```

## Requirements

- Debian or Ubuntu, root, systemd
- Bash 4.3 or newer, APT, dpkg, util-linux
- Working APT repositories and outbound network access
- `curl`, `tar`, `coreutils`, `ca-certificates` — installed automatically if missing
- `rclone` — only for remote backups

Podman must be 4.4 or newer. Debian 13 and Ubuntu 24.04 (and later) ship a suitable version; on older releases use Docker, or install a recent Podman yourself.

## What it manages

| Area | Commands |
| --- | --- |
| Websites | Sites, Caddy config, WordPress deployment, PHP config updates |
| Databases | MariaDB databases and accounts |
| Containers | Docker, Podman, Compose projects, images, containers, volumes |
| Security | Security audit, UFW, SSH hardening, system and unattended updates, network detection, secret store |
| Backups | Backup and restore, with rclone remotes and external-backup import |
| Monitoring | Read-only dashboard, diagnostics, component status, activity log |
| Apps | Install and remove Caddy, PHP-FPM, MariaDB, Valkey, Node.js, Docker, Podman |
| Tools | Self-update, disk cleanup, theme preview |

## Updates and removal

To update, or use Tools › Self-update in the menu:

```bash
oneserver update check
oneserver update run
```

To remove OneServer itself — no menu entry for this one:

```bash
bash /opt/oneserver/uninstall.sh
```

The uninstaller asks about components, backup archives, secrets and config, and the toolkit itself. Each can be kept, and irreversible steps require typing the full name to confirm; say yes to all four and every package, file and trace OneServer installed is removed. **Your data is not part of that** — databases, site directories, certificates and user config are never deleted automatically; the uninstaller just prints where they are and leaves them to you. Remove components here if you want them gone — OneServer is the only thing that records which packages and files belong to which component, and that record goes with it.

If you are done with the server, run Tools › Disk cleanup before uninstalling.

## Operational notes

- Preview changes with `--dry-run`.
- `--yes` does not apply to irreversible operations; deletions still require typing the full name.
- Do not edit the state or secret files by hand.
- Keep a second SSH session or your provider's console open when changing SSH or firewall rules.
- Verify the archive and the target before restoring.
- Run `oneserver doctor` when something looks wrong; recovery steps are in the [operations runbook](docs/OPERATIONS.md) (Simplified Chinese).
- The dashboard uses Basic Auth and listens on all interfaces by default. Turn the password off and it narrows to localhost, or to a network you specify. It serves plain HTTP, so put it behind an HTTPS reverse proxy before exposing it.
- Prompts and terminal output are currently in Simplified Chinese.

## License

OneServer is licensed under the [MIT License](LICENSE). Third-party software and incorporated material remain subject to their respective licenses; see [Third-party notices](docs/THIRD_PARTY.md).
