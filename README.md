# firewalld-dynamic-hosts

Cron jobs that keep a firewall allow-list aligned with trusted IPs and hostnames.

## Overview

Internal servers should accept SSH only from addresses we treat as trusted. Some of those are static IPs. Some are hostnames whose addresses change. firewalld and nftables are not configured here with a native hostname source that updates when DNS changes. These scripts are that update.

Three variants:

- CentOS / firewalld (`centos/fwdynhosts.sh`) replaces the sources on each zone named in the config, and replaces services, ports, or target only when that key is present.
- Debian / nftables (`debian-nft/fwdynhosts.sh`) replaces the elements of each named set in the nftables table `firewall`.
- Debian / ufw (`debian-ufw/fwdynhosts.sh`) writes one ufw rule list per named zone. `zones.json` is the zone's ports and protocols. `dynhosts.json` is who may use that zone.

On firewalld, services, ports, and target stay as they are unless the config lists that key. On nftables, you create the set and the rules that accept traffic from it; the script only refreshes who is in the set. UFW has no zones, so `zones.json` is that policy and the script writes an allow for each dynhosts address. Each run replaces the whole list it owns. Firewalld zones, nftables sets, and ufw rules whose comment is not one of the named zones are left alone. A DNS change takes effect on the next cron run. The install sections below schedule that cron hourly.

Each script reads `/opt/fwdynhosts/dynhosts.json`. The ufw script also reads `/opt/fwdynhosts/zones.json`. Copy the matching example and edit it on the host. Do not commit the live dynhosts file.

## Debian Installation for nftables

This assumes an ipv4 nftables table named `firewall`. That name is `family="firewall"` at the top of `debian-nft/fwdynhosts.sh`. Set names come from the JSON.

The following is a sample set of firewall rules that will use a set named "management":

`nft add set ip firewall management { type ipv4_addr\; comment \"allowed management hosts\" \; }`
`nft add rule ip firewall input ip saddr @management icmp type { echo-request } counter accept`
`nft add rule ip firewall input ip saddr @management tcp dport ssh accept`

- Add `debian-nft/fwdynhosts.sh` and `debian-nft/dynhosts.json` (using dynhosts.json.example as template) to the Debian host in `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `crontab -e`
- `apt-get update && apt-get install jq`
- Install a package that provides the `host` command. The script resolves hostnames with `host`.
- Add entry to refresh rules every hour: `0 * * * * /opt/fwdynhosts/fwdynhosts.sh`


## Debian Installation for ufw

UFW has no zones. Add a zone by name in both files. `zones.json` lists that zone's ports and protocols. `dynhosts.json` lists the addresses allowed to use it. The example zone `public` uses `0.0.0.0/0`, which is any IPv4 address, for 80/tcp and 443/tcp. The example zone `management` uses the sample hosts for 22/tcp. Those names and ports are templates. A zone omitted from `dynhosts.json` is left as it is.

Rules this script owns use the zone name as the ufw comment. Any other comment is left alone. Enable ufw once on the host before relying on the cron job.

- Add `debian-ufw/fwdynhosts.sh`, `debian-ufw/dynhosts.json` (from dynhosts.json.example), and `debian-ufw/zones.json` (from zones.json.example) to the Debian host in `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `crontab -e`
- `apt-get update && apt-get install ufw jq`
- Install a package that provides the `host` command. The script resolves hostnames with `host`.
- Add entry to refresh rules every hour: `0 * * * * /opt/fwdynhosts/fwdynhosts.sh`


## CentOS Installation for firewalld

The default config path is still `/opt/fwdynhosts/dynhosts.json`. `--config PATH` is how a test points at another file. It does not change the installed path.

Each object needs `zone`, `ips`, and `hostnames`. Optional keys are `services`, `ports`, and `target`. Any other key is rejected. A file that only has the three required keys still applies, and that run does not call set-target, add-service, or remove-service.

Sources on a zone named in the file are replaced completely, including addresses added by hand. The script prints every source it will remove. It does not remove anything until each hostname has resolved or has a last-known-good address. Zones absent from the file are left alone, including their interfaces. The script does not change policies, rich rules, or firewalld service definitions.

When `services` or `ports` is present, that property becomes exactly the listed set. An empty array clears it. When the key is absent, the live property is left as it is. `target` may be `default`, `DROP`, or `REJECT`. `ACCEPT` is rejected on every zone. A service name must appear in `firewall-cmd --get-services`. Zones named `public` or `cloudflare` cannot receive service `ssh` or port `22/tcp` or `22/udp`.

The example zone `work` uses `203.0.113.10`. That address is a documentation placeholder because `work` is new. It is not copied from `trusted`. The same normalized source cannot appear in two zones. Overlapping CIDRs are allowed; firewalld uses the longest prefix. The example does not name `public`, so a copied example does not manage public sources. A live file that still lists `public` remains valid.

`host -W 5` supplies every validated A and AAAA. Loopback, link-local, multicast, and unspecified DNS answers fail that name. A failed name keeps its last-known-good addresses when they exist. If they do not, the run exits before it changes firewalld. Static `127.0.0.1` is allowed and logged as a warning. Static `0.0.0.0/0`, `::/0`, multicast, and unspecified addresses are rejected. Private RFC1918 addresses are allowed.

