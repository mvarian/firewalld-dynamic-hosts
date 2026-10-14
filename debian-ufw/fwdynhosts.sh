#!/usr/bin/env bash

configuration=`cat /opt/fwdynhosts/dynhosts.json`
zones=`cat /opt/fwdynhosts/zones.json`

echo "$configuration" | jq -c -r '.[]' | while read -r item; do
	zone=`echo $item | jq -r ".zone"`

	printf "Configuring Zone: $zone\n"

	printf "\nClearing existing rules...\n"
	ufw show added | while read -r rule; do
		case "$rule" in
			*"comment '${zone}'")
				rule=${rule#ufw }
				rule=`printf '%s' "$rule" | tr -d "'"`
				printf "ufw delete $rule\n"
				ufw delete $rule
				;;
		esac
	done

	printf "\nSetting new IP sources...\n"
	ips=`echo $item | jq -r -c ".ips[]"`
	for ip in ${ips[@]}; do
		printf "Allowing IP: $ip\n"
		echo "$zones" | jq -c --arg z "$zone" '.[] | select(.zone == $z) | .rules[]' | while read -r rule; do
			port=`echo $rule | jq -r '.port // ""'`
			proto=`echo $rule | jq -r '.proto // ""'`
			if [ -n "$port" ] && [ -n "$proto" ]; then
				printf "ufw allow proto $proto from $ip to any port $port comment $zone\n"
				ufw allow proto $proto from $ip to any port $port comment $zone
			fi
		done
	done

	printf "\nSetting new Hostname sources...\n"
	hostnames=`echo $item | jq -r -c ".hostnames[]"`
	for hostname in ${hostnames[@]}; do
		hostip=`host $hostname | awk '/has address/ { print $4 }' | head -n1`
		printf "Allowing Hostname: $hostname resolved to $hostip\n"
		echo "$zones" | jq -c --arg z "$zone" '.[] | select(.zone == $z) | .rules[]' | while read -r rule; do
			port=`echo $rule | jq -r '.port // ""'`
			proto=`echo $rule | jq -r '.proto // ""'`
			if [ -n "$port" ] && [ -n "$proto" ]; then
				printf "ufw allow proto $proto from $hostip to any port $port comment $zone\n"
				ufw allow proto $proto from $hostip to any port $port comment $zone
			fi
		done
	done

	printf "\n"

done

printf "Reloading ufw..."
ufw reload

printf "Done.\n"
