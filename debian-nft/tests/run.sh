#!/usr/bin/env bash
# Mock nft and host. Does not touch /etc/nftables.conf.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/debian-nft/fwdynhosts.sh"
FAILS=0
BASE=$(mktemp -d)
BIN="$BASE/bin"
mkdir -p "$BIN"
trap 'rm -rf "$BASE"' EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$*" >&2; }

cat > "$BIN/nft" << 'EOF'
#!/usr/bin/env bash
mkdir -p "${FWDYNHOSTS_MOCK:?}"
printf '%s\n' "$*" >> "$FWDYNHOSTS_MOCK/calls"
if [ "${1:-}" = -f ]; then
	printf '%s\n' "-- file --" >> "$FWDYNHOSTS_MOCK/calls"
	cat "$2" >> "$FWDYNHOSTS_MOCK/calls"
fi
if [ "${FWDYNHOSTS_NFT_FAIL:-}" = 1 ]; then
	exit 1
fi
exit 0
EOF
cat > "$BIN/host" << 'EOF'
#!/usr/bin/env bash
host=""
skip=0
for a in "$@"; do
	if [ "$skip" -eq 1 ]; then skip=0; continue; fi
	case "$a" in
		-W) skip=1 ;;
		-*) ;;
		*) host=$a ;;
	esac
done
[ -n "$host" ] || exit 1
found=0
while IFS= read -r line || [ -n "$line" ]; do
	name=${line%% *}
	rest=${line#* }
	[ "$name" = "$host" ] || continue
	found=1
	if [ "$rest" = fail ]; then exit 1; fi
	for item in $rest; do
		printf '%s has address %s\n' "$host" "$item"
	done
done < "${FWDYNHOSTS_HOSTS:?}"
[ "$found" -eq 1 ] || exit 1
EOF
cat > "$BIN/flock" << 'EOF'
#!/usr/bin/env bash
if [ "${FWDYNHOSTS_FLOCK_BUSY:-}" = 1 ]; then exit 1; fi
exit 0
EOF
chmod +x "$BIN/nft" "$BIN/host" "$BIN/flock"

new_case() {
	T=$(mktemp -d "$BASE/case.XXXXXX")
	export FWDYNHOSTS_MOCK="$T/mock"
	export FWDYNHOSTS_HOSTS="$T/hosts"
	export FWDYNHOSTS_CONFIG="$T/dynhosts.json"
	export FWDYNHOSTS_STATE_DIR="$T/state"
	export PATH="$BIN:$PATH"
	mkdir -p "$FWDYNHOSTS_MOCK"
	unset FWDYNHOSTS_NFT_FAIL FWDYNHOSTS_FLOCK_BUSY
	printf '%s\n' "example.com 93.184.216.34" > "$T/hosts"
	printf '%s\n' "archive.org 207.241.224.2" >> "$T/hosts"
	cp "$ROOT/debian-nft/dynhosts.json.example" "$T/dynhosts.json"
}

run() {
	set +e
	bash "$SCRIPT" >"$T/stdout" 2>"$T/stderr"
	RC=$?
	set -e
	return 0
}

if grep -E 'nft list|flush ruleset|delete table|> /etc/nftables.conf' "$SCRIPT"; then
	fail "script still rewrites the rules file"
else
	pass "script does not dump or rewrite the rules file"
fi

new_case
run
if [ "$RC" -eq 0 ] && grep -q 'flush set ip firewall management' "$FWDYNHOSTS_MOCK/calls" \
	&& grep -q '93.184.216.34' "$FWDYNHOSTS_MOCK/calls" \
	&& grep -q '207.241.224.2' "$FWDYNHOSTS_MOCK/calls" \
	&& grep -qx 'Done.' "$T/stdout"; then
	pass "refresh writes one set transaction"
else
	fail "refresh writes one set transaction"
fi

new_case
printf '%s\n' "example.com fail" > "$T/hosts"
run
if [ "$RC" -ne 0 ] && [ ! -s "$FWDYNHOSTS_MOCK/calls" ] && ! grep -qx 'Done.' "$T/stdout"; then
	pass "dns failure changes nothing"
else
	fail "dns failure changes nothing"
fi

new_case
printf '%s\n' '[{"set":"management","ips":["0.0.0.0/0"],"hostnames":[]}]' > "$T/dynhosts.json"
run
if [ "$RC" -ne 0 ] && [ ! -s "$FWDYNHOSTS_MOCK/calls" ]; then
	pass "world address rejected"
else
	fail "world address rejected"
fi

new_case
printf '%s\n' 'not json' > "$T/dynhosts.json"
run
if [ "$RC" -ne 0 ] && [ ! -s "$FWDYNHOSTS_MOCK/calls" ]; then
	pass "bad json changes nothing"
else
	fail "bad json changes nothing"
fi

new_case
export FWDYNHOSTS_FLOCK_BUSY=1
run
unset FWDYNHOSTS_FLOCK_BUSY
if [ "$RC" -ne 0 ] && [ ! -s "$FWDYNHOSTS_MOCK/calls" ]; then
	pass "busy lock changes nothing"
else
	fail "busy lock changes nothing"
fi

new_case
printf '%s\n' '[{"set":"management","ips":[],"hostnames":[]}]' > "$T/dynhosts.json"
run
if [ "$RC" -ne 0 ] && [ ! -s "$FWDYNHOSTS_MOCK/calls" ]; then
	pass "empty set is not flushed"
else
	fail "empty set is not flushed"
fi

if [ "$FAILS" -ne 0 ]; then
	printf '%s\n' "$FAILS failed" >&2
	exit 1
fi
printf '%s\n' "all tests passed"
exit 0
