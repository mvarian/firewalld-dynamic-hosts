# Architecture Decisions

This is the project's append-only decision log.

Format: newest entry on top, heading `## YYYY-MM-DD - <short title>`. Each entry records
what was decided, what alternative was rejected, and why. Entries are never rewritten — a
superseded decision gets a new entry that references the old one.

## 2026-10-14 - UFW zones are named in JSON

This supersedes the public/private-only split in "UFW public rules and private rules" below. The rest of that entry still holds: discrete `ufw allow` rules, no ipset, no `/etc/nftables.conf` rewrite, `ufw reload` at the end, a failed lookup drops that hostname, and a rule missing `port` or `proto` is not added.

Zone names are data. `debian-ufw/zones.json` is an array of `{ zone, rules: [{ port, proto }] }`. `dynhosts.json` is an array of `{ zone, ips, hostnames }`. The script joins them on `zone`.

For each zone named in `dynhosts.json`, the script deletes ufw rules whose comment is that zone name, then adds one allow per address per port and protocol. A zone absent from `dynhosts.json` is not cleared. A named zone with no matching `rules` in `zones.json` is cleared and left empty.

Any IPv4 source is just an address on that zone. The example zone `public` uses `0.0.0.0/0`. That name is not special in the script. Hardcoded `public` and `private` keys were rejected.

## 2026-10-14 - UFW public rules and private rules

UFW has no zones. `debian-ufw/fwdynhosts.sh` is a separate script. It reads `/opt/fwdynhosts/zones.json` and `/opt/fwdynhosts/dynhosts.json`.

`public` in zones.json is the port and protocol list allowed from any IPv4 address (`0.0.0.0/0`). `private` is the port and protocol list allowed only from the static `ips` and the resolved hostnames in dynhosts.json. There is one private address list, not a per-zone list.

Each run deletes ufw rules whose comment is exactly `public` or `private`, then adds the current set. Other ufw rules are left alone. A failed lookup does not keep that hostname. An empty private address list, or a private rule missing `port` or `proto`, adds nothing for that rule. The previous private rules are already deleted.

An ipset, and an `ufw allow from` with no port, were rejected. UFW's discrete allow rules are the zone structure. Persistence is `ufw allow` / `ufw delete` and `ufw reload`. This script does not write `/etc/nftables.conf`.

The nftables script now lives at `debian-nft/fwdynhosts.sh`. The 2026-10-14 entries below still say `debian/fwdynhosts.sh`.

## 2026-10-14 - Named lists are replaced from JSON

A run treats `dynhosts.json` as the whole source list for each zone or set it names.

`centos/fwdynhosts.sh` deletes every current firewalld source on that zone, then adds the configured IPs and the resolved hostname addresses. `debian/fwdynhosts.sh` aims to purge the named nftables set and add those same addresses. Zones and sets that do not appear in the file are not cleared by that loop.

Incremental add/remove was rejected. The scripts do not store the previous generation, so a merge would leave a removed hostname in the firewall until some other change deleted it.

An empty `ips` and `hostnames` list therefore clears that zone or set. That is the same rule, not a special case.

## 2026-10-14 - Resolve hostnames outside the firewall

Internal servers should accept SSH only from IPs and hostnames we treat as trusted, including hosts that do not have a static address. firewalld and nftables are not given a native hostname object that updates when DNS changes. A root cron job is the update.

Each variant reads `/opt/fwdynhosts/dynhosts.json`, keeps the static `ips` as written, and resolves each hostname with `host`, keeping the first IPv4 answer (`has address`, `head -n1`). It then writes those addresses into the firewall's existing allow-list:

- CentOS / firewalld: sources on the named zone, then `firewall-cmd --reload`.
- Debian / nftables: elements of the named set in the nftables table `firewall` (the script variable `family` is that table name, not the address family). The address family on the add path is the literal `ip`.

The SSH accept rule is not generated here. On firewalld, the zone's services and target are configured on the host; this script only replaces sources. On nftables, an administrator creates the set and the rules that accept traffic from it (the README sample accepts SSH and ICMP echo from the `management` set). The script refreshes membership.

One cross-distro script was rejected. Persistence is not the same operation: firewalld uses `--permanent` plus `--reload`, while the Debian script overwrites `/etc/nftables.conf` with `flush ruleset` and a dump of the live ruleset. Those stay in `centos/fwdynhosts.sh` and `debian/fwdynhosts.sh`.

This entry records the design already in the tree. It is not a behavior change.
