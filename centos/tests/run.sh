#!/usr/bin/env bash
# Exercise centos/fwdynhosts.sh with PATH mocks. Uses the real jq.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/centos/fwdynhosts.sh"
EXAMPLE="$ROOT/centos/dynhosts.json.example"
FAILS=0
ORIG_PATH=$PATH
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fwdynhosts-tests.XXXXXX")
BIN="$BASE/bin"
mkdir -p "$BIN"

cleanup_base() {
	rm -rf "$BASE"
}
trap cleanup_base EXIT

pass() {
	printf 'PASS %s\n' "$*"
}

fail() {
	FAILS=$((FAILS + 1))
	printf 'FAIL %s\n' "$*" >&2
	if [ -n "${T:-}" ]; then
		if [ -f "$T/stdout" ]; then
			printf '--- stdout ---\n' >&2
			cat "$T/stdout" >&2
		fi
		if [ -f "$T/stderr" ]; then
			printf '--- stderr ---\n' >&2
			cat "$T/stderr" >&2
		fi
		if [ -f "${FWDYNHOSTS_MOCK_DIR:-}/calls" ]; then
			printf '--- firewall-cmd ---\n' >&2
			cat "$FWDYNHOSTS_MOCK_DIR/calls" >&2
		fi
	fi
}

write_mocks() {
	cat > "$BIN/firewall-cmd" << 'EOF'
#!/usr/bin/env bash
set -eu
permanent=0
zone=""
op=""
val=""
mkdir -p "${FWDYNHOSTS_MOCK_DIR:?}"
printf '%s\n' "$*" >> "$FWDYNHOSTS_MOCK_DIR/calls"
for a in "$@"; do
	case "$a" in
		--permanent) permanent=1 ;;
		--reload) op=reload ;;
		--get-zones) op=get-zones ;;
		--get-services) op=get-services ;;
		--new-zone=*) op=new-zone; val=${a#--new-zone=} ;;
		--delete-zone=*) op=delete-zone; val=${a#--delete-zone=} ;;
		--zone=*) zone=${a#--zone=} ;;
		--list-sources) op=list-sources ;;
		--list-services) op=list-services ;;
		--list-ports) op=list-ports ;;
		--list-interfaces) op=list-interfaces ;;
		--get-target) op=get-target ;;
		--add-source=*) op=add-source; val=${a#--add-source=} ;;
		--remove-source=*) op=remove-source; val=${a#--remove-source=} ;;
		--add-service=*) op=add-service; val=${a#--add-service=} ;;
		--remove-service=*) op=remove-service; val=${a#--remove-service=} ;;
		--add-port=*) op=add-port; val=${a#--add-port=} ;;
		--remove-port=*) op=remove-port; val=${a#--remove-port=} ;;
		--set-target=*) op=set-target; val=${a#--set-target=} ;;
		*) printf 'unknown arg %s\n' "$a" >&2; exit 1 ;;
	esac
done
if [ -z "$op" ]; then
	printf '%s\n' "missing operation" >&2
	exit 1
fi
if [ "$permanent" -eq 1 ]; then
	dir=$FWDYNHOSTS_ZONES_DIR
else
	dir=$FWDYNHOSTS_MOCK_DIR/runtime
fi
if [ "${FWDYNHOSTS_MOCK_KILL:-}" = 1 ] && [ "$op" = add-source ]; then
	printf '\nCORRUPT\n' >> "$FWDYNHOSTS_ZONES_DIR/$zone.xml"
	kill -TERM "$PPID"
	exit 0
fi
if [ "${FWDYNHOSTS_MOCK_FAIL:-}" = "$op" ]; then
	if [ -n "$zone" ] && [ -f "$FWDYNHOSTS_ZONES_DIR/$zone.xml" ]; then
		printf '\nFAILMARKER\n' >> "$FWDYNHOSTS_ZONES_DIR/$zone.xml"
	fi
	exit 1
