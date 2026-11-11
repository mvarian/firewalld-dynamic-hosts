# Dangerous Areas

These scripts run as root and change who the host firewall trusts. A bad edit is an SSH lockout or an allow-list that is wider than the JSON says. Read this before changing `centos/fwdynhosts.sh`, `debian-nft/fwdynhosts.sh`, `debian-ufw/fwdynhosts.sh`, or either `dynhosts.json.example`.

Threat model for this tree: the attacker who matters is anyone who can change DNS for a configured hostname, anyone who can write `/opt/fwdynhosts/dynhosts.json`, or an edit here that the next cron run applies. The scripts do not authenticate the operator. Trust is "root placed this file and this cron job."

## Replacing a named zone or set

`centos/fwdynhosts.sh` replaces every source on each zone named in the JSON, including sources added by hand. DNS runs first. A failed lookup stops the run before any firewall change, so a lookup failure does not empty the zone. An empty `ips` and `hostnames` list still clears that zone's sources. Optional `services`, `ports`, and `target` replace that property only when the key is present. New entries are added before stale ones are removed, so a run that stops partway leaves more access, not less. Permanent changes take effect at the single reload.

`debian-nft/fwdynhosts.sh` replaces a named IPv4 set in one `nft -f` transaction (`flush set` then `add element`) after the full desired list is valid. It does not write `/etc/nftables.conf`. An empty list, or a lookup that returns no address, exits before nft and leaves the set as it is. Do not put the old family-less purge back.

Do not change "replace the whole list" into a merge inside either script. That contract is `architecture-decisions.md`.

## Debian rewrite of `/etc/nftables.conf`

`debian-nft/fwdynhosts.sh` does not write `/etc/nftables.conf`. The rules file is installed by hand. Do not put the truncate-and-`nft list table` save back. That is what left the 115-byte delete-only file.

## Hostname to address

CentOS trusts every A and AAAA from `host -W 5`. Debian nftables keeps every A record and exits before nft when a lookup fails. UFW still trusts the first A record `host` prints, and drops the rest. DNS for those names is a trust boundary. A wrong or extra name in JSON becomes a trusted source on the next run.

CentOS passes zone names and addresses to `firewall-cmd` as quoted arguments. Debian nftables writes set changes into an nft script and runs `nft -f`. It does not expand braces on the shell command line, and it does not interpolate the JSON `comment` into an nft command. UFW still expands the zone name and the address into `ufw` commands. Do not put unquoted `{ ... }` back on the nftables path.

## What not to add to the refresh path

- CentOS sets services, ports, and target only when those keys are present in the JSON. It rejects `ssh`, `22/tcp`, and `22/udp` on zones named `public` or `cloudflare`, and it rejects target `ACCEPT` on every zone. It does not bind interfaces. Debian nftables refresh does not generate accept rules. Those rules are each server's hand-written `/etc/nftables.conf`. Do not open 22, 8443, or 11443 to `0.0.0.0/0` or `::/0`. The ufw script writes the named zone's port rules because UFW has no zone object.
- CentOS resolves A and AAAA. Debian nftables and UFW stay on A records.
- CentOS and Debian nftables do not change the firewall when a lookup fails, and do not print `Done.` on a failure. UFW still prints the command and runs it without that recovery.

## UFW zone comment

`debian-ufw/fwdynhosts.sh` deletes every ufw rule whose comment equals a zone named in `dynhosts.json`, then writes that zone again. A hand-added rule that reuses the comment is part of that list. A zone not named in `dynhosts.json` is left alone, including rules from a zone removed from the file.

An address of `0.0.0.0/0` opens that zone's ports to every IPv4 address. A rule missing `port` or `proto` is not added. The zone's previous rules are already gone by then.
