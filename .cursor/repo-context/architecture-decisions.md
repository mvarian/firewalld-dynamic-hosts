# Architecture Decisions

This is the project's append-only decision log.

Format: newest entry on top, heading `## YYYY-MM-DD - <short title>`. Each entry records
what was decided, what alternative was rejected, and why. Entries are never rewritten — a
superseded decision gets a new entry that references the old one.

## 2026-11-06 - Servers keep their own nftables.conf

`nftables.baseline.conf` is renamed `nftables.conf.example` and is no longer an install step. Each server's `/etc/nftables.conf` is written by hand and holds server-specific rules this repo does not know. Copying a repo file over it would remove them. This supersedes the "short rules file" install in "The script only updates sets" (2026-11-06).

## 2026-11-06 - CentOS back to a short refresh

`centos/fwdynhosts.sh` was cut from 2322 lines to one apply path for the same reason as Debian nftables. It keeps `services`, `ports`, `target`, the ACCEPT and public/cloudflare SSH guards, and `--refresh-cloudflare`. It resolves every hostname before any `firewall-cmd` change and exits on a failed lookup. It adds new sources before removing stale ones and reloads once only when something changed. Modes, `--status` and `status.json`, the JSON log, last-known-good, zone XML backups, the SSH coverage check, and `--migrate-public-web` were removed. This supersedes "CentOS run status for RMM" (2026-10-24) and the backup and last-known-good parts of "CentOS refresh validates before it replaces" (2026-10-24).

## 2026-11-06 - The script only updates sets

The policy compiler, schema, exception flags, deploy wrappers, and rollback timer are rejected. The firewall is a short rules file: default drop, and accept for a few services from named sets. `dynhosts.json` stays the original array of `set`, `ips`, and `hostnames`. `debian-nft/fwdynhosts.sh` replaces elements in the IPv4 sets and does not write `/etc/nftables.conf`. The empty-firewall incident was that write. A failed lookup exits before `nft`. An empty list is refused for every set. Duplicate set names are an error. Every A record is kept. `0.0.0.0/0` is rejected. `/usr/sbin` is appended to `PATH` so cron can find `nft`. The IPv6 table stays drop and has no management set, because the script does not fill one. This supersedes the 2026-11-06 entries below that grew a second policy engine.

## 2026-11-06 - Allowlist accepts nft list decorations

`nft list` prints protocol matches the baseline left implicit (`ip protocol icmp`, `meta l4proto tcp`), may print port 22 as `ssh`, may brace `ct state`, and may insert `counter`. `input_rule_allowed` strips those decorations and then requires an exact baseline rule. A negation, a port range, a jump, or a bare accept still fails. Matching the raw list line was rejected: the first real `nft list` would make every later refresh fail closed and stop updating addresses. This was not checked against Debian 13's nft binary.

## 2026-11-06 - Rollback restores the previous live policy

This supersedes the parts of "Debian nftables refuses an empty save" (2026-11-06) that copied `/etc/nftables.conf` as the pre-deploy backup, that required the full baseline property check before a rollback, that named `destination.new` as the conf temp file, and that treated a warning as enough when the SSH client was outside the management set on confirm. The rest of that entry still holds for `debian-nft/`: cron does not install the baseline, an empty IPv4 management list is refused before nft, and the conf is replaced with `mv` only after a successful load.

`deploy-apply.sh` captures the live `ip firewall` and `ip6 firewall` tables, prepends the add/delete header, and saves that file as `$STATE_DIR/nftables.conf.pre-deploy` only when it is restorable. One function decides restorability for `do_rollback` and `rollback-if-unconfirmed.sh`. A file is restorable when `nft -c -f` succeeds, it is not header-only, both `ip` and `ip6` tables are present, and neither input policy is `accept`. A missing input policy is not restorable, because the check has to see a policy that is not accept. Missing `fwdynhosts:` comments are OK. The previous working policy will not have those comments, so requiring them made rollback refuse the file it is supposed to restore.

If the live tables are missing, empty, header-only, or an input policy is `accept`, there is no automatic rollback. The deploy stops unless `--no-automatic-rollback` is passed. That flag says console access is required and does not schedule a timer. The timer restores the captured live policy. `--rollback-schedule-file` is how a test records the `systemd-run` line without running it. When the flag is absent, `systemd-run` is required. `FWDYNHOSTS_ROLLBACK_SCHEDULE` is not a switch. An ambient variable must not disable the timer. `$STATE_DIR/deploy-pending` is written only after the timer is scheduled. A second deploy exits while that file exists and does not overwrite the capture. `--confirm-change` removes the marker after the confirm file is written. The rollback script removes it after a successful restore. Before scheduling, an active `fwdynhosts-rollback.timer` is refused when `systemctl` exists.

The rollback script takes the lock with `flock -w 120`, checks the confirm file again, and exits 0 without nft when the file is present. It then checks restorability and runs `nft -f` before it replaces the conf. `do_install_baseline` and `do_rollback` use that same load-then-save order. `nft -f` of one file is one transaction. A failed load leaves the previous conf in place.

