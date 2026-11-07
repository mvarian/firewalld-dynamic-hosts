# Patterns and Antipatterns

Match the variant you are editing. Do not invent a shared library for two short scripts.

## Patterns

- Config is a JSON array. CentOS objects in `centos/dynhosts.json.example` use `zone`, `ips`, `hostnames`, and optional `services`, `ports`, and `target`. Debian nftables objects in `debian-nft/dynhosts.json.example` use `set`, `comment`, `ips`, `hostnames`. UFW objects in `debian-ufw/dynhosts.json.example` use `zone`, `ips`, `hostnames`. UFW `debian-ufw/zones.json.example` uses `zone` and `rules` of `port` and `proto`. The same `zone` string joins the UFW files. Keep that split.
- CentOS resolves a hostname with `host -W 5` and keeps every validated A and AAAA. Debian nftables uses `host -W 5` and keeps every A record. A failed lookup exits before nft. UFW still uses `host`, then `awk '/has address/ { print $4 }'`, then `head -n1`.
- Print the firewall command, then run it. Cron stdout is the only trace these scripts have.
- Static addresses stay in `ips`. Hostnames stay in `hostnames`. Do not pre-resolve hostnames into the example file.
- The Debian nftables table name stays `family=firewall`. The script updates `ip` sets. The set name is the JSON `set` field, or `zone` when `set` is absent. A later duplicate name is an error. The JSON `comment` is ignored.

## Antipatterns

- A distro switch inside one script. UFW is its own script because it has no zones. See `architecture-decisions.md`.
- Merging new addresses into a zone, set, or ufw comment and leaving old ones. Named lists are replaced.
- Adding an SSH allow to a CentOS zone named `public` or `cloudflare`, or generating an nft accept rule inside the nftables refresh script. CentOS sets services, ports, and target only when the JSON key is present, and it rejects `ssh` and port 22 on `public` and `cloudflare`. The nftables script only replaces set elements. The ufw script writes one `ufw allow` per address per rule of the named zone, because that is the zone.
- Teaching the ufw script a config path other than `/opt/fwdynhosts/dynhosts.json` and `/opt/fwdynhosts/zones.json` without updating the README install. CentOS keeps that default and also accepts `--config`. Debian nftables keeps the default and uses `FWDYNHOSTS_CONFIG` in tests. The README says the installed path is unchanged.
- Committing a live `dynhosts.json`. `.gitignore` lists `dynhosts.json`. Examples stay the templates.
- Putting Debian nftables back on a run that writes `/etc/nftables.conf`, or that continues after `jq`, `host`, or `nft` fails. The set change is one `nft -f` file. A failed lookup does not call nft. UFW still continues after a failed lookup. CentOS stops before any firewall change when DNS has no last-known-good, and it restores the backup if a permanent change does not finish.
