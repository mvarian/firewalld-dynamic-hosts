# Known Constraints

Observed from `centos/fwdynhosts.sh`, `debian-nft/fwdynhosts.sh`, `debian-ufw/fwdynhosts.sh`, the JSON examples, and `README.md`.

## Where it runs

- Internal servers. Three variants: CentOS with firewalld, Debian with nftables (`debian-nft/`), Debian with ufw (`debian-ufw/`).
- Install path is fixed: `/opt/fwdynhosts/fwdynhosts.sh` and `/opt/fwdynhosts/dynhosts.json`. The ufw variant also reads `/opt/fwdynhosts/zones.json`. The nftables rules file is copied once to `/etc/nftables.conf`. Tests point the CentOS and Debian nftables scripts at another config with `FWDYNHOSTS_CONFIG` and another state dir with `FWDYNHOSTS_STATE_DIR`. The installed path does not change. The ufw script does not take a config path argument.
- README schedules the refresh hourly from root crontab. `debian-nft/fwdynhosts.sh` does not schedule itself and takes no mode flag. A DNS change is visible only on the next successful run. Until then the previous address stays in the set.
- The live `dynhosts.json` is gitignored. Commit `dynhosts.json.example` only. The example addresses (`127.0.0.1`, `1.1.1.1`, `example.com`, `archive.org`) are templates, not this site's allow-list.

## What the firewall already has to provide

- Debian nftables refresh replaces named sets. The policy is each server's hand-written `/etc/nftables.conf`. The script does not install it and does not rewrite it. `debian-nft/nftables.conf.example` is an example of that file, not something to install. CentOS replaces sources on each named zone, and replaces services, ports, or target only when that key is present. It rejects target `ACCEPT` on every zone, and it rejects `ssh`, `22/tcp`, and `22/udp` on zones named `public` or `cloudflare`. It does not bind interfaces.
- CentOS: an old file of `zone`, `ips`, and `hostnames` still only replaces sources. The example no longer names `public`. A live file that still names `public` is valid. The script does not add or remove interfaces.
- Debian nftables: the table name is `family=firewall` in `debian-nft/fwdynhosts.sh`. The script updates `ip` sets only. The set name comes from JSON (`set`, or `zone` when `set` is absent). `comment` is ignored. A duplicate set name is an error. The rules file owns the accept rules.
- Debian ufw: each zone's ports and protocols come from `zones.json`. Who may use that zone comes from the matching `zone` in `dynhosts.json`. `0.0.0.0/0` in `ips` is any IPv4 address. The script writes those ufw rules. It does not write v6 rules. The names `public` and `management` in the example are not special.

## Resolution

- Debian nftables resolves every A record from `host -W 5` (`has address`). AAAA is ignored. A failed name, or a name with no address, exits before nft. There is no last-known-good file: the set already loaded is left as it is. UFW is IPv4 only. Its resolver line is `host $hostname | awk '/has address/ { print $4 }' | head -n1`. Extra A records are ignored there. CentOS resolves every A and AAAA from `host -W 5`.
- CentOS install names `jq`, `bind-utils` (`host`), `firewalld`, and `util-linux` (`flock`). `curl` is required only for `--refresh-cloudflare`. Debian nftables install names `jq`, a package that provides `host`, `nftables`, and `util-linux` (`flock`). UFW install names `ufw` and `jq`. The ufw script also calls `host`.
- A failed ufw lookup still continues. CentOS and Debian nftables exit before any firewall change when a lookup fails.

## Failure and concurrency

- Debian ufw does not set `set -e`, `set -u`, or `set -o pipefail`. A failed `jq`, `host`, or `ufw` does not stop the rest of that run. That script ends with `printf "Done.\n"`, so cron sees success when that printf runs. Debian nftables and CentOS use `set -euo pipefail`. Debian nftables exits 1 on failure and prints `Done.` only after success. CentOS exits 1 on failure and 2 on usage. On debian-nft that option is safe because the set change is one `nft -f` transaction, not a clear-then-add loop in the shell.
- The ufw script has no lock. Debian nftables and CentOS take an exclusive non-blocking `flock` and exit 1 when the lock is busy or `flock` is missing. A busy lock does not call nft.
- JSON keys differ by variant. CentOS objects use `zone`, `ips`, `hostnames`, and optional `services`, `ports`, and `target`. Debian nftables objects use `set` or `zone`, optional `comment`, `ips`, `hostnames`. The set name is `set` when present, otherwise `zone`. Unknown keys fail before any nft call. A duplicate name fails. UFW dynhosts objects use `zone`, `ips`, `hostnames`. UFW `zones.json` objects use `zone` and `rules` of `{ "port", "proto" }`. A missing `ips` or `hostnames` key makes `jq` fail for that ufw expansion; the ufw script does not abort on that failure. CentOS rejects a missing required key, an unknown key, and a duplicate zone name.

## Debian nftables persistence is two tables

`debian-nft/fwdynhosts.sh` does not write `/etc/nftables.conf`. The rules file is copied once and loaded by hand. The script only runs `nft -f` on a file that flushes and refills the named `ip` sets. A failed lookup or an empty address list exits before that. Do not put the old truncate-and-`nft list table` save back.

The CentOS script does not do this. It uses `firewall-cmd --permanent` and one `--reload` only when a permanent change was made. A no-change run does not reload, so runtime-only rules such as fail2ban's stay.

The ufw script does not do this. `ufw allow` and `ufw delete` write `/etc/ufw/user.rules`. The script then runs `ufw reload`. A rule is replaced only when its comment equals a zone named in `dynhosts.json`.

## Shell guide

`AI_PROFILE/languages/shell/` (style, patterns, anti-patterns) was derived partly from these scripts. CentOS and Debian nftables quote expansions, check status, take a lock, and use `set -euo pipefail`. Braces for an nft set change go in the script file passed to `nft -f`, not through the shell. UFW still has the older form: unquoted ufw lines, no lock, and no `set -e`. Do not put those older habits back on debian-nft. The shell guide's warning against `set -e` on a clear-then-add loop does not apply to debian-nft, because the set change is one transaction. This directory still decides what changes here.
