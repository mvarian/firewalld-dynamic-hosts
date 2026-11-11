# firewalld-dynamic-hosts

Cron jobs that keep a firewall allow-list aligned with trusted IPs and hostnames.

## Overview

Internal servers should accept SSH only from addresses we treat as trusted. Some of those are static IPs. Some are hostnames whose addresses change. firewalld and nftables are not configured here with a native hostname source that updates when DNS changes. These scripts are that update.

Three variants:

- CentOS / firewalld (`centos/fwdynhosts.sh`) replaces the sources on each zone named in the config, and replaces services, ports, or target only when that key is present.
- Debian / nftables (`debian-nft/fwdynhosts.sh`) replaces the elements of each named set in the nftables table `firewall`. The accept rules are the host's own `/etc/nftables.conf`. The script does not write that file.
- Debian / ufw (`debian-ufw/fwdynhosts.sh`) writes one ufw rule list per named zone. `zones.json` is the zone's ports and protocols. `dynhosts.json` is who may use that zone.

On firewalld, services, ports, and target stay as they are unless the config lists that key. On nftables, the rules file is the policy and the JSON is who may use the `management` set. UFW has no zones, so `zones.json` is that policy and the script writes an allow for each dynhosts address. Each run replaces the whole list it owns. Firewalld zones, nftables sets, and ufw rules whose comment is not one of the named zones are left alone. A DNS change takes effect on the next cron run. The install sections below schedule that cron hourly.

Each script reads `/opt/fwdynhosts/dynhosts.json`. The ufw script also reads `/opt/fwdynhosts/zones.json`. Copy the matching example and edit it on the host. Do not commit the live dynhosts file.

## Debian Installation for nftables

Your `/etc/nftables.conf` is the firewall, written by hand for each server. It must define `table ip firewall` with an `ipv4_addr` set for each name in `dynhosts.json`. The script replaces the elements of those sets and nothing else. It does not write `/etc/nftables.conf`.

`nftables.conf.example` shows that shape: default drop, with accepts from `@management`. It is an example. Do not copy it over a configured server. Put NOMS `172.234.29.145` in the live `management` ips. The example addresses are placeholders.

A lookup that returns no address exits before `nft` runs, so the set already loaded stays. An empty address list is not flushed. `0.0.0.0/0` is rejected. Writing this repository did not modify a host.

- Add `debian-nft/fwdynhosts.sh` and `debian-nft/dynhosts.json` (from dynhosts.json.example) to `/opt/fwdynhosts/`.
- Make sure `/etc/nftables.conf` defines each set named in `dynhosts.json` in `table ip firewall`.
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `apt-get update && apt-get install jq nftables util-linux`
- Install `bind9-host` or `bind9-dnsutils` so `host` is on `PATH`.
- `crontab -e`
- `0 * * * * /opt/fwdynhosts/fwdynhosts.sh`


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

Each object needs `zone`, `ips`, and `hostnames`. Optional keys are `services`, `ports`, and `target`. Any other key is rejected. A key that is absent leaves that property as it is. A key that is present becomes exactly the listed set. `target` may be `default`, `DROP`, or `REJECT`. Zones named `public` or `cloudflare` cannot receive `ssh`, `22/tcp`, or `22/udp`.

Sources on a zone named in the file are replaced, including addresses added by hand. Every hostname is resolved first. A lookup that fails or returns no address exits before any `firewall-cmd` change. New sources are added before stale ones are removed. Empty `ips` and `hostnames` clear the zone's sources. `0.0.0.0/0` and `::/0` are rejected. Zones absent from the file are left alone. `firewall-cmd --reload` runs once, and only when something changed.

`--refresh-cloudflare` fetches `https://www.cloudflare.com/ips-v4` and `ips-v6`, writes them into the `ips` of the zone named `cloudflare`, and then applies. A bad or empty feed leaves the file as it is. Run it by hand. Cron does not fetch.

Dependencies: `jq`, `bind-utils` (`host`), `firewalld`, and `util-linux` (`flock`). `curl` is required only for `--refresh-cloudflare`.

- Add `centos/fwdynhosts.sh` and `centos/dynhosts.json` (using dynhosts.json.example as template) to your CentOS box in `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `yum install -y jq bind-utils firewalld util-linux`
- Install `curl` only if you will refresh the Cloudflare list by hand.
- `crontab -e`
- Add entry to refresh rules every hour: `0 * * * * /opt/fwdynhosts/fwdynhosts.sh`

## Configuration and Usage

- Edit dynhosts.json to add the IPs and hostnames you want allowed in each zone/set, adding whatever zones/sets you need. On ufw, use the same zone name in `zones.json` for that zone's ports. Use `0.0.0.0/0` as an address when a ufw zone is open to any IPv4 address. Debian nftables rejects `0.0.0.0/0`.
- Any zones/sets not listed in the configuration will be untouched. On ufw, that includes rules whose comment is not a zone named in `dynhosts.json`.
- Any zones/sets listed in the configuration will have their allowed sources **completely replaced** by what is configured in the json file. Be sure to add everything you want allowed for the zone/set into the config. On CentOS and ufw, an empty list clears that zone. On Debian nftables, an empty list exits before nft and leaves the set as it is. On ufw, the same replacement applies to every rule commented with that zone name.
