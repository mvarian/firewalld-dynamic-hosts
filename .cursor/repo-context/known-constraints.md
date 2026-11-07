# Known Constraints

Observed from `centos/fwdynhosts.sh`, `debian-nft/fwdynhosts.sh`, `debian-ufw/fwdynhosts.sh`, the JSON examples, and `README.md`.

## Where it runs

- Internal servers. Three variants: CentOS with firewalld, Debian with nftables (`debian-nft/`), Debian with ufw (`debian-ufw/`).
- Install path is fixed: `/opt/fwdynhosts/fwdynhosts.sh` and `/opt/fwdynhosts/dynhosts.json`. The ufw variant also reads `/opt/fwdynhosts/zones.json`. CentOS accepts `--config` and `--state-dir`, and the default config path is still `/opt/fwdynhosts/dynhosts.json`. The Debian scripts do not take a config path argument.
- README schedules the script hourly from root crontab. The scripts themselves do not schedule anything. A DNS change is visible only on the next successful run. Until then the previous address stays allowed, because the list is whatever the last run wrote.
- The live `dynhosts.json` is gitignored. Commit `dynhosts.json.example` only. The example addresses (`127.0.0.1`, `1.1.1.1`, `example.com`, `archive.org`) are templates, not this site's allow-list.

## What the firewall already has to provide

- Debian nftables does not open SSH. It replaces an address list the host firewall already uses. CentOS replaces sources on each named zone, and replaces services, ports, or target only when that key is present. It rejects target `ACCEPT` on every zone, and it rejects `ssh`, `22/tcp`, and `22/udp` on zones named `public` or `cloudflare`. It does not bind interfaces.
- CentOS: an old file of `zone`, `ips`, and `hostnames` still only replaces sources. The example no longer names `public`. A live file that still names `public` is valid. When the config names `cloudflare`, zone `public` must already include interface `eth0`, and `cloudflare` must not have an interface. The script does not add `eth0` and does not remove an interface.
- Debian nftables: the table is hardcoded as `firewall` in `debian-nft/fwdynhosts.sh`. The set name comes from JSON (`management` in the example). The accept rules for that set are outside the script. `family="firewall"` must stay the table name.
- Debian ufw: each zone's ports and protocols come from `zones.json`. Who may use that zone comes from the matching `zone` in `dynhosts.json`. `0.0.0.0/0` in `ips` is any IPv4 address. The script writes those ufw rules. It does not write v6 rules. The names `public` and `management` in the example are not special.

## Resolution

- Debian nftables and ufw are IPv4 only. Their resolver line is `host $hostname | awk '/has address/ { print $4 }' | head -n1`. `has IPv6 address` is ignored. Extra A records are ignored. CentOS resolves every validated A and AAAA from `host -W 5`, and rejects loopback, link-local, multicast, and unspecified answers for that name.
- CentOS install names `jq`, `bind-utils` (`host`), `firewalld`, and `util-linux` (`flock`). `curl` is required only for `--refresh-cloudflare`. Debian install installs `jq`. The Debian script also calls `host`, and the README does not name a package for it.
- A failed Debian lookup still continues. CentOS uses the last-known-good addresses for that name when they exist. If they do not, it exits before any firewall change and does not delete current sources.

## Failure and concurrency

- Debian nftables and ufw do not set `set -e`, `set -u`, or `set -o pipefail`. A failed `jq`, `host`, `nft`, or `ufw` does not stop the rest of those runs. Those scripts end with `printf "Done.\n"`, so cron sees success when that printf runs. CentOS uses `set -Eeuo pipefail`, exits 1 on failure and 2 on usage, and prints `Done.` only after success.
- Debian scripts have no lock. Overlapping Debian runs can interleave removes and adds. CentOS takes an exclusive non-blocking `flock` on `$STATE_DIR/fwdynhosts.lock` and exits 1 when the lock is busy or `flock` is missing.
- JSON keys differ by variant. CentOS objects use `zone`, `ips`, `hostnames`, and optional `services`, `ports`, and `target`. Debian nftables objects use `set` or `zone`, optional `comment`, `ips`, `hostnames`. The set name is `set` when present, otherwise `zone`. UFW dynhosts objects use `zone`, `ips`, `hostnames`. UFW `zones.json` objects use `zone` and `rules` of `{ "port", "proto" }`. A missing `ips` or `hostnames` key makes `jq` fail for that Debian expansion; the Debian script does not abort on that failure. CentOS rejects a missing required key, an unknown key, and a duplicate zone name.

## Debian nftables persistence is two tables

After the set loop, `debian-nft/fwdynhosts.sh` rewrites `/etc/nftables.conf` so the next load deletes and recreates `ip firewall` and `ip6 firewall` only. Fail2ban and Docker tables are not in that file. Comments that existed only in the previous copy of those two tables are gone.

The CentOS script does not do this. It uses `firewall-cmd --permanent` and one `--reload` only when a permanent change or runtime drift on a managed zone needs it. Before the first permanent change it copies zone XML into `/var/lib/fwdynhosts` and records `in-progress`. A crash is restored from that backup on the next run. `--rollback` restores the newest backup.

The ufw script does not do this. `ufw allow` and `ufw delete` write `/etc/ufw/user.rules`. The script then runs `ufw reload`. A rule is replaced only when its comment equals a zone named in `dynhosts.json`.

## Shell guide

`AI_PROFILE/languages/shell/` (style, patterns, anti-patterns) was derived partly from these scripts. CentOS `fwdynhosts.sh` now quotes expansions, checks status, takes a lock, and uses `set -Eeuo pipefail`. Debian nftables and ufw still have the older form: unquoted nft or ufw lines, no lock, and no `set -e`. The guide describes what new code should do. It does not authorize sweeping the Debian scripts. This directory still decides what changes here.
