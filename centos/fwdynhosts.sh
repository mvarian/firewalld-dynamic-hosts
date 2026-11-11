#!/usr/bin/env bash
# Replace firewalld sources, and optional services, ports, and target, from dynhosts.json.
set -euo pipefail

CONFIG=${FWDYNHOSTS_CONFIG:-/opt/fwdynhosts/dynhosts.json}
STATE=${FWDYNHOSTS_STATE_DIR:-/var/lib/fwdynhosts}

usage() { printf '%s\n' "usage: fwdynhosts.sh [--apply|--refresh-cloudflare]" >&2; exit 2; }
die() { printf 'fwdynhosts: %s\n' "$1" >&2; exit 1; }
bad_addr() { case "$1" in ''|*[!0-9A-Fa-f.:/]*|*/0|0.0.0.0|0.0.0.0/*|::|::/*) return 0 ;; *) return 1 ;; esac; }
take() { if bad_addr "$1"; then die "rejected address: $1"; fi; printf '%s\n' "$1" >> "$2"; }
opt_list() {
	local key="$1" dest="$2"
	printf '%s' "$obj" | jq -e --arg k "$key" 'has($k)' >/dev/null || return 0
	printf '%s' "$obj" | jq -r --arg k "$key" '.[$k][]' > "$dest"
	sort -u -o "$dest" "$dest"
}
check_feed() {
	local kind="$1" file="$2" n=0 line
	while IFS= read -r line || [ -n "$line" ]; do
		case "$kind:$line" in
			v4:*/*) case "$line" in *:*) die "rejected address: $line" ;; esac ;;
			v6:*:*/*) ;;
			*) die "rejected address: $line" ;;
		esac
		if bad_addr "$line"; then die "rejected address: $line"; fi
		n=$((n + 1))
	done < "$file"
	[ "$n" -gt 0 ] || die "empty $kind feed"
}

mode=apply
case "${1:-}" in
	''|--apply) ;;
	--refresh-cloudflare) mode=cf ;;
	*) usage ;;
esac
[ $# -le 1 ] || usage
for cmd in jq firewall-cmd flock host; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd is missing"
done
mkdir -p "$STATE"
exec 9>"$STATE/fwdynhosts.lock"
flock -n 9 || die "lock busy"
work=$(mktemp -d)
cfg_tmp=
cleanup() { rm -rf "$work"; [ -z "${cfg_tmp:-}" ] || rm -f "$cfg_tmp"; }
trap cleanup EXIT

jq -e 'type=="array" and length>0 and ([.[].zone]|unique|length)==length and all(.[];
	type=="object" and (keys-["zone","ips","hostnames","services","ports","target"])==[]
	and (.zone|type=="string" and test("^[A-Za-z][A-Za-z0-9_-]*$"))
	and (.ips|type=="array") and (.hostnames|type=="array")
	and ((has("services")|not) or (.services|type=="array"))
	and ((has("ports")|not) or (.ports|type=="array"))
	and ((has("target")|not) or (.target=="default" or .target=="DROP" or .target=="REJECT"))
	and ((.zone!="public" and .zone!="cloudflare")
		or (((.services//[])|index("ssh")|not) and ((.ports//[])|index("22/tcp")|not) and ((.ports//[])|index("22/udp")|not))))
' "$CONFIG" >/dev/null || die "invalid config"

if [ "$mode" = cf ]; then
	command -v curl >/dev/null 2>&1 || die "curl is missing"
	curl -fsS --max-time 20 --proto '=https' --max-redirs 0 https://www.cloudflare.com/ips-v4 > "$work/cf4"
	curl -fsS --max-time 20 --proto '=https' --max-redirs 0 https://www.cloudflare.com/ips-v6 > "$work/cf6"
	check_feed v4 "$work/cf4"
	check_feed v6 "$work/cf6"
	n=$(jq '[.[] | select(.zone == "cloudflare")] | length' "$CONFIG")
	[ "$n" -eq 1 ] || die "need one cloudflare zone"
	awk 'NF { print }' "$work/cf4" "$work/cf6" > "$work/cf"
	new_ips=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$work/cf")
	old_ips=$(jq -c '[.[] | select(.zone == "cloudflare")][0].ips' "$CONFIG")
	if [ "$old_ips" != "$new_ips" ]; then
		cfg_tmp=$(mktemp "$(dirname "$CONFIG")/fwdynhosts.XXXXXX")
		cp -p "$CONFIG" "$cfg_tmp"
		jq --argjson ips "$new_ips" 'map(if .zone == "cloudflare" then .ips = $ips else . end)' "$CONFIG" > "$cfg_tmp"
		mv "$cfg_tmp" "$CONFIG"
		cfg_tmp=
	fi
fi

: > "$work/zones"
while IFS= read -r obj; do
	zone=$(printf '%s' "$obj" | jq -r '.zone')
	: > "$work/$zone.sources"
	while IFS= read -r addr; do
		take "$addr" "$work/$zone.sources"
	done < <(printf '%s' "$obj" | jq -r '.ips[]')
	while IFS= read -r hostname; do
		[ -n "$hostname" ] || die "lookup failed for $hostname"
		host -W 5 "$hostname" > "$work/host.out" || die "lookup failed for $hostname"
		found=0
		while IFS= read -r addr; do
			[ -n "$addr" ] || continue
			take "$addr" "$work/$zone.sources"
			found=1
		done < <(awk '/has IPv6 address/ { print $5; next } /has address/ { print $4 }' "$work/host.out")
		[ "$found" -eq 1 ] || die "no address for $hostname"
	done < <(printf '%s' "$obj" | jq -r '.hostnames[]')
	sort -u -o "$work/$zone.sources" "$work/$zone.sources"
	opt_list services "$work/$zone.services"
	opt_list ports "$work/$zone.ports"
	if printf '%s' "$obj" | jq -e 'has("target")' >/dev/null; then
		printf '%s' "$obj" | jq -r '.target' > "$work/$zone.target"
	fi
	printf '%s\n' "$zone" >> "$work/zones"
done < <(jq -c '.[]' "$CONFIG")

changed=0
fw() {
	printf 'firewall-cmd'
	local a
	for a in "$@"; do printf ' %s' "$a"; done
	printf '\n'
	firewall-cmd "$@"
	changed=1
}
sync_prop() {
	local zone="$1" add="$2" remove="$3" list="$4" file="$5" cur item
	cur="$work/cur.${list#--}"
	firewall-cmd --permanent "--zone=$zone" "$list" | tr ' \t' '\n' | sed '/^$/d' > "$cur"
	while IFS= read -r item; do
		[ -n "$item" ] || continue
		if ! grep -qxF "$item" "$cur"; then
			fw --permanent "--zone=$zone" "$add$item"
		fi
	done < "$file"
	while IFS= read -r item; do
		[ -n "$item" ] || continue
		if ! grep -qxF "$item" "$file"; then
			fw --permanent "--zone=$zone" "$remove$item"
		fi
	done < "$cur"
}

while IFS= read -r zone; do
	zones=$(firewall-cmd --permanent --get-zones)
	if ! printf '%s\n' "$zones" | tr ' ' '\n' | grep -qxF "$zone"; then
		fw --permanent "--new-zone=$zone"
	fi
	sync_prop "$zone" "--add-source=" "--remove-source=" "--list-sources" "$work/$zone.sources"
	if [ -f "$work/$zone.services" ]; then
		sync_prop "$zone" "--add-service=" "--remove-service=" "--list-services" "$work/$zone.services"
	fi
	if [ -f "$work/$zone.ports" ]; then
		sync_prop "$zone" "--add-port=" "--remove-port=" "--list-ports" "$work/$zone.ports"
	fi
	if [ -f "$work/$zone.target" ]; then
		want=$(cat "$work/$zone.target")
		have=$(firewall-cmd --permanent "--zone=$zone" --get-target)
		if [ "$want" != "$have" ]; then
			fw --permanent "--zone=$zone" "--set-target=$want"
		fi
	fi
done < "$work/zones"
if [ "$changed" -eq 1 ]; then
	fw --reload
fi
printf '%s\n' "Done."
