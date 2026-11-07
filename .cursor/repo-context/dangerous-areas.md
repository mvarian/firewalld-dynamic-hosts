# Dangerous Areas

Both scripts run as root and change who the host firewall trusts. A bad edit is an SSH lockout or an allow-list that is wider than the JSON says. Read this before changing `centos/fwdynhosts.sh`, `debian/fwdynhosts.sh`, or either `dynhosts.json.example`.

Threat model for this tree: the attacker who matters is anyone who can change DNS for a configured hostname, anyone who can write `/opt/fwdynhosts/dynhosts.json`, or an edit here that the next cron run applies. The scripts do not authenticate the operator. Trust is "root placed this file and this cron job."

## Replacing a named zone or set

`centos/fwdynhosts.sh` replaces every source on each zone named in the JSON, including sources added by hand. It prints those removals. DNS runs first. A hostname that fails with no last-known-good stops the run before any firewall change, so a lookup failure does not empty the zone. An empty `ips` and `hostnames` list still clears that zone's sources. Optional `services`, `ports`, and `target` replace that property only when the key is present. The script copies zone XML aside before the first permanent change and restores it if the run does not finish. firewalld still writes permanent changes before the single reload, so a SIGKILL during `firewall-cmd` can leave one XML file partial until the next run restores the backup.

`debian/fwdynhosts.sh` tries to purge the set, then adds elements. The add line is `nft add element ip firewall <set>`. The purge line is `nft delete element firewall <set>` with no `ip` family, and the element list is parsed from `nft list set` text with `awk` and `cut`. If that purge does not remove the old elements, the set grows instead of being replaced, and removed hostnames stay allowed.

Do not change "replace the whole list" into a merge inside either script. That contract is `architecture-decisions.md`.

## Debian rewrite of `/etc/nftables.conf`

`debian-nft/fwdynhosts.sh` overwrites `/etc/nftables.conf` on every run. The file deletes and recreates `ip firewall` and `ip6 firewall` from `nft list table`. The next nftables load replaces those two tables with that snapshot.

If a list command prints nothing, the header still deletes that table on the next load and does not recreate it. Do not put `flush ruleset` or `nft list ruleset` back. That captures fail2ban and Docker, then removes them on the next load. See the decision "nftables.conf reloads only the firewall tables".

## Hostname to address

CentOS trusts every validated A and AAAA from `host -W 5` that is not loopback, link-local, multicast, or unspecified. Debian nftables and ufw still trust the first A record `host` prints, and drop the rest. DNS for those names is a trust boundary. A wrong or extra name in JSON becomes a trusted source on the next run.

CentOS passes zone names and addresses to `firewall-cmd` as quoted arguments. Debian still expands the zone name, the set name, the comment, and the IP into `nft` commands without quoting (`nft add set` / `nft add element`). The config is root-owned and not remote input. Quoting changes on the Debian create-set line belong with a test against real `nft`, because that line also leaves `{ ... }` unquoted, and `{` is a bash reserved word.

## What not to add to the refresh path

- CentOS sets services, ports, and target only when those keys are present in the JSON. It rejects `ssh`, `22/tcp`, and `22/udp` on zones named `public` or `cloudflare`, and it rejects target `ACCEPT` on every zone. It does not bind interfaces. Debian nftables still does not generate the SSH accept rule. Membership and the accept rule stay separate there. The ufw script writes the named zone's port rules because UFW has no zone object.
- CentOS resolves A and AAAA. Debian nftables and ufw stay on the first A record until their firewall side is dual-stack.
- CentOS checks `firewall-cmd` status and restores the backup when a change does not finish. Debian still prints the command and runs it without that recovery.

## UFW zone comment

`debian-ufw/fwdynhosts.sh` deletes every ufw rule whose comment equals a zone named in `dynhosts.json`, then writes that zone again. A hand-added rule that reuses the comment is part of that list. A zone not named in `dynhosts.json` is left alone, including rules from a zone removed from the file.

An address of `0.0.0.0/0` opens that zone's ports to every IPv4 address. A rule missing `port` or `proto` is not added. The zone's previous rules are already gone by then.