`--install-baseline`, `--confirm-change`, and `deploy-apply.sh` require an operator address from the first field of `SSH_CONNECTION` or from `--operator-ip`. If it is missing, or not covered by the management set that will be live (install) or is live (confirm), the command exits 1 and does not write the confirm file. Cron `--apply`, `--check`, and `--dry-run` do not require an operator address. If `SSH_CONNECTION` is set during those modes, a client outside the desired management set is still refused. Session ids were not used. They were not verified. `sudo` and `sudo su` drop `SSH_CONNECTION` unless the operator passes `--operator-ip` or `sudo --preserve-env=SSH_CONNECTION`.

`/usr/sbin` and `/sbin` are appended to `PATH` when they are absent. They are not prepended, so a test mock earlier on `PATH` still wins. A root cron `PATH` of `/usr/bin:/bin` is a likely, unverified explanation of the empty save: `nft` would be command-not-found, stdout would be empty, and the 115-byte header would still be written.

Inside each input chain, every rule that accepts, drops, jumps, or gotos must match the baseline allowlist. A comment does not make another rule acceptable. The same check applies to a candidate and to the live table on apply. The port token `ssh` means 22. Prefix length 0 is a default route for any address and is rejected. The management set also rejects a prefix shorter than 8. Other sets still reject only prefix 0, multicast, and unspecified. IPv4 host bits are masked and octets are printed without leading zeros. IPv6 is stored in RFC 5952 form. A desired element covered by a broader element in the same set is dropped with a warning, and only the broader element is sent to nft. Both baseline management sets use `flags interval, auto-merge`.

An empty desired list for one family does not flush that live set and does not fail the run, except empty IPv4 management, which still fails before any nft call. A disappeared IPv6 list keeps the live IPv6 elements. `--allow-empty` may still clear a set that is not named `management`. It cannot clear IPv4 management.

`family` is always `firewall`. `set -Eeuo pipefail` is always on, including when the file is sourced. `main` runs unless `FWDYNHOSTS_LIB` is exactly `1`. `set_name_ok` allows only `[A-Za-z0-9_]`, including a rejection of newlines, and does not use grep. The conf temp file comes from `mktemp` in the destination directory.

`pre-deploy.sh` does not fail because the live table is not yet the baseline or because set elements differ from JSON. It exits 1 for invalid JSON, DNS with no last-known-good, nftables not active, ufw or firewalld active, a header-only conf while a live table exists without `--allow-missing-live`, and both live tables missing without that flag. It prints the port diff, whether a restorable live capture is available, and that drift is expected.

Forward policy stays drop. Whether rootless UniFi OS publishes through pasta onto the input chain, and whether a bridge would be affected, was not verified. No test result is claimed.

Rejected: prepending `/usr/sbin`, session ids, copying the on-disk conf as the rollback target, an environment variable that skips `systemd-run`, warning instead of failing an uncovered `--confirm-change`, requiring baseline comments on the rollback file, flushing one family because the other desired list disappeared, opening the destination with `>`, and changing forward policy to accept.

## 2026-11-06 - Debian nftables refuses an empty save

This supersedes, for `debian-nft/` only, the empty-list-clears behavior in "Named lists are replaced from JSON" (2026-10-14), the first-A-only resolver in "Resolve hostnames outside the firewall" (2026-10-14), the unvalidated truncate of `/etc/nftables.conf` in "nftables.conf reloads only the firewall tables" (2026-10-14), and the same-name replace in "nft set name falls back to zone" (2026-10-14). It also supersedes the "Debian nftables and ufw are unchanged" sentence in "CentOS refresh validates before it replaces" (2026-10-24) for debian-nft only. CentOS and ufw are unchanged.

`debian-nft/fwdynhosts.sh` still replaces a named set from JSON when the desired list is non-empty. It does not clear a live set when that list is empty. `--allow-empty` may clear a set that is not named `management`. The `management` set is never applied empty, because the baseline admin rules depend on it. A duplicate set name is an error. The JSON `comment` is accepted and ignored; the baseline owns set comments.

Hostnames use `host -W 5`. Every usable A and AAAA is kept. Loopback, link-local, multicast, and unspecified DNS answers are rejected. A failed name keeps last-known-good addresses when that name has at least one. If it does not, the run exits before any nft call and does not write the conf. Static `127.0.0.1` warns. Static `0.0.0.0/0`, `::/0`, multicast, and unspecified are rejected.

The set change is one `nft -f` file (`flush set` then `add element`). `set -Eeuo pipefail` is safe for that reason. An exclusive non-blocking `flock` is required before nft. The destination conf is written to `destination.new` and moved into place. It is never opened with `>`. A failed or empty `nft list table`, a header-only candidate, or a failed property check leaves the previous file in place and restores the previous elements when a set transaction already ran. The file still deletes and recreates only `ip firewall` and `ip6 firewall`. Dynamic elements are persisted so boot does not wait on DNS and does not start permissive.

`--install-baseline --confirm` is the only mode that installs `nftables.baseline.conf`. Cron refreshes addresses. It must not install the baseline. `nft -c -f` checks syntax only. The script also requires input policy drop, output policy accept, forward policy drop, the management set, and the baseline comments. An established SSH session is not proof that a new session works. `deploy-apply.sh` schedules a 300-second rollback and tells the operator to run `--confirm-change` only after a new SSH session, the management API, and the device inform path succeed.

Rejected: flushing the whole ruleset, generating the baseline from cron, treating `nft -c -f` as a policy check, treating an established SSH session as proof, opening admin ports to the world, and putting `172.234.29.145` in the example file. The live management `ips` array is where that address belongs.

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
