#!/usr/bin/env bash

configuration=`cat /opt/fwdynhosts/dynhosts.json`

items=$(echo "$configuration" | jq -c -r '.[]')
for item in ${items[@]}; do
	#printf "$item\n\n"
	zone=`echo $item | jq -r ".zone"`
	
	printf "Configuring Zone: $zone\n"

	printf "\nClearing existing sources...\n"
	zonesources=(`firewall-cmd --list-sources --zone=$zone`)
	for zonesource in "${zonesources[@]}"; do
		printf "Removing existing source $zonesource\n"
		printf "firewall-cmd --zone=$zone --remove-source=$zonesource --permanent\n"
		firewall-cmd --zone=$zone --remove-source=$zonesource --permanent
	done
	
	printf "\nSetting new IP sources...\n"
	ips=`echo $item | jq -r -c ".ips[]"`
	for ip in ${ips[@]}; do
		printf "Allowing IP: $ip\n"
		printf "firewall-cmd --zone=$zone --add-source=$ip --permanent\n"
		firewall-cmd --zone=$zone --add-source=$ip --permanent
	done
	
	printf "\nSetting new Hostname sources...\n"
	hostnames=`echo $item | jq -r -c ".hostnames[]"`
	for hostname in ${hostnames[@]}; do
		hostip=`host $hostname | awk '/has address/ { print $4 }' | head -n1`
		printf "Allowing Hostname: $hostname resolved to $hostip\n"
		printf "firewall-cmd --zone=$zone --add-source=$hostip --permanent\n"
		firewall-cmd --zone=$zone --add-source=$hostip --permanent
	done

	printf "\n"

done

printf "Reloading firewalld..."
firewall-cmd --reload

printf "Done.\n"