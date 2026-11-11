#!/usr/bin/env bash
# Mock firewall-cmd, host, curl, and flock.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/centos/fwdynhosts.sh"
FAILS=0
BASE=$(mktemp -d)
BIN="$BASE/bin"
mkdir -p "$BIN"
trap 'rm -rf "$BASE"' EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }

cat > "$BIN/firewall-cmd" << 'EOF'
#!/usr/bin/env bash
set -eu
mkdir -p "${FWDYNHOSTS_MOCK:?}/state"
printf '%s\n' "$*" >> "$FWDYNHOSTS_MOCK/calls"
root="$FWDYNHOSTS_MOCK/state"
zone="" action="" val=""
for a in "$@"; do
	case "$a" in
		--permanent) ;;
		--get-zones) action=zones ;;
		--reload) action=reload ;;
		--new-zone=*) action=new; val=${a#*=} ;;
		--zone=*) zone=${a#*=} ;;
		--list-*) action=list; val=${a#--list-} ;;
		--get-target) action=get-target ;;
		--set-target=*) action=set-target; val=${a#*=} ;;
		--add-*|--remove-*) action=${a%%=*}; action=${action#--}; val=${a#*=} ;;
		*) printf 'mock firewall-cmd: bad arg %s\n' "$a" >&2; exit 1 ;;
	esac
done
z="$root/$zone"
case "$action" in
	zones) for d in "$root"/*; do [ -d "$d" ] || continue; printf '%s ' "${d##*/}"; done; printf '\n' ;;
	new) mkdir -p "$root/$val"; for f in sources services ports; do : > "$root/$val/$f"; done; printf '%s\n' default > "$root/$val/target" ;;
	list) tr '\n' ' ' < "$z/$val"; printf '\n' ;;
	get-target) cat "$z/target" ;;
	set-target) printf '%s\n' "$val" > "$z/target" ;;
	reload) ;;
	add-*) printf '%s\n' "$val" >> "$z/${action#add-}s" ;;
	remove-*) f="$z/${action#remove-}s"; grep -vxF "$val" "$f" > "$f.new" || true; mv "$f.new" "$f" ;;
	*) printf '%s\n' "mock firewall-cmd: no action" >&2; exit 1 ;;
esac
EOF
cat > "$BIN/host" << 'EOF'
#!/usr/bin/env bash
host=""
skip=0
for a in "$@"; do
	if [ "$skip" -eq 1 ]; then skip=0; continue; fi
	case "$a" in -W) skip=1 ;; -*) ;; *) host=$a ;; esac
done
[ -n "$host" ] || exit 1
found=0
while IFS= read -r line || [ -n "$line" ]; do
	name=${line%% *}
	rest=${line#* }
	[ "$name" = "$host" ] || continue
	found=1
	[ "$rest" = fail ] && exit 1
	for item in $rest; do
		case "$item" in *:*) printf '%s has IPv6 address %s\n' "$host" "$item" ;; *) printf '%s has address %s\n' "$host" "$item" ;; esac
	done
done < "${FWDYNHOSTS_HOSTS:?}"
[ "$found" -eq 1 ] || exit 1
EOF
cat > "$BIN/flock" << 'EOF'
#!/usr/bin/env bash
if [ "${FWDYNHOSTS_FLOCK_BUSY:-}" = 1 ]; then exit 1; fi
exit 0
EOF
cat > "$BIN/curl" << 'EOF'
#!/usr/bin/env bash
set -eu
url=""
for a in "$@"; do
	case "$a" in https://*) url=$a ;; esac
done
case "$url" in
	*/ips-v4) cat "${FWDYNHOSTS_CURL_V4:?}" ;;
	*/ips-v6) cat "${FWDYNHOSTS_CURL_V6:?}" ;;
	*) printf '%s\n' "mock curl: bad url" >&2; exit 1 ;;
esac
EOF
chmod +x "$BIN/firewall-cmd" "$BIN/host" "$BIN/flock" "$BIN/curl"

