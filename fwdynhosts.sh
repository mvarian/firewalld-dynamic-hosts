#!/usr/bin/env bash

configuration=`cat dynhosts.json`

items=$(echo "$configuration" | jq -c -r '.[]')
for item in ${items[@]}; do
	printf "$item\n\n"
	zone=`echo $item | jq -r ".zone"`

	echo `echo $item | jq -r ".ips"`
	echo `echo $item | jq -r ".hostnames"`

done