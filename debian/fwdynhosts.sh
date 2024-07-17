#!/usr/bin/env bash

configuration=`cat /opt/fwdynhosts/dynhosts.json`
family="firewall"

echo "$configuration" | jq -c -r '.[]' | while read -r item; do	
	#printf "$item\n\n"
	nfset=`echo $item | jq -r ".set"`
	nfcomment=`echo $item | jq -r ".comment"`

	printf "Configuring Set: $nfset $nfcomment\n"

	printf "\nChecking for existing set...\n"
	# nft list sets ip | grep -E -o "set\ \w*\ {" | grep -E -o "[^set\ ](\w*)[^\ {]"
	# nft list sets ip | grep -E -o "set\ \w*\ {" | while read -r a; do echo $a | grep -E -o "[^set\ ](\w*)[^\ {]"; done
	setsearch="set $nfset {"
	if [[ $(nft list sets ip | grep "$setsearch") ]]; then
		echo "Set $nfset was found, purging set entries"
		ip_elements=$(nft list set $family $nfset | awk '/{ /,/}/' | cut -d '=' -f 2)
		nft delete element $family $nfset ${ip_elements}
	else
		echo "No set $nfset found, creating set"
		nft add set ip $family $nfset { type ipv4_addr\; comment \"$nfcomment\" \; }
	fi

	printf "\nSetting new IP sources...\n"
	ips=`echo $item | jq -r -c ".ips[]"`
	for ip in ${ips[@]}; do
		printf "Allowing IP: $ip\n"
		printf "nft add element ip $family $nfset { $ip }\n"
		nft add element ip $family $nfset { $ip }
	done

	printf "\nSetting new Hostname sources...\n"
	hostnames=`echo $item | jq -r -c ".hostnames[]"`
	for hostname in ${hostnames[@]}; do
		hostip=`host $hostname | awk '/has address/ { print $4 }' | head -n1`
		#hostip=`dig +short hq.nsky.io | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"`
		printf "Allowing Hostname: $hostname resolved to $hostip\n"
		printf "nft add element ip $family $nfset { $hostip }\n"
		nft add element ip $family $nfset { $hostip }
	done

	printf "\n"

done

printf "Reloading nftables..."
cat << "EOF" > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

EOF
nft list ruleset >> /etc/nftables.conf

printf "Done.\n"