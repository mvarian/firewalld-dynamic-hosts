# firewalld-dynamic-hosts

Cron jobs that keep a firewall allow-list aligned with trusted IPs and hostnames.

## Overview

Internal servers should accept SSH only from addresses we treat as trusted. Some of those are static IPs. Some are hostnames whose addresses change. firewalld and nftables are not configured here with a native hostname source that updates when DNS changes. These scripts are that update.

Three variants:

- CentOS / firewalld (`centos/fwdynhosts.sh`) replaces the sources on each zone named in the config.
- Debian / nftables (`debian-nft/fwdynhosts.sh`) replaces the elements of each named set in the nftables table `firewall`.
- Debian / ufw (`debian-ufw/fwdynhosts.sh`) writes one ufw rule list per named zone. `zones.json` is the zone's ports and protocols. `dynhosts.json` is who may use that zone.

On firewalld, the zone already defines which services those sources may reach. On nftables, you create the set and the rules that accept traffic from it; the script only refreshes who is in the set. UFW has no zones, so `zones.json` is that policy and the script writes an allow for each dynhosts address. Each run replaces the whole list it owns. Firewalld zones, nftables sets, and ufw rules whose comment is not one of the named zones are left alone. A DNS change takes effect on the next cron run. The install sections below schedule that cron hourly.

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

- Add `centos/fwdynhosts.sh` and `centos/dynhosts.json` (using dynhosts.json.example as template) to your CentOS box in `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `yum install -y jq bind-utils`
- `crontab -e`
- Add entry to refresh rules every hour: `0 * * * * /opt/fwdynhosts/fwdynhosts.sh`


## Configuration and Usage

- Edit dynhosts.json to add the IPs and hostnames you want allowed in each zone/set, adding whatever zones/sets you need. On ufw, use the same zone name in `zones.json` for that zone's ports. Use `0.0.0.0/0` as an address when the zone is open to any IPv4 address.
- Any zones/sets not listed in the configuration will be untouched. On ufw, that includes rules whose comment is not a zone named in `dynhosts.json`.
- Any zones/sets listed in the configuration will have their allowed sources **completely replaced** by what is configured in the json file. Be sure to add everything you want allowed for the zone/set into the config. On ufw, the same replacement applies to every rule commented with that zone name.