fi
require_perm() {
	if [ "$permanent" -ne 1 ]; then
		printf '%s\n' "mutation without --permanent" >&2
		exit 1
	fi
}
list_kind() {
	local kind="$1"
	local f="$dir/$zone.xml"
	local line out=""
	if [ ! -f "$f" ]; then
		printf 'missing zone %s\n' "$zone" >&2
		exit 1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			"$kind "*) out="$out ${line#"$kind "}" ;;
		esac
	done < "$f"
	if [ -n "$out" ]; then
		printf '%s\n' "${out# }"
	fi
}
add_kind() {
	local kind="$1"
	local f="$FWDYNHOSTS_ZONES_DIR/$zone.xml"
	require_perm
	if [ ! -f "$f" ]; then
		printf 'missing zone %s\n' "$zone" >&2
		exit 1
	fi
	if grep -Fxq -- "$kind $val" "$f"; then
		printf 'already present %s\n' "$val" >&2
		exit 1
	fi
	printf '%s %s\n' "$kind" "$val" >> "$f"
}
remove_kind() {
	local kind="$1"
	local f="$FWDYNHOSTS_ZONES_DIR/$zone.xml"
	local tmp
	require_perm
	if [ ! -f "$f" ]; then
		printf 'missing zone %s\n' "$zone" >&2
		exit 1
	fi
	if ! grep -Fxq -- "$kind $val" "$f"; then
		printf 'not present %s\n' "$val" >&2
		exit 1
	fi
	tmp=$(mktemp)
	grep -Fxv -- "$kind $val" "$f" > "$tmp" || true
	mv "$tmp" "$f"
}
case "$op" in
	get-services)
		printf '%s\n' "dhcpv6-client http https ssh cockpit"
		;;
	get-zones)
		out=""
		for f in "$dir"/*.xml; do
			[ -e "$f" ] || continue
			b=$(basename "$f" .xml)
			out="$out $b"
		done
		if [ -n "$out" ]; then
			printf '%s\n' "${out# }"
		fi
		;;
	reload)
		mkdir -p "$FWDYNHOSTS_MOCK_DIR/runtime"
		rm -f "$FWDYNHOSTS_MOCK_DIR/runtime"/*.xml
		for f in "$FWDYNHOSTS_ZONES_DIR"/*.xml; do
			[ -e "$f" ] || continue
			cp "$f" "$FWDYNHOSTS_MOCK_DIR/runtime/"
		done
		;;
	new-zone)
		require_perm
		f="$FWDYNHOSTS_ZONES_DIR/$val.xml"
		if [ -e "$f" ]; then
			printf 'zone exists\n' >&2
			exit 1
		fi
		printf 'target default\n' > "$f"
		;;
	delete-zone)
		require_perm
		rm -f "$FWDYNHOSTS_ZONES_DIR/$val.xml"
		;;
	list-sources) list_kind source ;;
	list-services) list_kind service ;;
	list-ports) list_kind port ;;
	list-interfaces) list_kind interface ;;
	get-target)
		f="$dir/$zone.xml"
		t=""
		if [ ! -f "$f" ]; then
			printf 'missing zone %s\n' "$zone" >&2
			exit 1
		fi
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
				target\ *) t=${line#target } ;;
			esac
		done < "$f"
		if [ -z "$t" ]; then
			t=default
		fi
		printf '%s\n' "$t"
		;;
	add-source) add_kind source ;;
	remove-source) remove_kind source ;;
	add-service) add_kind service ;;
	remove-service) remove_kind service ;;
	add-port) add_kind port ;;
	remove-port) remove_kind port ;;
	set-target)
		require_perm
		f="$FWDYNHOSTS_ZONES_DIR/$zone.xml"
		tmp=$(mktemp)
		found=0
		if [ ! -f "$f" ]; then
			printf 'missing zone %s\n' "$zone" >&2
			exit 1
		fi
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
				target\ *)
					printf 'target %s\n' "$val"
					found=1
					;;
				*)
					printf '%s\n' "$line"
					;;
			esac
		done < "$f" > "$tmp"
		if [ "$found" -eq 0 ]; then
			printf 'target %s\n' "$val" >> "$tmp"
		fi
		mv "$tmp" "$f"
		;;
	*)
		printf 'unhandled op %s\n' "$op" >&2
		exit 1
		;;
esac
exit 0
EOF
	cat > "$BIN/host" << 'EOF'
#!/usr/bin/env bash
set -eu
host=""
skip_next=0
for a in "$@"; do
	if [ "$skip_next" -eq 1 ]; then
		skip_next=0
		continue
	fi
	case "$a" in
		-W) skip_next=1 ;;
		-*) ;;
		*) host=$a ;;
	esac
done
[ -n "$host" ] || exit 1
file=${FWDYNHOSTS_HOST_FIXTURE:?}
found=0
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		''|\#*) continue ;;
	esac
	name=${line%% *}
	rest=${line#* }
	if [ "$name" != "$host" ]; then
		continue
	fi
	found=1
	status=${rest%% *}
	addrs=${rest#* }
	if [ "$status" = fail ]; then
		exit 1
	fi
	for item in $addrs; do
		case "$item" in
			A=*) printf '%s has address %s\n' "$host" "${item#A=}" ;;
			AAAA=*) printf '%s has IPv6 address %s\n' "$host" "${item#AAAA=}" ;;
			*) printf 'bad fixture %s\n' "$item" >&2; exit 1 ;;
		esac
	done
done < "$file"
[ "$found" -eq 1 ] || exit 1
exit 0
EOF
	cat > "$BIN/curl" << 'EOF'
#!/usr/bin/env bash
set -eu
url=""
mkdir -p "${FWDYNHOSTS_MOCK_DIR:?}"
printf '%s\n' "$*" >> "$FWDYNHOSTS_MOCK_DIR/curl-calls"
for a in "$@"; do
	case "$a" in
		https://*|http://*) url=$a ;;
	esac
done
case "$url" in
	https://www.cloudflare.com/ips-v4) cat "${FWDYNHOSTS_CURL_V4:?}" ;;
	https://www.cloudflare.com/ips-v6) cat "${FWDYNHOSTS_CURL_V6:?}" ;;
	*) printf 'unknown url %s\n' "$url" >&2; exit 1 ;;
esac
EOF
	cat > "$BIN/flock" << 'EOF'
#!/usr/bin/env bash
set -eu
mkdir -p "${FWDYNHOSTS_MOCK_DIR:?}"
printf '%s\n' "$*" >> "$FWDYNHOSTS_MOCK_DIR/flock-calls"
if [ "${FWDYNHOSTS_FLOCK_BUSY:-}" = 1 ]; then
	exit 1
fi
exit 0
EOF
	chmod +x "$BIN/firewall-cmd" "$BIN/host" "$BIN/curl" "$BIN/flock"
}

write_mocks

new_case() {
	T=$(mktemp -d "$BASE/case.XXXXXX")
	mkdir -p "$T/zones" "$T/state" "$T/mock/runtime"
	export FWDYNHOSTS_ASSUME_ROOT=1
	export FWDYNHOSTS_ZONES_DIR="$T/zones"
	export FWDYNHOSTS_MOCK_DIR="$T/mock"
	export FWDYNHOSTS_HOST_FIXTURE="$T/hosts"
	export FWDYNHOSTS_CURL_V4="$T/v4"
	export FWDYNHOSTS_CURL_V6="$T/v6"
	export PATH="$BIN:$ORIG_PATH"
	unset FWDYNHOSTS_MOCK_FAIL FWDYNHOSTS_MOCK_KILL FWDYNHOSTS_FLOCK_BUSY SSH_CONNECTION
	printf '%s\n' "example.com ok A=93.184.216.34" > "$T/hosts"
	printf '%s\n' "archive.org ok A=207.241.224.2" >> "$T/hosts"
	: > "$T/v4"
	: > "$T/v6"
}

write_zone() {
	local name="$1"
	cat > "$FWDYNHOSTS_ZONES_DIR/$name.xml"
	cp "$FWDYNHOSTS_ZONES_DIR/$name.xml" "$FWDYNHOSTS_MOCK_DIR/runtime/$name.xml"
}

seed_standard() {
	write_zone public << 'EOF'
target default
interface eth0
service http
service https
service dhcpv6-client
EOF
	write_zone trusted << 'EOF'
target ACCEPT
EOF
	write_zone work << 'EOF'
target default
service ssh
service cockpit
EOF
}

run() {
	bash "$SCRIPT" "$@" >"$T/stdout" 2>"$T/stderr"
	RC=$?
	return 0
}

assert_rc() {
	local want="$1"
	local name="$2"
	if [ "$RC" -eq "$want" ]; then
		pass "$name"
	else
		fail "$name: exit $RC wanted $want"
	fi
}

assert_done() {
	local name="$1"
	if grep -qx 'Done.' "$T/stdout"; then
		pass "$name"
	else
		fail "$name: missing Done."
	fi
}

assert_no_done() {
	local name="$1"
	if grep -qx 'Done.' "$T/stdout"; then
		fail "$name: printed Done."
	else
		pass "$name"
	fi
}

count_calls() {
	local needle="$1"
	if [ ! -f "$FWDYNHOSTS_MOCK_DIR/calls" ]; then
		printf '0\n'
		return 0
	fi
	grep -c -F -- "$needle" "$FWDYNHOSTS_MOCK_DIR/calls" || true
}

assert_no_mut() {
	local name="$1"
	local n=0
	n=$((n + $(count_calls '--add-source=')))
	n=$((n + $(count_calls '--remove-source=')))
	n=$((n + $(count_calls '--add-service=')))
	n=$((n + $(count_calls '--remove-service=')))
	n=$((n + $(count_calls '--add-port=')))
	n=$((n + $(count_calls '--remove-port=')))
	n=$((n + $(count_calls '--set-target=')))
	n=$((n + $(count_calls '--new-zone=')))
	n=$((n + $(count_calls '--delete-zone=')))
	n=$((n + $(count_calls '--reload')))
	if [ "$n" -eq 0 ]; then
		pass "$name"
	else
		fail "$name: $n mutation calls"
	fi
}

write_valid_feed() {
	cat > "$T/v4" << 'EOF'
192.0.2.0/24
198.51.100.0/24
203.0.113.0/24
198.51.101.0/24
198.51.102.0/24
198.51.103.0/24
198.51.104.0/24
198.51.105.0/24
198.51.106.0/24
198.51.107.0/24
EOF
	cat > "$T/v6" << 'EOF'
2001:db8::/32
2001:db8:1::/48
2001:db8:2::/48
2001:db8:3::/48
EOF
}

# 1. Initial apply from the example.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/public.xml" "$T/public.seed"
cp "$EXAMPLE" "$T/dynhosts.json"
run --config "$T/dynhosts.json" --state-dir "$T/state"
assert_rc 0 "1 apply exit"
assert_done "1 apply Done"
if [ "$(count_calls '--reload')" -eq 1 ]; then
	pass "1 one reload"
else
	fail "1 reload count $(count_calls '--reload')"
fi
if [ "$(count_calls '--new-zone=')" -eq 1 ]; then
	pass "1 creates cloudflare"
else
	fail "1 new-zone count $(count_calls '--new-zone=')"
fi
if cmp -s "$T/public.seed" "$FWDYNHOSTS_ZONES_DIR/public.xml"; then
	pass "1 public xml unchanged"
else
	fail "1 public xml changed"
fi
if grep -qx 'target default' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'service http' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'service https' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'service ssh' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 127.0.0.1' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 1.1.1.1' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 93.184.216.34' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 207.241.224.2' "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "1 trusted properties"
else
	fail "1 trusted properties"
fi
if grep -qx 'service ssh' "$FWDYNHOSTS_ZONES_DIR/work.xml" \
	&& grep -qx 'service cockpit' "$FWDYNHOSTS_ZONES_DIR/work.xml" \
	&& grep -qx 'source 203.0.113.10' "$FWDYNHOSTS_ZONES_DIR/work.xml" \
	&& grep -qx 'target default' "$FWDYNHOSTS_ZONES_DIR/work.xml"; then
	pass "1 work properties"
else
	fail "1 work properties"
fi
if [ -f "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" ] \
	&& grep -qx 'service http' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& grep -qx 'service https' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& grep -qx 'source 173.245.48.0/20' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& grep -qx 'source 2400:cb00::/32' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& ! grep -q '^interface ' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml"; then
	pass "1 cloudflare properties"
else
	fail "1 cloudflare properties"
fi
if [ -s "$FWDYNHOSTS_MOCK_DIR/flock-calls" ] && grep -qx -- '-n 9' "$FWDYNHOSTS_MOCK_DIR/flock-calls"; then
	pass "1 flock called"
else
	fail "1 flock was not recorded"
fi
if grep -q 'explicit --apply is the documented form' "$T/state/fwdynhosts.log"; then
	pass "1 logs documented apply"
else
	fail "1 missing documented apply log"
fi
mode=$(stat -f '%OLp' "$T/state" 2>/dev/null || stat -c '%a' "$T/state")
if [ "$mode" = 700 ]; then
	pass "1 state dir mode"
else
	fail "1 state dir mode $mode"
fi
mode=$(stat -f '%OLp' "$T/state/fwdynhosts.log" 2>/dev/null || stat -c '%a' "$T/state/fwdynhosts.log")
if [ "$mode" = 600 ]; then
	pass "1 log mode"
else
	fail "1 log mode $mode"
fi

# 2. Second apply is idempotent, then check is clean.
new_case
seed_standard
cp "$EXAMPLE" "$T/dynhosts.json"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
if [ "$RC" -ne 0 ]; then
	fail "2 first apply exit $RC"
else
	: > "$FWDYNHOSTS_MOCK_DIR/calls"
	run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
	assert_rc 0 "2 second apply exit"
	assert_no_mut "2 second apply no mutations"
	assert_done "2 second apply Done"
	run --config "$T/dynhosts.json" --state-dir "$T/state" --check
	assert_rc 0 "2 check clean"
	assert_no_mut "2 check no mutations"
fi

# 3. DNS failure with no last-known-good.
new_case
seed_standard
printf '%s\n' "example.com fail" > "$T/hosts"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":["example.com"]}]
EOF
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "3 dns failure exit"
assert_no_done "3 dns failure no Done"
assert_no_mut "3 dns failure no mutations"
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "3 zone xml unchanged"
else
	fail "3 zone xml changed"
fi

# 4. DNS failure uses last-known-good.
new_case
seed_standard
printf '%s\n' "good.example ok A=203.0.113.50" > "$T/hosts"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":[],"hostnames":["good.example"]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
if [ "$RC" -ne 0 ]; then
	fail "4 first apply exit $RC"
else
	printf '%s\n' "good.example fail" > "$T/hosts"
	: > "$FWDYNHOSTS_MOCK_DIR/calls"
	run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
	assert_rc 0 "4 lkg apply exit"
	if grep -qx 'source 203.0.113.50' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
		&& [ "$(count_calls '--remove-source=')" -eq 0 ]; then
		pass "4 keeps last-known-good"
	else
		fail "4 removed or lost last-known-good"
	fi
	if grep -q '203.0.113.50' "$T/state/dns-state.json"; then
		pass "4 dns state kept"
	else
		fail "4 dns state missing address"
	fi
fi

# 5. Duplicate zone names.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[
	{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]},
	{"zone":"trusted","ips":["203.0.113.11"],"hostnames":[]}
]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "5 duplicate zone exit"
assert_no_mut "5 duplicate zone no mutations"
assert_no_done "5 duplicate zone no Done"

# 6. Same source in two zones.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[
	{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]},
	{"zone":"work","ips":["203.0.113.10"],"hostnames":[]}
]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "6 duplicate source exit"
assert_no_mut "6 duplicate source no mutations"
if grep -q 'more than one zone' "$T/stderr"; then
	pass "6 duplicate source message"
else
	fail "6 duplicate source message"
fi

# 7. IPv4 and IPv6 CIDRs plus one A and one AAAA. Forbidden DNS fails the name.
new_case
seed_standard
printf '%s\n' "dual.example ok A=203.0.113.50 AAAA=2001:db8::5" > "$T/hosts"
cat > "$T/dynhosts.json" << 'EOF'
[{
	"zone": "trusted",
	"target": "default",
	"services": ["ssh"],
	"ips": ["203.0.113.0/24", "2001:db8:1::/48"],
	"hostnames": ["dual.example"]
}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "7 mixed apply exit"
if grep -qx 'source 203.0.113.0/24' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 2001:db8:1::/48' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 203.0.113.50' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 2001:db8::5' "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "7 all addresses applied"
else
	fail "7 all addresses applied"
fi
new_case
seed_standard
printf '%s\n' "bad.example ok A=127.0.0.1" > "$T/hosts"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":["bad.example"]}]
EOF
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "7 forbidden dns exit"
assert_no_mut "7 forbidden dns no mutations"
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "7 forbidden dns xml unchanged"
else
	fail "7 forbidden dns xml changed"
fi

# 8. Invalid Cloudflare feeds do not write or mutate.
for kind in empty html family few; do
	new_case
	seed_standard
	cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"cloudflare","ips":["203.0.113.9"],"hostnames":[]}]
EOF
	cp "$T/dynhosts.json" "$T/before.json"
	write_valid_feed
	case "$kind" in
		empty) : > "$T/v4" ;;
		html) printf '%s\n' '<html></html>' > "$T/v4" ;;
		family) printf '%s\n' '2001:db8::/32' > "$T/v4" ;;
		few)
			cat > "$T/v4" << 'EOF'
192.0.2.0/24
198.51.100.0/24
203.0.113.0/24
EOF
			;;
	esac
	run --config "$T/dynhosts.json" --state-dir "$T/state" --refresh-cloudflare --apply
	assert_rc 1 "8 $kind feed exit"
	assert_no_mut "8 $kind feed no mutations"
	if cmp -s "$T/before.json" "$T/dynhosts.json"; then
		pass "8 $kind config unchanged"
	else
		fail "8 $kind config changed"
	fi
done

# 9. Valid feed without --apply prints a diff and does not write.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"cloudflare","ips":["203.0.113.9"],"hostnames":[]}]
EOF
cp "$T/dynhosts.json" "$T/before.json"
write_valid_feed
run --config "$T/dynhosts.json" --state-dir "$T/state" --refresh-cloudflare
assert_rc 0 "9 refresh print exit"
assert_done "9 refresh print Done"
assert_no_mut "9 refresh print no mutations"
if grep -qx 'cloudflare ip removed 203.0.113.9' "$T/stdout" \
	&& grep -qx 'cloudflare ip added 192.0.2.0/24' "$T/stdout" \
	&& grep -qx 'Not writing config' "$T/stdout" \
	&& cmp -s "$T/before.json" "$T/dynhosts.json"; then
	pass "9 prints diff and does not write"
else
	fail "9 prints diff and does not write"
fi
if grep -q -- '--proto' "$FWDYNHOSTS_MOCK_DIR/curl-calls" \
	&& grep -q -- '--tlsv1.2' "$FWDYNHOSTS_MOCK_DIR/curl-calls" \
	&& grep -q -- '--max-time' "$FWDYNHOSTS_MOCK_DIR/curl-calls"; then
	pass "9 curl flags"
else
	fail "9 curl flags"
fi

# 10. Interrupted apply restores zone xml.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
export FWDYNHOSTS_MOCK_KILL=1
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset FWDYNHOSTS_MOCK_KILL
if [ "$RC" -ne 0 ]; then
	pass "10 interrupt exit"
else
	fail "10 interrupt exit was 0"
fi
assert_no_done "10 interrupt no Done"
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& ! grep -q CORRUPT "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "10 restored zone xml"
else
	fail "10 restored zone xml"
fi

# 11. Mutation failure restores zone xml.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
export FWDYNHOSTS_MOCK_FAIL=add-source
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset FWDYNHOSTS_MOCK_FAIL
if [ "$RC" -ne 0 ]; then
	pass "11 mutation failure exit"
else
	fail "11 mutation failure exit was 0"
fi
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& ! grep -q FAILMARKER "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "11 restored zone xml"
else
	fail "11 restored zone xml"
fi

# 12. Rollback restores the backup taken before apply.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
if [ "$RC" -ne 0 ]; then
	fail "12 apply before rollback exit $RC"
else
	run --config "$T/dynhosts.json" --state-dir "$T/state" --rollback
	assert_rc 0 "12 rollback exit"
	assert_done "12 rollback Done"
	if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
		pass "12 restored backup"
	else
		fail "12 restored backup"
	fi
fi

# 13. target ACCEPT is rejected for every zone.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"ACCEPT","ips":["203.0.113.10"],"hostnames":[]}]
EOF
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "13 trusted ACCEPT exit"
assert_no_mut "13 trusted ACCEPT no mutations"
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "13 trusted ACCEPT xml unchanged"
else
	fail "13 trusted ACCEPT xml changed"
fi
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"other","target":"ACCEPT","ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "13 other ACCEPT exit"
assert_no_mut "13 other ACCEPT no mutations"

# 14. migrate and refresh need cloudflare. Legacy apply does not touch services or target.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/public.xml" "$T/public.seed"
run --config "$T/dynhosts.json" --state-dir "$T/state" --migrate-public-web --confirm
assert_rc 1 "14 migrate without cloudflare"
assert_no_mut "14 migrate without cloudflare no mutations"
if cmp -s "$T/public.seed" "$FWDYNHOSTS_ZONES_DIR/public.xml"; then
	pass "14 migrate left public alone"
else
	fail "14 migrate changed public"
fi
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
cp "$T/dynhosts.json" "$T/before.json"
write_valid_feed
run --config "$T/dynhosts.json" --state-dir "$T/state" --refresh-cloudflare --apply
assert_rc 1 "14 refresh without cloudflare"
assert_no_mut "14 refresh without cloudflare no mutations"
if cmp -s "$T/before.json" "$T/dynhosts.json"; then
	pass "14 refresh left config alone"
else
	fail "14 refresh changed config"
fi
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "14 legacy apply exit"
if [ "$(count_calls '--set-target=')" -eq 0 ] \
	&& [ "$(count_calls '--add-service=')" -eq 0 ] \
	&& [ "$(count_calls '--remove-service=')" -eq 0 ] \
	&& [ "$(count_calls '--add-port=')" -eq 0 ] \
	&& [ "$(count_calls '--remove-port=')" -eq 0 ] \
	&& [ "$(count_calls '--add-source=')" -ge 1 ] \
	&& [ "$(count_calls '--reload')" -eq 1 ] \
	&& grep -qx 'target ACCEPT' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 203.0.113.10' "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "14 legacy apply sources only"
else
	fail "14 legacy apply sources only"
fi

# 15. A manual extra source is reported and removed.
new_case
seed_standard
printf '%s\n' "source 198.51.100.50" >> "$FWDYNHOSTS_ZONES_DIR/trusted.xml"
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$FWDYNHOSTS_MOCK_DIR/runtime/trusted.xml"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "15 extra source exit"
if grep -q '198.51.100.50' "$T/stdout" \
	&& ! grep -q '198.51.100.50' "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -qx 'source 203.0.113.10' "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "15 removed manual extra"
else
	fail "15 removed manual extra"
fi

# 16. Dry-run prints the plan and does not mutate.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --dry-run
assert_rc 0 "16 dry-run exit"
assert_done "16 dry-run Done"
assert_no_mut "16 dry-run no mutations"
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& grep -q 'firewall-cmd --permanent --zone=trusted --add-source=203.0.113.10' "$T/stdout"; then
	pass "16 dry-run plan only"
else
	fail "16 dry-run plan only"
fi

# 17. Runtime versus permanent source drift fails check.
new_case
seed_standard
printf '%s\n' "source 198.51.100.77" >> "$FWDYNHOSTS_MOCK_DIR/runtime/trusted.xml"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":[],"hostnames":[]}]
EOF
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
run --config "$T/dynhosts.json" --state-dir "$T/state" --check
assert_rc 1 "17 runtime drift exit"
assert_no_mut "17 runtime drift no mutations"
assert_no_done "17 runtime drift no Done"
if grep -q 'runtime differs from permanent for zone trusted sources' "$T/stdout" \
	&& cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "17 reports runtime drift"
else
	fail "17 reports runtime drift"
fi

# 18. Busy lock.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
export FWDYNHOSTS_FLOCK_BUSY=1
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset FWDYNHOSTS_FLOCK_BUSY
assert_rc 1 "18 busy lock exit"
assert_no_mut "18 busy lock no mutations"
if [ -s "$FWDYNHOSTS_MOCK_DIR/flock-calls" ]; then
	pass "18 flock was called"
else
	fail "18 flock was called"
fi

# Interrupted-run recovery on the next start.
new_case
seed_standard
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
mkdir -p "$T/state/backups/manual/xml"
cp "$T/trusted.seed" "$T/state/backups/manual/xml/trusted.xml"
printf '%s\n' "trusted file" > "$T/state/backups/manual/manifest"
printf '%s\n' "GARBAGE" >> "$FWDYNHOSTS_ZONES_DIR/trusted.xml"
printf '%s\n' "$T/state/backups/manual" > "$T/state/in-progress"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":[],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --check
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml" \
	&& [ ! -f "$T/state/in-progress" ] \
	&& grep -q 'Recovering interrupted run' "$T/stdout"; then
	pass "19 recovered in-progress backup"
else
	fail "19 recovered in-progress backup"
fi

# Refresh apply that fails later restores the config and the zone xml.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[
	{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":[]},
	{"zone":"cloudflare","target":"default","services":["http","https"],"ips":["203.0.113.9"],"hostnames":[]}
]
EOF
cp "$T/dynhosts.json" "$T/before.json"
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
write_valid_feed
export FWDYNHOSTS_MOCK_FAIL=add-source
run --config "$T/dynhosts.json" --state-dir "$T/state" --refresh-cloudflare --apply
unset FWDYNHOSTS_MOCK_FAIL
if [ "$RC" -ne 0 ] && cmp -s "$T/before.json" "$T/dynhosts.json" \
	&& cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "20 failed apply restores config and xml"
else
	fail "20 failed apply restores config and xml"
fi

# SSH client coverage and the no-SSH abort.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["1.1.1.1"],"hostnames":[]}]
EOF
export SSH_CONNECTION="203.0.113.99 50000 10.0.0.1 22"
cp "$FWDYNHOSTS_ZONES_DIR/trusted.xml" "$T/trusted.seed"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset SSH_CONNECTION
assert_rc 1 "21 uncovered ssh client"
assert_no_mut "21 uncovered ssh client no mutations"
if cmp -s "$T/trusted.seed" "$FWDYNHOSTS_ZONES_DIR/trusted.xml"; then
	pass "21 uncovered ssh client xml unchanged"
else
	fail "21 uncovered ssh client xml changed"
fi
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["1.1.1.1"],"hostnames":[]}]
EOF
export SSH_CONNECTION="1.1.1.1 50000 10.0.0.1 22"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset SSH_CONNECTION
assert_rc 0 "21 covered ssh client"
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[
	{"zone":"trusted","target":"DROP","services":["http"],"ips":["203.0.113.10"],"hostnames":[]},
	{"zone":"work","target":"default","services":["http"],"ips":["203.0.113.11"],"hostnames":[]}
]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "21 no ssh zone"
assert_no_mut "21 no ssh zone no mutations"
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["2001:db8::/32"],"hostnames":[]}]
EOF
export SSH_CONNECTION="2001:db8::5 1 2001:db8::1 22"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset SSH_CONNECTION
assert_rc 1 "21 ipv6 prefix not covered"
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["2001:db8::5"],"hostnames":[]}]
EOF
export SSH_CONNECTION="2001:0db8:0:0:0:0:0:5 1 2001:db8::1 22"
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset SSH_CONNECTION
assert_rc 0 "21 ipv6 exact match"

# Public web migration.
new_case
seed_standard
write_zone cloudflare << 'EOF'
target default
service http
service https
source 203.0.113.20
EOF
cp "$FWDYNHOSTS_ZONES_DIR/public.xml" "$T/public.seed"
run --state-dir "$T/state" --migrate-public-web
assert_rc 2 "22 migrate preview exit"
assert_no_done "22 migrate preview no Done"
assert_no_mut "22 migrate preview no mutations"
if grep -q 'Would remove service http from zone public' "$T/stdout" \
	&& cmp -s "$T/public.seed" "$FWDYNHOSTS_ZONES_DIR/public.xml"; then
	pass "22 migrate preview text"
else
	fail "22 migrate preview text"
fi
new_case
seed_standard
write_zone cloudflare << 'EOF'
target default
service http
service https
source 203.0.113.20
EOF
cp "$FWDYNHOSTS_ZONES_DIR/public.xml" "$T/public.seed"
run --state-dir "$T/state" --migrate-public-web --dry-run
assert_rc 0 "22 migrate dry-run exit"
assert_no_mut "22 migrate dry-run no mutations"
if cmp -s "$T/public.seed" "$FWDYNHOSTS_ZONES_DIR/public.xml" \
	&& grep -q 'firewall-cmd --permanent --zone=public --remove-service=http' "$T/stdout"; then
	pass "22 migrate dry-run plan"
else
	fail "22 migrate dry-run plan"
fi
new_case
seed_standard
write_zone cloudflare << 'EOF'
target default
service http
service https
source 203.0.113.20
EOF
run --state-dir "$T/state" --migrate-public-web --confirm
assert_rc 0 "22 migrate confirm exit"
if grep -qx 'interface eth0' "$FWDYNHOSTS_ZONES_DIR/public.xml" \
	&& grep -qx 'service dhcpv6-client' "$FWDYNHOSTS_ZONES_DIR/public.xml" \
	&& ! grep -qx 'service http' "$FWDYNHOSTS_ZONES_DIR/public.xml" \
	&& ! grep -qx 'service https' "$FWDYNHOSTS_ZONES_DIR/public.xml" \
	&& grep -qx 'source 203.0.113.20' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& grep -qx 'service http' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& grep -qx 'service https' "$FWDYNHOSTS_ZONES_DIR/cloudflare.xml" \
	&& [ "$(count_calls '--reload')" -eq 1 ]; then
	pass "22 migrate removed only public http https"
else
	fail "22 migrate removed only public http https"
fi

# Normalized identity, forbidden static sources, and overlapping CIDRs.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["01.2.3.4"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "23 leading zero exit"
assert_no_mut "23 leading zero no mutations"
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["0.0.0.0/0"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "23 default route exit"
assert_no_mut "23 default route no mutations"
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[
	{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]},
	{"zone":"work","ips":["203.0.113.10/32"],"hostnames":[]}
]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 1 "23 normalized duplicate exit"
assert_no_mut "23 normalized duplicate no mutations"
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[
	{"zone":"trusted","target":"default","services":["ssh"],"ips":["10.0.0.0/8"],"hostnames":[]},
	{"zone":"work","target":"default","services":["ssh"],"ips":["10.1.0.0/16"],"hostnames":[]}
]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "23 overlapping cidrs allowed"

# 24. Successful apply writes status.json; --status is OK.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "24 apply exit"
if [ -f "$T/state/status.json" ] \
	&& [ "$(jq -r '.result' "$T/state/status.json")" = ok ] \
	&& [ "$(jq -r '.changes' "$T/state/status.json")" -gt 0 ] \
	&& [ "$(jq -r '.reloaded' "$T/state/status.json")" = true ]; then
	pass "24 status.json ok with changes"
else
	fail "24 status.json ok with changes"
fi
mode=$(stat -f '%OLp' "$T/state/status.json" 2>/dev/null || stat -c '%a' "$T/state/status.json")
if [ "$mode" = 600 ]; then
	pass "24 status.json mode"
else
	fail "24 status.json mode $mode"
fi
finished=$(jq -r '.finished' "$T/state/status.json")
changes=$(jq -r '.changes' "$T/state/status.json")
reloaded=$(jq -r '.reloaded' "$T/state/status.json")
: > "$FWDYNHOSTS_MOCK_DIR/calls"
: > "$FWDYNHOSTS_MOCK_DIR/flock-calls"
run --state-dir "$T/state" --status
assert_rc 0 "24 status exit"
assert_no_done "24 status no Done"
if grep -qx "OK - last run $finished changes=$changes reloaded=$reloaded" "$T/stdout" \
	&& [ "$(wc -l < "$T/stdout" | tr -d ' ')" -eq 1 ]; then
	pass "24 status OK line"
else
	fail "24 status OK line"
fi
if [ "$(count_calls '--reload')" -eq 0 ] && [ ! -s "$FWDYNHOSTS_MOCK_DIR/flock-calls" ]; then
	pass "24 status no firewall or lock"
else
	fail "24 status no firewall or lock"
fi

# 25. Idempotent second apply: changes 0, reloaded false, last_success updated.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
if [ "$RC" -ne 0 ]; then
	fail "25 first apply exit $RC"
else
	first_success=$(jq -r '.last_success' "$T/state/status.json")
	run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
	assert_rc 0 "25 second apply exit"
	if [ "$(jq -r '.changes' "$T/state/status.json")" -eq 0 ] \
		&& [ "$(jq -r '.reloaded' "$T/state/status.json")" = false ] \
		&& [ "$(jq -r '.result' "$T/state/status.json")" = ok ] \
		&& [ "$(jq -r '.last_success' "$T/state/status.json")" = "$(jq -r '.finished' "$T/state/status.json")" ]; then
		pass "25 noop status fields"
	else
		fail "25 noop status fields"
	fi
	second_success=$(jq -r '.last_success' "$T/state/status.json")
	if [ -n "$second_success" ] && [ -n "$first_success" ]; then
		pass "25 last_success present"
	else
		fail "25 last_success present"
	fi
fi

# 26. DNS hard failure carries last_success; --status is CRITICAL.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
if [ "$RC" -ne 0 ]; then
	fail "26 first apply exit $RC"
else
	prior=$(jq -r '.last_success' "$T/state/status.json")
	printf '%s\n' "missing.example fail" > "$T/hosts"
	cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":["203.0.113.10"],"hostnames":["missing.example"]}]
EOF
	run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
	assert_rc 1 "26 dns failure exit"
	if [ "$(jq -r '.result' "$T/state/status.json")" = failed ] \
		&& [ -n "$(jq -r '.error' "$T/state/status.json")" ] \
		&& [ "$(jq -r '.error' "$T/state/status.json")" != "null" ] \
		&& [ "$(jq -r '.consecutive_failures' "$T/state/status.json")" -eq 1 ] \
		&& [ "$(jq -r '.last_success' "$T/state/status.json")" = "$prior" ]; then
		pass "26 failed status carries last_success"
	else
		fail "26 failed status carries last_success"
	fi
	run --state-dir "$T/state" --status
	assert_rc 2 "26 status CRITICAL exit"
	assert_no_done "26 status CRITICAL no Done"
	if grep -q '^CRITICAL - ' "$T/stdout" \
		&& grep -q 'consecutive_failures=1' "$T/stdout"; then
		pass "26 status CRITICAL text"
	else
		fail "26 status CRITICAL text"
	fi
fi

# 27. LKG used: --status is WARNING naming the host.
new_case
seed_standard
printf '%s\n' "good.example ok A=203.0.113.50" > "$T/hosts"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","target":"default","services":["ssh"],"ips":[],"hostnames":["good.example"]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
if [ "$RC" -ne 0 ]; then
	fail "27 first apply exit $RC"
else
	printf '%s\n' "good.example fail" > "$T/hosts"
	run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
	assert_rc 0 "27 lkg apply exit"
	run --state-dir "$T/state" --status
	assert_rc 1 "27 status WARNING exit"
	assert_no_done "27 status WARNING no Done"
	if grep -qx 'WARNING - DNS last-known-good used for good.example' "$T/stdout"; then
		pass "27 status WARNING names host"
	else
		fail "27 status WARNING names host"
	fi
fi

# 28. --check and --dry-run do not create or modify status.json.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":[],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --check
assert_rc 0 "28 check exit"
if [ ! -e "$T/state/status.json" ]; then
	pass "28 check does not create status.json"
else
	fail "28 check created status.json"
fi
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "28 apply before dry-run"
cp "$T/state/status.json" "$T/status.before"
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10","203.0.113.11"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --dry-run
assert_rc 0 "28 dry-run exit"
if cmp -s "$T/status.before" "$T/state/status.json"; then
	pass "28 dry-run does not modify status.json"
else
	fail "28 dry-run modified status.json"
fi

# 29. Busy lock does not modify status.json.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "29 apply before busy lock"
cp "$T/state/status.json" "$T/status.before"
export FWDYNHOSTS_FLOCK_BUSY=1
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset FWDYNHOSTS_FLOCK_BUSY
assert_rc 1 "29 busy lock exit"
if cmp -s "$T/status.before" "$T/state/status.json"; then
	pass "29 busy lock does not modify status.json"
else
	fail "29 busy lock modified status.json"
fi
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
export FWDYNHOSTS_FLOCK_BUSY=1
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset FWDYNHOSTS_FLOCK_BUSY
if [ ! -e "$T/state/status.json" ]; then
	pass "29 busy lock does not create status.json"
else
	fail "29 busy lock created status.json"
fi

# 30. Missing status.json: --status exits 3.
new_case
run --state-dir "$T/state" --status
assert_rc 3 "30 missing status exit"
assert_no_done "30 missing status no Done"
if grep -qx 'UNKNOWN - status.json missing' "$T/stdout"; then
	pass "30 missing status text"
else
	fail "30 missing status text"
fi
if [ ! -e "$T/nosuch" ]; then
	run --state-dir "$T/nosuch" --status
	assert_rc 3 "30 missing dir exit"
	if [ ! -e "$T/nosuch" ]; then
		pass "30 status does not create state dir"
	else
		fail "30 status created state dir"
	fi
fi

# 31. Stale last_success is CRITICAL; --max-age 600 is OK.
new_case
old=$(( $(date +%s) - 10800 ))
if ts=$(date -u -d "@$old" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
	:
else
	ts=$(date -u -r "$old" '+%Y-%m-%dT%H:%M:%SZ')
fi
jq -n --arg ts "$ts" '{
	schema: 1,
	host: "test",
	mode: "apply",
	started: $ts,
	finished: $ts,
	duration_s: 1,
	result: "ok",
	exit_code: 0,
	error: "",
	changes: 0,
	reloaded: false,
	dns_lkg_hosts: [],
	runtime_drift: false,
	recovered: false,
	rolled_back: false,
	last_success: $ts,
	consecutive_failures: 0
}' > "$T/state/status.json"
run --state-dir "$T/state" --status
assert_rc 2 "31 stale status exit"
assert_no_done "31 stale status no Done"
if grep -q '^CRITICAL - ' "$T/stdout" \
	&& grep -q 'consecutive_failures=0' "$T/stdout" \
	&& grep -q 'minutes old' "$T/stdout"; then
	pass "31 stale status text"
else
	fail "31 stale status text"
fi
run --state-dir "$T/state" --status --max-age 600
assert_rc 0 "31 max-age 600 exit"
if grep -q '^OK - last run ' "$T/stdout"; then
	pass "31 max-age 600 OK"
else
	fail "31 max-age 600 OK"
fi

# 32. Mutation failure with rollback records rolled_back.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
export FWDYNHOSTS_MOCK_FAIL=add-source
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
unset FWDYNHOSTS_MOCK_FAIL
assert_rc 1 "32 mutation failure exit"
if [ "$(jq -r '.result' "$T/state/status.json")" = failed ] \
	&& [ "$(jq -r '.rolled_back' "$T/state/status.json")" = true ]; then
	pass "32 rolled_back true"
else
	fail "32 rolled_back true"
fi

# 33. Log rotation when fwdynhosts.log exceeds 5 MiB.
new_case
seed_standard
cat > "$T/dynhosts.json" << 'EOF'
[{"zone":"trusted","ips":["203.0.113.10"],"hostnames":[]}]
EOF
dd if=/dev/zero of="$T/state/fwdynhosts.log" bs=1024 count=5121 >/dev/null 2>&1
run --config "$T/dynhosts.json" --state-dir "$T/state" --apply
assert_rc 0 "33 apply after large log"
if [ -f "$T/state/fwdynhosts.log.1" ] \
	&& [ -f "$T/state/fwdynhosts.log" ] \
	&& [ "$(wc -c < "$T/state/fwdynhosts.log.1" | tr -d ' ')" -gt 5242880 ] \
	&& [ "$(wc -c < "$T/state/fwdynhosts.log" | tr -d ' ')" -lt 5242880 ]; then
	pass "33 log rotated"
else
	fail "33 log rotated"
fi

# 34. Flag combinations for --status and --max-age.
new_case
run --state-dir "$T/state" --max-age 90
assert_rc 2 "34 max-age without status"
new_case
run --state-dir "$T/state" --status --apply
assert_rc 2 "34 status with apply"

if [ "$FAILS" -ne 0 ]; then
	printf '%s\n' "$FAILS failed" >&2
	exit 1
fi
printf '%s\n' "all tests passed"
exit 0
