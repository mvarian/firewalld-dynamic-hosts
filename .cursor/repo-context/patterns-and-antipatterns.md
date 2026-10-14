# Patterns and Antipatterns

Match the variant you are editing. Do not invent a shared library for two short scripts.

## Patterns

- Config is a JSON array. CentOS objects in `centos/dynhosts.json.example` use `zone`, `ips`, `hostnames`. Debian nftables objects in `debian-nft/dynhosts.json.example` use `set`, `comment`, `ips`, `hostnames`. UFW objects in `debian-ufw/dynhosts.json.example` use `zone`, `ips`, `hostnames`. UFW `debian-ufw/zones.json.example` uses `zone` and `rules` of `port` and `proto`. The same `zone` string joins them. Keep that split.
- Resolve a hostname the way both scripts already do: `host`, then `awk '/has address/ { print $4 }'`, then `head -n1`.
- Print the firewall command, then run it. Cron stdout is the only trace these scripts have.
- Static addresses stay in `ips`. Hostnames stay in `hostnames`. Do not pre-resolve hostnames into the example file.
- The Debian nftables table name stays `family="firewall"`. The set name stays the JSON `set` field.

## Antipatterns

- A distro switch inside one script. UFW is its own script because it has no zones. See `architecture-decisions.md`.
- Merging new addresses into a zone, set, or ufw comment and leaving old ones. Named lists are replaced.
- Adding SSH or nft accept rules to the CentOS or nftables refresh loop. Those loops only refresh the address list. The ufw script writes one `ufw allow` per address per rule of the named zone, because that is the zone.
- Teaching a script a config path other than `/opt/fwdynhosts/dynhosts.json` (and `/opt/fwdynhosts/zones.json` for ufw) without updating the README install.
- Committing a live `dynhosts.json`. `.gitignore` lists `dynhosts.json`. Examples stay the templates.
- "Hardening" by aborting on the first failed lookup or the first `nft` error without deciding what the half-updated zone or set should be. Today a failure does not stop the script, and the Debian script still rewrites `/etc/nftables.conf` afterward.
