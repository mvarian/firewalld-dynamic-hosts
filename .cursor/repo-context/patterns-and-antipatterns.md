# Patterns and Antipatterns

Match the variant you are editing. Do not invent a shared library for two short scripts.

## Patterns

- Config is a JSON array. CentOS objects in `centos/dynhosts.json.example` use `zone`, `ips`, `hostnames`, and optional `services`, `ports`, and `target`. Debian nftables objects in `debian-nft/dynhosts.json.example` use `set`, `comment`, `ips`, `hostnames`. UFW objects in `debian-ufw/dynhosts.json.example` use `zone`, `ips`, `hostnames`. UFW `debian-ufw/zones.json.example` uses `zone` and `rules` of `port` and `proto`. The same `zone` string joins the UFW files. Keep that split.
- CentOS resolves a hostname with `host -W 5` and keeps every validated A and AAAA. Debian nftables and ufw still use `host`, then `awk '/has address/ { print $4 }'`, then `head -n1`.
- Print the firewall command, then run it. Cron stdout is the only trace these scripts have.
- Static addresses stay in `ips`. Hostnames stay in `hostnames`. Do not pre-resolve hostnames into the example file.
- The Debian nftables table name stays `family="firewall"`. The set name is the JSON `set` field, or `zone` when `set` is absent.

## Antipatterns

- A distro switch inside one script. UFW is its own script because it has no zones. See `architecture-decisions.md`.
- Merging new addresses into a zone, set, or ufw comment and leaving old ones. Named lists are replaced.
- Adding an SSH allow to a CentOS zone named `public` or `cloudflare`, or generating an nft accept rule inside the nftables refresh loop. CentOS sets services, ports, and target only when the JSON key is present, and it rejects `ssh` and port 22 on `public` and `cloudflare`. The nftables loop only refreshes the address list. The ufw script writes one `ufw allow` per address per rule of the named zone, because that is the zone.
- Teaching a Debian script a config path other than `/opt/fwdynhosts/dynhosts.json` (and `/opt/fwdynhosts/zones.json` for ufw) without updating the README install. CentOS keeps that default and also accepts `--config` so tests can point elsewhere. The README says the default is unchanged.
- Committing a live `dynhosts.json`. `.gitignore` lists `dynhosts.json`. Examples stay the templates.
- "Hardening" a Debian run by aborting on the first failed lookup or the first `nft` error without deciding what the half-updated set should be. A Debian failure does not stop the script, and `debian-nft/fwdynhosts.sh` still rewrites `/etc/nftables.conf` afterward. CentOS stops before any firewall change when DNS has no last-known-good, and it restores the backup if a permanent change does not finish.
