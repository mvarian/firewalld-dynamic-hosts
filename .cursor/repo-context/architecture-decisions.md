# Architecture Decisions

This is the project's append-only decision log.

Format: newest entry on top, heading `## YYYY-MM-DD - <short title>`. Each entry records
what was decided, what alternative was rejected, and why. Entries are never rewritten — a
superseded decision gets a new entry that references the old one.

## 2026-10-24 - CentOS run status for RMM

`centos/fwdynhosts.sh` writes `$STATE_DIR/status.json` only from mutating modes (`--apply`, `--migrate-public-web --confirm`, `--rollback`, and `--refresh-cloudflare` with `--apply`) and only from the EXIT trap, so a failed run is recorded the same way as a successful one. `--status` is a read-only Nagios check (exit 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN). Parsing cron stdout or mail for health was rejected because the RMM needs a stable machine-readable contract.

## 2026-10-24 - CentOS refresh validates before it replaces

This supersedes the CentOS parts of "Named lists are replaced from JSON" and "Resolve hostnames outside the firewall" (both 2026-10-14). Debian nftables and ufw are unchanged.

`centos/fwdynhosts.sh` still treats `dynhosts.json` as the whole source list for each zone it names, including sources that were added by hand. It prints every source it will remove. It does not remove anything until every hostname has been resolved or satisfied from last-known-good. A reconcile flag was rejected: the zone is the ownership boundary, and a manual extra is not a second source of truth.

`services`, `ports`, and `target` are optional. When a key is present the live property becomes exactly that set, and an empty array clears it. When the key is absent the live property is left alone, so an old file of `zone`, `ips`, and `hostnames` still only replaces sources. Making services additive was rejected: a removed service would stay open. `target` ACCEPT is rejected on every zone. Allowed values are `default`, `DROP`, and `REJECT`.

DNS keeps every validated A and AAAA from `host -W 5`. Answers that are loopback, link-local, multicast, or unspecified are rejected for that name. Keeping only the first A was rejected because a name with several addresses would be only partly allowed, and because the host firewall is dual-stack. A failed name uses its last-known-good addresses when those exist. If they do not, the run exits before any firewall change. Static `ips` may still be `127.0.0.1`. Static `0.0.0.0/0`, `::/0`, multicast, and unspecified are rejected. Static loopback warns. RFC1918 is not rejected.

The same normalized source in two zones is an error. Normalization is lowercase, strip IPv4 `/32` and IPv6 `/128`, and reject IPv4 leading zeros. Overlapping CIDRs are allowed; firewalld longest-prefix wins. Treating overlap as a conflict was rejected. Removal passes firewall-cmd the exact token it listed. Addition passes the normalized form.

`--refresh-cloudflare` downloads the published v4 and v6 lists, validates them, and prints the CIDR diff. It writes only with `--apply`, and then only the `ips` array of the zone named `cloudflare`, then continues into a normal firewall apply. An invalid feed writes nothing and does not touch firewalld. Cron does not fetch. Storing the feed outside the JSON was rejected: the zone's `ips` array is already the list the apply path reads.

The script uses `set -Eeuo pipefail`, an exclusive lock, a backup taken before the first permanent change, and one `firewall-cmd --reload` only when something changed. `--check`, `--dry-run`, `--apply`, and `--rollback` are the modes. No mode means `--apply` so an existing crontab line keeps working. `--migrate-public-web` is a separate confirmed step that removes `http` and `https` from `public` only after `cloudflare` is already serving that role. It is never part of a normal apply.

## 2026-10-14 - nft set name falls back to zone

`debian-nft/fwdynhosts.sh` reads `set` and, when that key is absent, `zone`. A missing name is skipped. The string `null` from `jq` was becoming a real set, so a file that only had `zone` never updated `management`.

`set` remains the nftables name when both keys are present. One JSON object is still one set, and a later object with the same name replaces it.

## 2026-10-14 - nftables.conf reloads only the firewall tables

This supersedes the `flush ruleset` plus `nft list ruleset` persistence in "Resolve hostnames outside the firewall" below. `debian-nft/fwdynhosts.sh` still rewrites `/etc/nftables.conf` after updating set elements.

The file deletes and recreates `ip firewall` and `ip6 firewall` only. Fail2ban (`inet f2b-table`) and Docker (`ip filter`, `ip nat`, and the ip6 equivalents) stay out of that file, so the next nftables load does not flush them or restore a stale copy.

A full ruleset dump was rejected. It captures tables those daemons own, and `flush ruleset` removes them on the next load.

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
