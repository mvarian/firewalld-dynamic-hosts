# Known Constraints

Observed from `centos/fwdynhosts.sh`, `debian-nft/fwdynhosts.sh`, `debian-ufw/fwdynhosts.sh`, the JSON examples, and `README.md`.

## Where it runs

- Internal servers. Three variants: CentOS with firewalld, Debian with nftables (`debian-nft/`), Debian with ufw (`debian-ufw/`).
- Install path is fixed: `/opt/fwdynhosts/fwdynhosts.sh` and `/opt/fwdynhosts/dynhosts.json`. The ufw variant also reads `/opt/fwdynhosts/zones.json`. The scripts do not take a config path argument.
- README schedules the script hourly from root crontab. The scripts themselves do not schedule anything. A DNS change is visible only on the next successful run. Until then the previous address stays allowed, because the list is whatever the last run wrote.
- The live `dynhosts.json` is gitignored. Commit `dynhosts.json.example` only. The example addresses (`127.0.0.1`, `1.1.1.1`, `example.com`, `archive.org`) are templates, not this site's allow-list.

## What the firewall already has to provide

- CentOS and Debian nftables do not open SSH. They replace an address list the host firewall already uses.
- CentOS: the zone must already allow the services that should be reachable from those sources. Replacing sources on `trusted` and also on `public` follows the example file; the effect depends on what each zone already allows and which interfaces are bound to it.
- Debian nftables: the table is hardcoded as `firewall` in `debian-nft/fwdynhosts.sh`. The set name comes from JSON (`management` in the example). The accept rules for that set are outside the script. `family="firewall"` must stay the table name.
- Debian ufw: each zone's ports and protocols come from `zones.json`. Who may use that zone comes from the matching `zone` in `dynhosts.json`. `0.0.0.0/0` in `ips` is any IPv4 address. The script writes those ufw rules. It does not write v6 rules. The names `public` and `management` in the example are not special.

## Resolution

- IPv4 only. The resolver line is `host $hostname | awk '/has address/ { print $4 }' | head -n1`. `has IPv6 address` is ignored. Extra A records are ignored.
- CentOS install installs `jq` and `bind-utils` (`host`). Debian install installs `jq`. The Debian script also calls `host`, and the README does not name a package for it.
- A failed lookup still continues. Nothing tests that `hostip` is non-empty before `firewall-cmd`, `nft`, or `ufw` is invoked.

## Failure and concurrency

- None of the scripts set `set -e`, `set -u`, or `set -o pipefail`. A failed `jq`, `host`, `firewall-cmd`, `nft`, or `ufw` does not stop the rest of the run. Each script ends with `printf "Done.\n"`, so cron sees success when that printf runs.
- There is no lock. Overlapping runs can interleave removes and adds.
- JSON keys differ by variant. CentOS objects use `zone`, `ips`, `hostnames`. Debian nftables objects use `set` or `zone`, optional `comment`, `ips`, `hostnames`. The set name is `set` when present, otherwise `zone`. UFW dynhosts objects use `zone`, `ips`, `hostnames`. UFW `zones.json` objects use `zone` and `rules` of `{ "port", "proto" }`. A missing `ips` or `hostnames` key makes `jq` fail for that expansion; the script does not abort on that failure.

## Debian nftables persistence is two tables

After the set loop, `debian-nft/fwdynhosts.sh` rewrites `/etc/nftables.conf` so the next load deletes and recreates `ip firewall` and `ip6 firewall` only. Fail2ban and Docker tables are not in that file. Comments that existed only in the previous copy of those two tables are gone.

The CentOS script does not do this. It uses `firewall-cmd --permanent` and one `--reload`.

The ufw script does not do this. `ufw allow` and `ufw delete` write `/etc/ufw/user.rules`. The script then runs `ufw reload`. A rule is replaced only when its comment equals a zone named in `dynhosts.json`.

## Profile silence

`AI_PROFILE/languages/` has frontend, php, and powershell guides. It has no shell guide. Shell changes in this repo follow the existing scripts and this directory.
