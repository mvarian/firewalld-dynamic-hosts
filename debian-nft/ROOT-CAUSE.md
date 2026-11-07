# The empty firewall

The old `debian-nft/fwdynhosts.sh` truncated `/etc/nftables.conf` and then appended `nft list table`. When a table was missing, or when cron's `PATH` did not include `/usr/sbin` and `nft` was not found, the list printed nothing. The cron path is likely and was not confirmed on the host. The file that remained was 115 bytes:

```
#!/usr/sbin/nft -f
add table ip firewall
delete table ip firewall
add table ip6 firewall
delete table ip6 firewall
```

The next boot deleted both tables and created nothing. `nftables.service` still looked active. An empty ruleset has no input hook, so the host is open.

The script no longer writes that file. It only replaces elements in sets the rules file already defines. A failed lookup exits before `nft` runs, so the current set stays. The rules file is installed by hand, once.

No Linode was contacted. No reboot was run.