new_case() {
	T=$(mktemp -d "$BASE/case.XXXXXX")
	export FWDYNHOSTS_MOCK="$T/mock" FWDYNHOSTS_HOSTS="$T/hosts" FWDYNHOSTS_CONFIG="$T/dynhosts.json"
	export FWDYNHOSTS_STATE_DIR="$T/state" FWDYNHOSTS_CURL_V4="$T/v4" FWDYNHOSTS_CURL_V6="$T/v6"
	export FWDYNHOSTS_FLOCK_BUSY= PATH="$BIN:$PATH"
	mkdir -p "$FWDYNHOSTS_MOCK"
	printf '%s\n' "example.com 93.184.216.34" > "$T/hosts"
	printf '%s\n' '[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]' > "$T/dynhosts.json"
	: > "$T/v4"; : > "$T/v6"
}
run() { set +e; bash "$SCRIPT" "$@" >"$T/stdout" 2>"$T/stderr"; RC=$?; set -e; return 0; }
seed() {
	local dir="$FWDYNHOSTS_MOCK/state/$1"
	mkdir -p "$dir"
	printf '%s\n' "$2" > "$dir/sources"
	: > "$dir/services"; : > "$dir/ports"
	[ -z "${3:-}" ] || printf '%s\n' "$3" > "$dir/services"
	[ -z "${4:-}" ] || printf '%s\n' "$4" > "$dir/ports"
	printf '%s\n' "${5:-default}" > "$dir/target"
}
no_fw() { if [ "$RC" -ne 0 ] && [ ! -f "$FWDYNHOSTS_MOCK/calls" ] && ! grep -Fqx 'Done.' "$T/stdout"; then pass "$1"; else fail "$1"; fi; }
ok() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }
rej() { new_case; printf '%s\n' "$2" > "$T/dynhosts.json"; if [ $# -ge 3 ]; then printf '%s\n' "$3" > "$T/hosts"; fi; run; no_fw "$1"; }

new_case
printf '%s\n' '[{"zone":"trusted","target":"DROP","services":["http","https"],"ports":["8080/tcp"],"ips":["203.0.113.10"],"hostnames":["example.com"]}]' > "$T/dynhosts.json"
printf '%s\n' "example.com 93.184.216.34 2001:db8::10" > "$T/hosts"
run --apply
reloads=$(grep -c -e '--reload' "$FWDYNHOSTS_MOCK/calls" || true)
miss=0
for pat in '--permanent --new-zone=trusted' '--permanent --zone=trusted --add-source=203.0.113.10' '--permanent --zone=trusted --add-source=93.184.216.34' '--permanent --zone=trusted --add-source=2001:db8::10' '--permanent --zone=trusted --add-service=http' '--permanent --zone=trusted --add-service=https' '--permanent --zone=trusted --add-port=8080/tcp' '--permanent --zone=trusted --set-target=DROP' '--reload'; do
	grep -Fqx -e "$pat" "$FWDYNHOSTS_MOCK/calls" || miss=1
done
grep -Fqx -e 'firewall-cmd --permanent --zone=trusted --add-source=203.0.113.10' "$T/stdout" || miss=1
ok '[ "$RC" -eq 0 ] && [ "$miss" -eq 0 ] && [ "$reloads" -eq 1 ] && grep -Fqx "Done." "$T/stdout"' "apply adds sources services ports target and reloads once"

: > "$FWDYNHOSTS_MOCK/calls"
run --apply
ok '[ "$RC" -eq 0 ] && grep -Fqx "Done." "$T/stdout" && ! grep -E "add-|remove-|new-zone|set-target|--reload" "$FWDYNHOSTS_MOCK/calls"' "second run makes no change and does not reload"

new_case
seed trusted "198.51.100.8"
printf '%s\n' '[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]' > "$T/dynhosts.json"
run
add=$(grep -n 'add-source=' "$FWDYNHOSTS_MOCK/calls" | head -1 | cut -d: -f1)
rem=$(grep -n 'remove-source=' "$FWDYNHOSTS_MOCK/calls" | head -1 | cut -d: -f1)
ok '[ "$RC" -eq 0 ] && [ -n "$add" ] && [ -n "$rem" ] && [ "$add" -lt "$rem" ] && grep -q "add-source=203.0.113.10" "$FWDYNHOSTS_MOCK/calls" && grep -q "remove-source=198.51.100.8" "$FWDYNHOSTS_MOCK/calls"' "stale source removed after add"

rej "dns failure changes nothing" '[{"zone":"trusted","ips":[],"hostnames":["example.com"]}]' "example.com fail"
rej "prefix 0 rejected" '[{"zone":"trusted","ips":["10.0.0.0/0"],"hostnames":[]}]'
rej "target ACCEPT rejected" '[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[],"target":"ACCEPT"}]'
rej "ssh on public rejected" '[{"zone":"public","ips":["203.0.113.10"],"hostnames":[],"services":["ssh"]}]'
rej "port 22 on cloudflare rejected" '[{"zone":"cloudflare","ips":["203.0.113.10"],"hostnames":[],"ports":["22/tcp"]}]'
rej "unknown key rejected" '[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[],"comment":"nope"}]'
rej "bad json rejected" 'not json'

new_case
export FWDYNHOSTS_FLOCK_BUSY=1
run
no_fw "busy lock rejected"

new_case
seed trusted "203.0.113.10" "http" "9/tcp" "DROP"
printf '%s\n' '[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]' > "$T/dynhosts.json"
run
zd="$FWDYNHOSTS_MOCK/state/trusted"
ok '[ "$RC" -eq 0 ] && [ "$(cat "$zd/services")" = "http" ] && [ "$(cat "$zd/ports")" = "9/tcp" ] && [ "$(cat "$zd/target")" = "DROP" ] && [ "$(cat "$zd/sources")" = "203.0.113.10" ] && ! grep -E "add-|remove-|set-target|--reload" "$FWDYNHOSTS_MOCK/calls"' "missing services key leaves services untouched"

new_case
seed trusted "203.0.113.10"
printf '%s\n' '[{"zone":"trusted","ips":[],"hostnames":[]}]' > "$T/dynhosts.json"
run
ok '[ "$RC" -eq 0 ] && [ ! -s "$FWDYNHOSTS_MOCK/state/trusted/sources" ] && grep -q "remove-source=203.0.113.10" "$FWDYNHOSTS_MOCK/calls" && ! grep -q "add-source=" "$FWDYNHOSTS_MOCK/calls" && grep -q -e "--reload" "$FWDYNHOSTS_MOCK/calls" && grep -Fqx "Done." "$T/stdout"' "empty ips and hostnames clears sources"

new_case
printf '%s\n' '173.245.48.0/20' '104.16.0.0/13' > "$T/v4"
printf '%s\n' '2400:cb00::/32' > "$T/v6"
printf '%s\n' '[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[],"services":["ssh"]},{"zone":"cloudflare","ips":["1.2.3.0/24"],"hostnames":[],"services":["http","https"]}]' > "$T/dynhosts.json"
chmod 640 "$T/dynhosts.json"
run --refresh-cloudflare
mode_now=$(stat -f '%OLp' "$T/dynhosts.json" 2>/dev/null || stat -c '%a' "$T/dynhosts.json")
ips=$(jq -c '[.[] | select(.zone == "cloudflare")][0].ips' "$T/dynhosts.json")
trusted=$(jq -c '[.[] | select(.zone == "trusted")][0] | {ips,hostnames,services}' "$T/dynhosts.json")
cf_svc=$(jq -c '[.[] | select(.zone == "cloudflare")][0].services' "$T/dynhosts.json")
reloads=$(grep -c -e '--reload' "$FWDYNHOSTS_MOCK/calls" || true)
want_ips='["173.245.48.0/20","104.16.0.0/13","2400:cb00::/32"]'
want_trusted='{"ips":["203.0.113.10"],"hostnames":[],"services":["ssh"]}'
want_svc='["http","https"]'
ok '[ "$RC" -eq 0 ] && [ "$mode_now" = 640 ] && [ "$reloads" -eq 1 ] && grep -Fqx "Done." "$T/stdout" && [ "$ips" = "$want_ips" ] && [ "$trusted" = "$want_trusted" ] && [ "$cf_svc" = "$want_svc" ] && grep -q "add-source=173.245.48.0/20" "$FWDYNHOSTS_MOCK/calls" && grep -q "add-source=2400:cb00::/32" "$FWDYNHOSTS_MOCK/calls"' "refresh-cloudflare writes ips and keeps other zones"

new_case
printf '%s\n' '173.245.48.0/20' '0.0.0.0/0' > "$T/v4"
printf '%s\n' '2400:cb00::/32' > "$T/v6"
printf '%s\n' '[{"zone":"cloudflare","ips":["1.2.3.0/24"],"hostnames":[]}]' > "$T/dynhosts.json"
cp "$T/dynhosts.json" "$T/before"
run --refresh-cloudflare
ok '[ "$RC" -ne 0 ] && cmp -s "$T/before" "$T/dynhosts.json" && [ ! -f "$FWDYNHOSTS_MOCK/calls" ] && ! grep -Fqx "Done." "$T/stdout"' "bad feed leaves config unchanged"

new_case
run --check
ok '[ "$RC" -eq 2 ] && [ -s "$T/stderr" ]' "unknown argument exits 2"

if [ "$FAILS" -ne 0 ]; then
	printf '%s\n' "$FAILS failed" >&2
	exit 1
fi
printf '%s\n' "all tests passed"
exit 0
