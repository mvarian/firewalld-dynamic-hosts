# Dangerous Areas

Both scripts run as root and change who the host firewall trusts. A bad edit is an SSH lockout or an allow-list that is wider than the JSON says. Read this before changing `centos/fwdynhosts.sh`, `debian/fwdynhosts.sh`, or either `dynhosts.json.example`.

Threat model for this tree: the attacker who matters is anyone who can change DNS for a configured hostname, anyone who can write `/opt/fwdynhosts/dynhosts.json`, or an edit here that the next cron run applies. The scripts do not authenticate the operator. Trust is "root placed this file and this cron job."

## Replacing a named zone or set

`centos/fwdynhosts.sh` removes every source on the zone before adding the new ones (`firewall-cmd --list-sources`, then `--remove-source` for each). Sources that some other process added are removed too. A config that names a zone and then resolves nothing leaves the zone with no sources.

`debian/fwdynhosts.sh` tries to purge the set, then adds elements. The add line is `nft add element ip firewall <set>`. The purge line is `nft delete element firewall <set>` with no `ip` family, and the element list is parsed from `nft list set` text with `awk` and `cut`. If that purge does not remove the old elements, the set grows instead of being replaced, and removed hostnames stay allowed.

Do not change "replace the whole list" into a merge inside either script. That contract is `architecture-decisions.md`.

## Debian rewrite of `/etc/nftables.conf`

`debian-nft/fwdynhosts.sh` overwrites `/etc/nftables.conf` on every run. The file deletes and recreates `ip firewall` and `ip6 firewall` from `nft list table`. The next nftables load replaces those two tables with that snapshot.

If a list command prints nothing, the header still deletes that table on the next load and does not recreate it. Do not put `flush ruleset` or `nft list ruleset` back. That captures fail2ban and Docker, then removes them on the next load. See the decision "nftables.conf reloads only the firewall tables".

## Hostname to address

The allow-list trusts the first A record `host` prints. DNS for those names is a trust boundary. A wrong or extra name in JSON becomes a trusted source on the next run. Addresses after the first are dropped, so a hostname with more than one A record is only partly allowed.

`host $hostname`, the zone name, the set name, the comment, and the IP are expanded into shell commands without quoting (`centos/fwdynhosts.sh` `firewall-cmd --zone=$zone`; `debian/fwdynhosts.sh` `nft add set` / `nft add element`). The config is root-owned and not remote input. Quoting changes belong with a test against real `nft` and `firewall-cmd` lines, because the Debian create-set line also leaves `{ ... }` unquoted, and `{` is a bash reserved word.

## What not to add to the refresh path

- Do not generate the SSH accept rule inside the CentOS or nftables refresh script. Membership and the accept rule are separate there. The ufw script writes the named zone's port rules because UFW has no zone object.
- Do not resolve AAAA or add `inet` sets here until the firewall side is actually dual-stack. The current sets and sources are IPv4.
- Do not treat a printed command as a check. The scripts print the command and then run it. They do not test the exit status.

## UFW zone comment

`debian-ufw/fwdynhosts.sh` deletes every ufw rule whose comment equals a zone named in `dynhosts.json`, then writes that zone again. A hand-added rule that reuses the comment is part of that list. A zone not named in `dynhosts.json` is left alone, including rules from a zone removed from the file.

An address of `0.0.0.0/0` opens that zone's ports to every IPv4 address. A rule missing `port` or `proto` is not added. The zone's previous rules are already gone by then.
