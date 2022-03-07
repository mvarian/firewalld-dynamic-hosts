# firewalld-dynamic-hosts

A way of managing hostname-based access in firewalld.

## Overview

The inspiration for this is wanting a way to lock down SSH and administrative access to CentOS VMs when the authorized users don't have static IPs.

This is a simple approach to effectively utilize hostnames in firewalld.

## Installation

- Add this code your linux box to `/opt/fwdynhosts/`.
- `sudo su`
- `chmod 700 -R /opt/fwdynhosts/*`
- `chown root:root -R /opt/fwdynhosts/*`
- `yum install -y jq bind-utils`
- `crontab -e`
- Add entry to refresh rules every hour: `0 * * * * /opt/fwdynhosts/fwdynhosts.sh`


## Configuration and Usage

- Edit dynhosts.json to add the IPs and hostnames you want allowed in each zone, adding whatever zones you need.
- Any zones not listed in the configuration will be untouched.
- Any zones listed in the configuration will have their allowed sources **completely replaced** by what is configured in the json file.  Be sure to add everything you want allowed for the zone into the config.
