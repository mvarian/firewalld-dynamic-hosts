# firewalld-dynamic-hosts

A way of managing hostname-based access in firewalld.

## Overview

The inspiration for this is wanting a way to lock down SSH and administrative access to Linux Servers/VMs when the authorized users don't have static IPs.

This is a simple approach to effectively utilize hostnames in supported firewalls and distributions.

## Debian Installation for nftables

This assumes an ipv4 firewall set named "firewall".  If the ruleset is named something else, set this in the firewall="" line at the top of fwdynhosts.sh.

The following is a sample set of firewall rules that will use a set named "management":

`nft add set ip firewall management { type ipv4_addr\; comment \"allowed management hosts\" \; }`
`nft add rule ip firewall input ip saddr @management icmp type { echo-request } counter accept`
`nft add rule ip firewall input ip saddr @management tcp dport ssh accept`

- Add `debian/fwdynhosts.sh` and `debian/dynhosts.json` (using dynhosts.json.example as template) to your CentOS box in `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `crontab -e`
- `apt-get update && apt-get install jq`
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

- Edit dynhosts.json to add the IPs and hostnames you want allowed in each zone/set, adding whatever zones/sets you need.
- Any zones/sets not listed in the configuration will be untouched.
- Any zones/sets listed in the configuration will have their allowed sources **completely replaced** by what is configured in the json file.  Be sure to add everything you want allowed for the zone/set into the config.
