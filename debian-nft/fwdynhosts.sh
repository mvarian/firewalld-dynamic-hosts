#!/usr/bin/env bash
# Refresh nftables set elements from dynhosts.json.
# The accept rules live in the host's own /etc/nftables.conf. This script does not write them.
set -euo pipefail

case ":${PATH:-}:" in
	*:/usr/sbin:*) ;;
	*) PATH="${PATH:+$PATH:}/usr/sbin:/sbin" ;;
esac
export PATH

CONFIG=${FWDYNHOSTS_CONFIG:-/opt/fwdynhosts/dynhosts.json}
STATE=${FWDYNHOSTS_STATE_DIR:-/var/lib/fwdynhosts}
family=firewall

for cmd in jq nft flock host; do
	command -v "$cmd" >/dev/null 2>&1 || { printf 'fwdynhosts: %s is missing\n' "$cmd" >&2; exit 1; }
done

mkdir -p "$STATE"
exec 9>"$STATE/fwdynhosts.lock"
flock -n 9 || { printf '%s\n' "fwdynhosts: lock busy" >&2; exit 1; }

jq -e 'type == "array" and length > 0 and all(.[]; (keys - ["set","zone","comment","ips","hostnames"]) == [] and (.ips | type == "array") and (.hostnames | type == "array"))' "$CONFIG" >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

add_addr() {
	local addr="$1" dest="$2"
	case "$addr" in
		*:*)
			printf 'fwdynhosts: not an ipv4 address: %s\n' "$addr" >&2
			exit 1
			;;
		''|*[!0-9./]*|*/0|0.0.0.0|0.0.0.0/*)
			printf 'fwdynhosts: rejected address: %s\n' "$addr" >&2
			exit 1
			;;
	esac
	printf '%s\n' "$addr" >> "$dest"
}

while IFS= read -r item; do
	name=$(printf '%s' "$item" | jq -r '.set // .zone // empty')
	case "$name" in
		[A-Za-z]*) ;;
		*)
			printf 'fwdynhosts: bad set name: %s\n' "$name" >&2
			exit 1
			;;
	esac
	case "$name" in
		*[!A-Za-z0-9_]*)
			printf 'fwdynhosts: bad set name: %s\n' "$name" >&2
			exit 1
			;;
	esac
	if [ -e "$work/set.$name" ]; then
		printf 'fwdynhosts: duplicate set: %s\n' "$name" >&2
		exit 1
	fi
	: > "$work/set.$name"
	while IFS= read -r addr; do
		[ -n "$addr" ] || continue
		add_addr "$addr" "$work/set.$name"
	done < <(printf '%s' "$item" | jq -r '.ips[]')
	while IFS= read -r hostname; do
		[ -n "$hostname" ] || continue
		if ! host -W 5 "$hostname" > "$work/host.out"; then
			printf 'fwdynhosts: lookup failed for %s\n' "$hostname" >&2
			exit 1
		fi
		found=0
		while IFS= read -r addr; do
			[ -n "$addr" ] || continue
			add_addr "$addr" "$work/set.$name"
			found=1
		done < <(awk '/has address/ { print $4 }' "$work/host.out")
		if [ "$found" -eq 0 ]; then
			printf 'fwdynhosts: no address for %s\n' "$hostname" >&2
			exit 1
		fi
	done < <(printf '%s' "$item" | jq -r '.hostnames[]')
	if [ ! -s "$work/set.$name" ]; then
		printf 'fwdynhosts: refusing to empty set %s\n' "$name" >&2
		exit 1
	fi
	sort -u "$work/set.$name" -o "$work/set.$name"
done < <(jq -c '.[]' "$CONFIG")

{
	for f in "$work"/set.*; do
		name=$(basename "$f")
		name=${name#set.}
		printf 'flush set ip %s %s\n' "$family" "$name"
		list=$(paste -sd, "$f" | sed 's/,/, /g')
		printf 'add element ip %s %s { %s }\n' "$family" "$name" "$list"
	done
} > "$work/tx.nft"

printf 'nft -f %s\n' "$work/tx.nft"
cat "$work/tx.nft"
nft -f "$work/tx.nft"
printf '%s\n' "Done."