Modes, at most one of `--check`, `--dry-run`, `--apply`, and `--rollback`. No mode means `--apply`, so an older crontab line that does not pass a mode still applies. The documented line names the mode:

`0 * * * * /opt/fwdynhosts/fwdynhosts.sh --apply`

`--check` validates, resolves, and reports drift, including a managed zone whose runtime sources differ from permanent. It changes nothing and exits 1 when drift remains. `--dry-run` prints the permanent commands and does not reload. `--apply` writes permanent changes, then one `firewall-cmd --reload` only when something changed. `--rollback` restores the newest backup and reloads.

State lives in `/var/lib/fwdynhosts` (mode 0700). `--state-dir PATH` overrides it. `fwdynhosts.log` is one JSON object per line. `dns-state.json` stores the last good addresses for each hostname. Before the first permanent change, zone XML is copied to `backups/<timestamp>/` and the path is written to `in-progress`. A successful change points `latest-backup` at that directory and removes the marker. An apply that changes nothing does not replace `latest-backup`.

firewalld has no transaction. Permanent commands run, then one `--reload` swaps the ruleset. A crash after the marker is written is recovered on the next run: that backup is restored, firewalld is reloaded, the marker is removed only after that succeeds, and the requested mode then continues. SIGKILL during `firewall-cmd` itself can leave one zone XML partial until that recovery. The script does not edit zone XML except to copy a backup back; `firewall-cmd` is the writer. Established connections may continue across the reload. A new zone is created and filled before that single reload. Two reloads are not used.

`--refresh-cloudflare` fetches `https://www.cloudflare.com/ips-v4` and `https://www.cloudflare.com/ips-v6`, checks the lists, and prints added and removed CIDRs. Alone, or with `--check` or `--dry-run`, it does not write the file and does not change firewalld. Cron must not fetch. With `--apply`, a valid list that differs is written into the `ips` array of the zone named `cloudflare`, and the script then applies firewalld. An invalid, empty, or partial feed writes nothing and does not touch firewalld. If the firewall apply fails after that write, the previous config file is restored. The config must already contain one zone named `cloudflare`.

`--migrate-public-web` is never part of a normal apply. Use it only after `cloudflare` is populated and you have checked that it has sources, services `http` and `https`, no interface, and a target of `default`, `DROP`, or `REJECT`, and that `public` has interface `eth0`. Without `--confirm` the script prints the `http` and `https` services it would remove from `public` and exits. `--migrate-public-web --dry-run` prints the plan and changes nothing. `--migrate-public-web --confirm` removes only those two services from `public`, reloads once, and checks that `eth0` is still there, that `http` and `https` are gone, and that `cloudflare` still has its sources and `http`/`https`. Other public services and public interfaces are left as they are.

Dependencies: `jq`, `bind-utils` (`host`), `firewalld`, and `util-linux` (`flock`). `curl` is required only for `--refresh-cloudflare`.

- Add `centos/fwdynhosts.sh` and `centos/dynhosts.json` (using dynhosts.json.example as template) to your CentOS box in `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `yum install -y jq bind-utils firewalld util-linux`
- Install `curl` only if you will refresh the Cloudflare list by hand.
- `crontab -e`
- Add entry to refresh rules every hour: `0 * * * * /opt/fwdynhosts/fwdynhosts.sh --apply`

### Monitoring

Each mutating run (`--apply`, `--migrate-public-web --confirm`, `--rollback`, and `--refresh-cloudflare` with `--apply`) writes `/var/lib/fwdynhosts/status.json` (mode 0600) from the process EXIT trap, including failures. `--check`, `--dry-run`, and refresh-only runs are not recorded.

The file is JSON (`schema` 1) with `host`, `mode`, `started`, `finished` (UTC ISO-8601), `duration_s`, `result` (`ok` or `failed`), `exit_code`, `error`, `changes`, `reloaded`, `dns_lkg_hosts`, `runtime_drift`, `recovered`, `rolled_back`, `last_success`, and `consecutive_failures`. `last_success` is this run's `finished` time when `result` is `ok`, and is copied from the previous file when the run fails.

An RMM check should run:

`/opt/fwdynhosts/fwdynhosts.sh --status --max-age 90`

`--status` prints one line and uses Nagios exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN. Exit 2 here means CRITICAL, not a usage error. `--max-age MINUTES` (default 90) is the maximum age of `last_success`. `--status` does not take the lock, does not call `firewall-cmd` or DNS, and does not write `status.json`.

`fwdynhosts.log` in the state directory is one JSON object per line. When it exceeds 5 MiB it is rotated to `fwdynhosts.log.1`.

## Configuration and Usage

- Edit dynhosts.json to add the IPs and hostnames you want allowed in each zone/set, adding whatever zones/sets you need. On ufw, use the same zone name in `zones.json` for that zone's ports. Use `0.0.0.0/0` as an address when the zone is open to any IPv4 address.
- Any zones/sets not listed in the configuration will be untouched. On ufw, that includes rules whose comment is not a zone named in `dynhosts.json`.
- Any zones/sets listed in the configuration will have their allowed sources **completely replaced** by what is configured in the json file. Be sure to add everything you want allowed for the zone/set into the config. On ufw, the same replacement applies to every rule commented with that zone name.
