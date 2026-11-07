#!/usr/bin/env bash
# fwdynhosts.sh - replace firewalld sources, and optional services, ports, and target.
#
#   /opt/fwdynhosts/fwdynhosts.sh [--config PATH] [--state-dir PATH]
#       [--check|--dry-run|--apply|--rollback|--status]
#       [--max-age MINUTES]
#       [--refresh-cloudflare] [--migrate-public-web [--confirm]]
#
# Default config remains /opt/fwdynhosts/dynhosts.json. --config exists so tests
# can point at another file. firewalld has no transaction: permanent changes are
# written, then one reload swaps the ruleset. A crash is recovered from the
# backup on the next run. SIGKILL during firewall-cmd can leave one zone XML
# partial until that recovery.

set -Eeuo pipefail
umask 077

PUBLIC_ZONE=public
PUBLIC_IFACE=eth0
CF_ZONE=cloudflare

CONFIG=/opt/fwdynhosts/dynhosts.json
STATE_DIR=/var/lib/fwdynhosts
# Test seam. Production leaves this unset and uses /etc/firewalld/zones.
ZONES_DIR=${FWDYNHOSTS_ZONES_DIR:-/etc/firewalld/zones}

MUTATION_STARTED=0
COMMITTED=0
CONFIG_CHANGED=0
CONFIG_BACKUP=""
CONFIG_MODE=""
BACKUP_DIR=""
WORK=""
LOG_FILE=""
MODE=""
MODE_SET=0
REFRESH=0
MIGRATE=0
CONFIRM=0
DEFAULTED_APPLY=0
DNS_STATE=""
CF_V4_URL=https://www.cloudflare.com/ips-v4
CF_V6_URL=https://www.cloudflare.com/ips-v6
LOG_MAX_BYTES=5242880
LAST_ERROR=""
CHANGES=0
RELOADED=0
RECOVERED=0
ROLLED_BACK=0
RECORD_STATUS=0
START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
START_EPOCH=$(date +%s)
MAX_AGE=90
MAX_AGE_SET=0
CONFIG_SET=0

say() {
	printf '%s\n' "$*"
}

log_event() {
	local level="$1"
	local msg="$2"
	local zone="${3:-}"
	local source="${4:-}"
	local action="${5:-}"
	local extra="${6-}"
	local ts line
	[ -n "$LOG_FILE" ] || return 0
	[ -d "$STATE_DIR" ] || return 0
	if [ -z "$extra" ]; then
		extra='{}'
	fi
	ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 0
	line=$(jq -nc \
		--arg ts "$ts" \
		--arg level "$level" \
		--arg msg "$msg" \
		--arg zone "$zone" \
		--arg source "$source" \
		--arg action "$action" \
		--argjson extra "$extra" \
		'{ts:$ts, level:$level, msg:$msg}
		 + (if $zone == "" then {} else {zone:$zone} end)
		 + (if $source == "" then {} else {source:$source} end)
		 + (if $action == "" then {} else {action:$action} end)
		 + $extra') || return 0
	printf '%s\n' "$line" >> "$LOG_FILE" || return 0
	return 0
}

die() {
	LAST_ERROR="$*"
	printf '%s\n' "fwdynhosts: $*" >&2
	log_event error "$*"
	exit 1
}

usage() {
	printf '%s\n' "fwdynhosts: $*" >&2
	exit 2
}

finish() {
	say "Done."
	exit 0
}

rotate_log_if_needed() {
	local size
	[ -f "$LOG_FILE" ] || return 0
	size=$(( $(wc -c < "$LOG_FILE") )) || return 0
	[ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
	mv -f "$LOG_FILE" "$LOG_FILE.1" || die "cannot rotate log"
	: > "$LOG_FILE"
	chmod 0600 "$LOG_FILE" || die "cannot chmod log"
}

iso_to_epoch() {
	local ts="$1"
	local epoch
	if epoch=$(date -u -d "$ts" '+%s' 2>/dev/null); then
		printf '%s\n' "$epoch"
		return 0
	fi
	if epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null); then
		printf '%s\n' "$epoch"
		return 0
	fi
	return 1
}

write_run_status() {
	local exit_code="$1"
	local finished now_epoch duration_s result host tmp
	local reloaded_j recovered_j rolled_j drift_j lkg_j
	local last_success consec prev prev_last prev_fail extra level

	[ "${RECORD_STATUS:-0}" -eq 1 ] || return 0
	[ -n "${STATE_DIR:-}" ] || return 0
	[ -d "$STATE_DIR" ] || return 0

	finished=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || finished=""
	now_epoch=$(date +%s) || now_epoch=0
	duration_s=$((now_epoch - START_EPOCH))
	if [ "$duration_s" -lt 0 ]; then
		duration_s=0
	fi
	if [ "$exit_code" -eq 0 ]; then
		result=ok
	else
		result=failed
	fi
	host=$(hostname 2>/dev/null) || host=""

	reloaded_j=false
	[ "${RELOADED:-0}" -eq 1 ] && reloaded_j=true
	recovered_j=false
	[ "${RECOVERED:-0}" -eq 1 ] && recovered_j=true
	rolled_j=false
	[ "${ROLLED_BACK:-0}" -eq 1 ] && rolled_j=true

	drift_j=false
	if [ -n "${WORK:-}" ] && [ -s "$WORK/runtime-drift" ]; then
		drift_j=true
	fi

	lkg_j='[]'
	if [ -n "${WORK:-}" ] && [ -s "$WORK/dns-soft" ]; then
		lkg_j=$(jq -R -s 'split("\n") | map(select(length > 0))' "$WORK/dns-soft") || lkg_j='[]'
	fi

	prev="$STATE_DIR/status.json"
	prev_last=""
	prev_fail=0
	if [ -f "$prev" ]; then
		prev_last=$(jq -r '.last_success // empty' "$prev" 2>/dev/null) || prev_last=""
		prev_fail=$(jq -r '.consecutive_failures // 0' "$prev" 2>/dev/null) || prev_fail=0
		case "$prev_fail" in
			*[!0-9]*) prev_fail=0 ;;
		esac
	fi
	if [ "$result" = ok ]; then
		last_success=$finished
		consec=0
	else
		last_success=$prev_last
		consec=$((prev_fail + 1))
	fi

	tmp=$(mktemp "$STATE_DIR/.status.XXXXXX") || return 0
	if ! jq -n \
		--argjson schema 1 \
		--arg host "$host" \
		--arg mode "$MODE" \
		--arg started "$START_TS" \
		--arg finished "$finished" \
		--argjson duration_s "$duration_s" \
		--arg result "$result" \
		--argjson exit_code "$exit_code" \
		--arg error "${LAST_ERROR:-}" \
		--argjson changes "${CHANGES:-0}" \
		--argjson reloaded "$reloaded_j" \
		--argjson dns_lkg_hosts "$lkg_j" \
		--argjson runtime_drift "$drift_j" \
		--argjson recovered "$recovered_j" \
		--argjson rolled_back "$rolled_j" \
		--arg last_success "$last_success" \
		--argjson consecutive_failures "$consec" \
		'{
			schema: $schema,
			host: $host,
			mode: $mode,
			started: $started,
			finished: $finished,
			duration_s: $duration_s,
			result: $result,
			exit_code: $exit_code,
			error: $error,
			changes: $changes,
			reloaded: $reloaded,
			dns_lkg_hosts: $dns_lkg_hosts,
			runtime_drift: $runtime_drift,
			recovered: $recovered,
			rolled_back: $rolled_back,
			last_success: $last_success,
			consecutive_failures: $consecutive_failures
		}' > "$tmp"; then
		rm -f "$tmp"
		return 0
	fi
	chmod 0600 "$tmp" || { rm -f "$tmp"; return 0; }
	mv "$tmp" "$STATE_DIR/status.json" || { rm -f "$tmp"; return 0; }

	if [ "$result" = ok ]; then
		level=info
	else
		level=error
	fi
	extra=$(jq -nc \
		--arg result "$result" \
		--argjson exit_code "$exit_code" \
		--argjson changes "${CHANGES:-0}" \
		--argjson reloaded "$reloaded_j" \
		--argjson runtime_drift "$drift_j" \
		--argjson recovered "$recovered_j" \
		--argjson rolled_back "$rolled_j" \
		--argjson consecutive_failures "$consec" \
		'{result:$result, exit_code:$exit_code, changes:$changes, reloaded:$reloaded, runtime_drift:$runtime_drift, recovered:$recovered, rolled_back:$rolled_back, consecutive_failures:$consecutive_failures}') || extra='{}'
	log_event "$level" "run summary" "" "" "" "$extra" || true
	return 0
}

# --status exit 2 is CRITICAL. usage() also exits 2.
do_status() {
	local file="$STATE_DIR/status.json"
	local schema result last_success consec finished changes reloaded
	local now ls_epoch age_s age_min max_age_s
	local lkg_len recovered drift hosts err

	if [ "$(id -u)" -ne 0 ] && [ "${FWDYNHOSTS_ASSUME_ROOT:-}" != 1 ]; then
		die "must run as root"
	fi
	need_bin jq

	if [ ! -f "$file" ]; then
		printf '%s\n' "UNKNOWN - status.json missing"
		exit 3
	fi
	if [ ! -r "$file" ]; then
		printf '%s\n' "UNKNOWN - status.json unreadable"
		exit 3
	fi
	if ! jq -e . "$file" >/dev/null 2>&1; then
		printf '%s\n' "UNKNOWN - status.json invalid JSON"
		exit 3
	fi
	schema=$(jq -r '.schema // empty' "$file")
	if [ "$schema" != "1" ]; then
		printf '%s\n' "UNKNOWN - status.json schema is not 1"
		exit 3
	fi

	result=$(jq -r '.result // empty' "$file")
	last_success=$(jq -r '.last_success // empty' "$file")
	consec=$(jq -r '.consecutive_failures // 0' "$file")
	finished=$(jq -r '.finished // empty' "$file")
	changes=$(jq -r '.changes // 0' "$file")
	reloaded=$(jq -r '.reloaded' "$file")
	err=$(jq -r '.error // empty' "$file")

	now=$(date +%s)
	age_min=""
	age_s=0
	if [ -n "$last_success" ]; then
		if ls_epoch=$(iso_to_epoch "$last_success"); then
			age_s=$((now - ls_epoch))
			if [ "$age_s" -lt 0 ]; then
				age_s=0
			fi
			age_min=$((age_s / 60))
		fi
	fi

	if [ -f "$STATE_DIR/in-progress" ]; then
		if [ -n "$age_min" ]; then
			printf '%s\n' "CRITICAL - in-progress marker exists age_min=$age_min consecutive_failures=$consec"
		else
			printf '%s\n' "CRITICAL - in-progress marker exists consecutive_failures=$consec"
		fi
		exit 2
	fi

	if [ "$result" != "ok" ]; then
		if [ -n "$err" ] && [ -n "$age_min" ]; then
			printf '%s\n' "CRITICAL - last run failed: $err age_min=$age_min consecutive_failures=$consec"
		elif [ -n "$age_min" ]; then
			printf '%s\n' "CRITICAL - last run failed age_min=$age_min consecutive_failures=$consec"
		elif [ -n "$err" ]; then
			printf '%s\n' "CRITICAL - last run failed: $err consecutive_failures=$consec"
		else
			printf '%s\n' "CRITICAL - last run failed consecutive_failures=$consec"
		fi
		exit 2
	fi

	if [ -z "$last_success" ]; then
		printf '%s\n' "CRITICAL - last_success missing consecutive_failures=$consec"
		exit 2
	fi
	if [ -z "$age_min" ]; then
		printf '%s\n' "UNKNOWN - cannot parse last_success timestamp"
		exit 3
	fi
	max_age_s=$((MAX_AGE * 60))
	if [ "$age_s" -gt "$max_age_s" ]; then
		printf '%s\n' "CRITICAL - last success is $age_min minutes old consecutive_failures=$consec"
		exit 2
	fi

	lkg_len=$(jq '(.dns_lkg_hosts // []) | length' "$file")
	recovered=$(jq -r '.recovered // false' "$file")
	drift=$(jq -r '.runtime_drift // false' "$file")
	if [ "$lkg_len" -gt 0 ]; then
		hosts=$(jq -r '.dns_lkg_hosts | join(", ")' "$file")
		printf '%s\n' "WARNING - DNS last-known-good used for $hosts"
		exit 1
	fi
	if [ "$recovered" = "true" ]; then
		printf '%s\n' "WARNING - recovered interrupted run"
		exit 1
	fi
	if [ "$drift" = "true" ]; then
		printf '%s\n' "WARNING - runtime differed from permanent"
		exit 1
	fi

	printf '%s\n' "OK - last run $finished changes=$changes reloaded=$reloaded"
	exit 0
}

need_bin() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

file_mode() {
	local m
	m=$(stat -c '%a' "$1" 2>/dev/null) || m=$(stat -f '%OLp' "$1" 2>/dev/null) || return 1
	printf '%s\n' "$m"
}

split_ws_to() {
	local text="$1"
	local dest="$2"
	local tok
	printf '%s\n' "$text" | tr ' \t' '\n' > "$dest.raw"
	: > "$dest"
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		printf '%s\n' "$tok" >> "$dest"
	done < "$dest.raw"
}

note_drift() {
	printf '%s\n' "$*" >> "$WORK/drift"
}

note_runtime() {
	printf '%s\n' "$*" >> "$WORK/runtime-drift"
}

plan_add() {
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/plan"
}

# firewall-cmd is invoked directly so a TERM delivered to this process is trapped.
fw_mut() {
	local arg
	printf 'firewall-cmd'
	for arg in "$@"; do
		printf ' %s' "$arg"
	done
	printf '\n'
	firewall-cmd "$@" || die "firewall-cmd failed"
}

fw_capture() {
	FWQ=$(firewall-cmd "$@") || die "firewall-cmd failed"
}

zone_listed() {
	local zone="$1"
	local file="$2"
	grep -Fxq -- "$zone" "$file"
}

octet_ok() {
	case "$1" in
		0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) return 0 ;;
		*) return 1 ;;
	esac
}

v6_group_val() {
	local g="$1"
	case "$g" in
		""|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#g}" -le 4 ] || return 1
	printf '%s\n' "$((16#$g))"
}

expand_v6() {
	local ip="$1"
	local left="" right="" g rest val out="" right_out=""
	local compressed=0 nleft=0 nright=0 zeros=0 total=0 i=0
	case "$ip" in
		*:::*) return 1 ;;
		*[!0-9a-f:]*) return 1 ;;
		"") return 1 ;;
	esac
	case "$ip" in
		*:)
			case "$ip" in
				*::) ;;
				*) return 1 ;;
			esac
			;;
	esac
	case "$ip" in
		:*)
			case "$ip" in
				::*) ;;
				*) return 1 ;;
			esac
			;;
	esac
	local stripped
	stripped=${ip/::/X}
	case "$stripped" in
		*::*) return 1 ;;
	esac
	case "$ip" in
		::)
			printf '%s\n' "0 0 0 0 0 0 0 0"
			return 0
			;;
		*::*) compressed=1 ;;
	esac
	case "$ip" in
		::*)
			left=""
			right=${ip#::}
			;;
		*::)
			left=${ip%::}
			right=""
			;;
		*::*)
			left=${ip%%::*}
			right=${ip#*::}
			;;
		*)
			left=$ip
			right=""
			;;
	esac
	rest=$left
	while [ -n "$rest" ]; do
		case "$rest" in
			*:*) g=${rest%%:*}; rest=${rest#*:} ;;
			*) g=$rest; rest="" ;;
		esac
		val=$(v6_group_val "$g") || return 1
		out="$out $val"
		nleft=$((nleft + 1))
	done
	rest=$right
	while [ -n "$rest" ]; do
		case "$rest" in
			*:*) g=${rest%%:*}; rest=${rest#*:} ;;
			*) g=$rest; rest="" ;;
		esac
		val=$(v6_group_val "$g") || return 1
		right_out="$right_out $val"
		nright=$((nright + 1))
	done
	if [ "$compressed" -eq 0 ]; then
		[ "$nleft" -eq 8 ] || return 1
		[ "$nright" -eq 0 ] || return 1
		printf '%s\n' "${out# }"
		return 0
	fi
	total=$((nleft + nright))
	[ "$total" -le 7 ] || return 1
	zeros=$((8 - total))
	i=0
	while [ "$i" -lt "$zeros" ]; do
		out="$out 0"
		i=$((i + 1))
	done
	out="$out$right_out"
	out=${out# }
	set -- $out
	[ "$#" -eq 8 ] || return 1
	printf '%s\n' "$out"
}

parse_v4() {
	local raw="$1"
	local addr prefix a b c d rest
	case "$raw" in
		*/*)
			addr=${raw%%/*}
			prefix=${raw#*/}
			case "$prefix" in
				*/*) return 1 ;;
			esac
			;;
		*)
			addr=$raw
			prefix=""
			;;
	esac
	rest=$addr
	a=${rest%%.*}
	case "$rest" in
		*.*) rest=${rest#*.} ;;
		*) return 1 ;;
	esac
	b=${rest%%.*}
	case "$rest" in
		*.*) rest=${rest#*.} ;;
		*) return 1 ;;
	esac
	c=${rest%%.*}
	case "$rest" in
		*.*) rest=${rest#*.} ;;
		*) return 1 ;;
	esac
	d=$rest
	case "$d" in
		*.*) return 1 ;;
	esac
	octet_ok "$a" && octet_ok "$b" && octet_ok "$c" && octet_ok "$d" || return 1
	if [ -n "$prefix" ]; then
		case "$prefix" in
			0|[1-9]|[1-9][0-9]) ;;
			*) return 1 ;;
		esac
		[ "$prefix" -le 32 ] || return 1
		if [ "$prefix" -eq 32 ]; then
			printf '%s\n' "$a.$b.$c.$d"
		else
			printf '%s\n' "$a.$b.$c.$d/$prefix"
		fi
	else
		printf '%s\n' "$a.$b.$c.$d"
	fi
}

parse_v6() {
	local lower addr prefix
	lower=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	case "$lower" in
		*/*)
			addr=${lower%%/*}
			prefix=${lower#*/}
			case "$prefix" in
				*/*) return 1 ;;
			esac
			;;
		*)
			addr=$lower
			prefix=""
			;;
	esac
	expand_v6 "$addr" >/dev/null || return 1
	if [ -n "$prefix" ]; then
		case "$prefix" in
			0|[1-9]|[1-9][0-9]|1[0-2][0-9]) ;;
			*) return 1 ;;
		esac
		[ "$prefix" -le 128 ] || return 1
		if [ "$prefix" -eq 128 ]; then
			printf '%s\n' "$addr"
		else
			printf '%s\n' "$addr/$prefix"
		fi
	else
		printf '%s\n' "$addr"
	fi
}

parse_source() {
	local lower
	lower=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	case "$lower" in
		*:*) parse_v6 "$lower" ;;
		*) parse_v4 "$lower" ;;
	esac
}

ip_flags() {
	local norm="$1"
	local addr prefix flags="" a b rest exp g1
	case "$norm" in
		*/*) addr=${norm%%/*}; prefix=${norm#*/} ;;
		*) addr=$norm; prefix="" ;;
	esac
	case "$norm" in
		*:*)
			exp=$(expand_v6 "$addr") || return 1
			g1=${exp%% *}
			if [ $((g1 & 65472)) -eq 65152 ]; then
				flags="$flags linklocal"
			fi
			if [ $((g1 & 65280)) -eq 65280 ]; then
				flags="$flags multicast"
			fi
			if [ "$exp" = "0 0 0 0 0 0 0 1" ]; then
				flags="$flags loopback"
			fi
			if [ "$exp" = "0 0 0 0 0 0 0 0" ] && [ -z "$prefix" ]; then
				flags="$flags unspecified"
			fi
			if [ "$exp" = "0 0 0 0 0 0 0 0" ] && [ "$prefix" = "0" ]; then
				flags="$flags defaultroute"
			fi
			;;
		*)
			a=${addr%%.*}
			rest=${addr#*.}
			b=${rest%%.*}
			if [ "$a" -eq 127 ]; then
				flags="$flags loopback"
			fi
			if [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; then
				flags="$flags linklocal"
			fi
			if [ "$a" -ge 224 ] && [ "$a" -le 239 ]; then
				flags="$flags multicast"
			fi
			if [ "$addr" = "0.0.0.0" ] && [ -z "$prefix" ]; then
				flags="$flags unspecified"
			fi
			if [ "$addr" = "0.0.0.0" ] && [ "$prefix" = "0" ]; then
				flags="$flags defaultroute"
			fi
			;;
	esac
	printf '%s\n' "${flags# }"
}

has_flag() {
	local name="$1"
	local flags="$2"
	case " $flags " in
		*" $name "*) return 0 ;;
		*) return 1 ;;
	esac
}

check_static() {
	local raw="$1"
	local norm flags
	norm=$(parse_source "$raw") || die "invalid source: $raw"
	flags=$(ip_flags "$norm") || die "invalid source: $raw"
	if has_flag defaultroute "$flags" || has_flag unspecified "$flags" || has_flag multicast "$flags"; then
		die "rejected source: $raw"
	fi
	if has_flag loopback "$flags"; then
		printf '%s\n' "fwdynhosts: warning: static loopback source $norm" >&2
		log_event warning "static loopback source" "" "$norm" "warn"
	fi
	printf '%s\n' "$norm"
}

check_dns_addr() {
	local raw="$1"
	local norm flags
	case "$raw" in
		*/*)
			case "$raw" in
				*/32|*/128) ;;
				*) return 1 ;;
			esac
			;;
	esac
	norm=$(parse_source "$raw") || return 1
	case "$norm" in
		*/*) return 1 ;;
	esac
	flags=$(ip_flags "$norm") || return 1
	if has_flag loopback "$flags" || has_flag linklocal "$flags" || has_flag multicast "$flags" || has_flag unspecified "$flags" || has_flag defaultroute "$flags"; then
		return 1
	fi
	printf '%s\n' "$norm"
}

ipv4_int() {
	local ip="$1"
	local a b c d rest
	case "$ip" in
		*/*|*:*|"") return 1 ;;
	esac
	parse_v4 "$ip" >/dev/null || return 1
	a=${ip%%.*}
	rest=${ip#*.}
	b=${rest%%.*}
	rest=${rest#*.}
	c=${rest%%.*}
	d=${rest#*.}
	printf '%s\n' $((a * 16777216 + b * 65536 + c * 256 + d))
}

ipv4_contains() {
	local src="$1"
	local client="$2"
	local net prefix si ci shift mask
	case "$src" in
		*:*) return 1 ;;
	esac
	case "$src" in
		*/*) net=${src%%/*}; prefix=${src#*/} ;;
		*) net=$src; prefix=32 ;;
	esac
	si=$(ipv4_int "$net") || return 1
	ci=$(ipv4_int "$client") || return 1
	shift=$((32 - prefix))
	mask=$(( (4294967295 << shift) & 4294967295 ))
	[ $((si & mask)) -eq $((ci & mask)) ]
}

# IPv6 CIDR containment is not computed. Anything short of an exact address is not covered.
ipv6_exact() {
	local s c ea eb
	s=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	c=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
	case "$s" in
		*/*) return 1 ;;
	esac
	case "$c" in
		*/*) return 1 ;;
	esac
	ea=$(expand_v6 "$s") || return 1
	eb=$(expand_v6 "$c") || return 1
	[ "$ea" = "$eb" ]
}

hostname_ok() {
	local h="$1"
	local body label rest
	[ "${#h}" -ge 1 ] && [ "${#h}" -le 253 ] || return 1
	case "$h" in
		.*|*..) return 1 ;;
	esac
	body=$h
	case "$body" in
		.) return 1 ;;
		*.) body=${body%.} ;;
	esac
	[ -n "$body" ] || return 1
	case "$body" in
		*[!A-Za-z0-9.-]*) return 1 ;;
	esac
	rest=$body
	while [ -n "$rest" ]; do
		case "$rest" in
			.*) return 1 ;;
			*.*) label=${rest%%.*}; rest=${rest#*.} ;;
			*) label=$rest; rest="" ;;
		esac
		[ -n "$label" ] || return 1
		[ "${#label}" -le 63 ] || return 1
		case "$label" in
			-*|*-) return 1 ;;
			*[!A-Za-z0-9-]*) return 1 ;;
		esac
	done
	return 0
}

port_ok() {
	local p="$1"
	local num
	case "$p" in
		*/tcp) num=${p%/tcp} ;;
		*/udp) num=${p%/udp} ;;
		*) return 1 ;;
	esac
	case "$num" in
		*[!0-9]*|"") return 1 ;;
		0*) return 1 ;;
	esac
	[ "$num" -ge 1 ] && [ "$num" -le 65535 ]
}

service_name_ok() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

zone_name_ok() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]]
}

validate_structure() {
	if ! jq '
		def allowed: ["zone","ips","hostnames","services","ports","target"];
		if type != "array" then
			error("config must be a JSON array")
		else . end
		| .[]
		| if type != "object" then
			error("config element is not an object")
		else . end
		| . as $o
		| ($o | keys - allowed) as $bad
		| if ($bad | length) != 0 then
			error("unknown key " + $bad[0])
		else . end
		| if (($o | has("zone")) and ($o | has("ips")) and ($o | has("hostnames"))) then
			.
		else
			error("missing required key")
		end
		| if ($o.zone | type) != "string" then error("zone is not a string") else . end
		| if ($o.ips | type) != "array" then error("ips is not an array") else . end
		| if ($o.hostnames | type) != "array" then error("hostnames is not an array") else . end
		| if ($o | has("services")) and (($o.services | type) != "array") then
			error("services is not an array")
		else . end
		| if ($o | has("ports")) and (($o.ports | type) != "array") then
			error("ports is not an array")
		else . end
		| if ($o | has("target")) and (($o.target | type) != "string") then
			error("target is not a string")
		else . end
		| if ($o.ips | map(type == "string") | all) then . else error("ip is not a string") end
		| if ($o.hostnames | map(type == "string") | all) then . else error("hostname is not a string") end
		| if (($o | has("services")) | not) or ($o.services | map(type == "string") | all) then
			.
		else
			error("service is not a string")
		end
		| if (($o | has("ports")) | not) or ($o.ports | map(type == "string") | all) then
			.
		else
			error("port is not a string")
		end
	' "$CONFIG" >/dev/null 2>"$WORK/jq.err"; then
		die "invalid config: $(cat "$WORK/jq.err")"
	fi
	local dups
	dups=$(jq -r '.[].zone' "$CONFIG" | sort | uniq -d || true)
	if [ -n "$dups" ]; then
		die "duplicate zone name: $(printf '%s' "$dups" | tr '\n' ' ')"
	fi
}

read_perm_zones() {
	fw_capture --permanent --get-zones
	split_ws_to "$FWQ" "$WORK/perm-zones"
}

read_run_zones() {
	fw_capture --get-zones
	split_ws_to "$FWQ" "$WORK/run-zones"
}

read_list_prop() {
	local which="$1"
	local zone="$2"
	local prop="$3"
	local dest="$4"
	if [ "$which" = permanent ]; then
		fw_capture --permanent --zone="$zone" --list-"$prop"
	else
		fw_capture --zone="$zone" --list-"$prop"
	fi
	split_ws_to "$FWQ" "$dest"
	sort -u "$dest" -o "$dest"
}

read_target_prop() {
	local which="$1"
	local zone="$2"
	local dest="$3"
	if [ "$which" = permanent ]; then
		fw_capture --permanent --zone="$zone" --get-target
	else
		fw_capture --zone="$zone" --get-target
	fi
	printf '%s\n' "$FWQ" | tr -d '[:space:]' > "$dest"
}

load_known_services() {
	fw_capture --get-services
	split_ws_to "$FWQ" "$WORK/known-services"
}

ensure_zone_dir() {
	mkdir -p "$WORK/z/$1"
}

load_config_fields() {
	local zone item has_services has_ports has_target target svc port ip host norm
	: > "$WORK/zones"
	: > "$WORK/hostnames"
	: > "$WORK/all-sources"
	: > "$WORK/needs-services"
	jq -r '.[].zone' "$CONFIG" > "$WORK/zones"
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		zone_name_ok "$zone" || die "invalid zone name: $zone"
		ensure_zone_dir "$zone"
		item=$(jq -c --arg z "$zone" '.[] | select(.zone == $z)' "$CONFIG")
		has_services=$(printf '%s' "$item" | jq -r 'if has("services") then "1" else "0" end')
		has_ports=$(printf '%s' "$item" | jq -r 'if has("ports") then "1" else "0" end')
		has_target=$(printf '%s' "$item" | jq -r 'if has("target") then "1" else "0" end')
		printf '%s\n' "$has_services" > "$WORK/z/$zone/manage_services"
		printf '%s\n' "$has_ports" > "$WORK/z/$zone/manage_ports"
		printf '%s\n' "$has_target" > "$WORK/z/$zone/manage_target"
		: > "$WORK/z/$zone/services"
		: > "$WORK/z/$zone/ports"
		: > "$WORK/z/$zone/sources"
		: > "$WORK/z/$zone/hostnames"
		if [ "$has_target" -eq 1 ]; then
			target=$(printf '%s' "$item" | jq -r '.target')
			case "$target" in
				ACCEPT) die "target ACCEPT is rejected for zone $zone" ;;
				default|DROP|REJECT) ;;
				*) die "invalid target for zone $zone: $target" ;;
			esac
			printf '%s\n' "$target" > "$WORK/z/$zone/target"
		fi
		if [ "$has_services" -eq 1 ]; then
			printf '1\n' >> "$WORK/needs-services"
			while IFS= read -r svc; do
				[ -n "$svc" ] || continue
				service_name_ok "$svc" || die "invalid service for zone $zone: $svc"
				if [ "$zone" = "$PUBLIC_ZONE" ] || [ "$zone" = "$CF_ZONE" ]; then
					if [ "$svc" = "ssh" ]; then
						die "service ssh is rejected for zone $zone"
					fi
				fi
				printf '%s\n' "$svc" >> "$WORK/z/$zone/services"
			done < <(printf '%s' "$item" | jq -r '.services[]?')
			sort -u "$WORK/z/$zone/services" -o "$WORK/z/$zone/services"
		fi
		if [ "$has_ports" -eq 1 ]; then
			while IFS= read -r port; do
				[ -n "$port" ] || continue
				port_ok "$port" || die "invalid port for zone $zone: $port"
				if [ "$zone" = "$PUBLIC_ZONE" ] || [ "$zone" = "$CF_ZONE" ]; then
					if [ "$port" = "22/tcp" ] || [ "$port" = "22/udp" ]; then
						die "port $port is rejected for zone $zone"
					fi
				fi
				printf '%s\n' "$port" >> "$WORK/z/$zone/ports"
			done < <(printf '%s' "$item" | jq -r '.ports[]?')
			sort -u "$WORK/z/$zone/ports" -o "$WORK/z/$zone/ports"
		fi
		while IFS= read -r ip; do
			[ -n "$ip" ] || continue
			norm=$(check_static "$ip")
			printf '%s\n' "$norm" >> "$WORK/z/$zone/sources"
			printf '%s\t%s\n' "$zone" "$norm" >> "$WORK/all-sources"
		done < <(printf '%s' "$item" | jq -r '.ips[]')
		while IFS= read -r host; do
			[ -n "$host" ] || continue
			hostname_ok "$host" || die "invalid hostname for zone $zone: $host"
			printf '%s\n' "$host" >> "$WORK/z/$zone/hostnames"
			printf '%s\n' "$host" >> "$WORK/hostnames"
		done < <(printf '%s' "$item" | jq -r '.hostnames[]')
		sort -u "$WORK/z/$zone/hostnames" -o "$WORK/z/$zone/hostnames"
	done < "$WORK/zones"
	sort -u "$WORK/hostnames" -o "$WORK/hostnames"
	if [ -s "$WORK/needs-services" ]; then
		load_known_services
		while IFS= read -r zone; do
			[ -n "$zone" ] || continue
			[ "$(cat "$WORK/z/$zone/manage_services")" -eq 1 ] || continue
			while IFS= read -r svc; do
				[ -n "$svc" ] || continue
				if ! grep -Fxq -- "$svc" "$WORK/known-services"; then
					die "service $svc is not defined for zone $zone"
				fi
			done < "$WORK/z/$zone/services"
		done < "$WORK/zones"
	fi
}

write_dns_file() {
	local src="$1"
	local tmp
	tmp=$(mktemp "$STATE_DIR/.dns-state.XXXXXX") || die "cannot create dns state"
	cp "$src" "$tmp" || die "cannot write dns state"
	chmod 0600 "$tmp" || die "cannot chmod dns state"
	mv "$tmp" "$DNS_STATE" || die "cannot replace dns state"
}

dns_put() {
	local host="$1"
	local file="$2"
	local base="$3"
	local arr
	arr=$(jq -R . < "$file" | jq -s .) || die "cannot encode addresses for $host"
	jq --arg h "$host" --argjson a "$arr" '.[$h] = $a' "$base" > "$WORK/dns-state.new" || die "cannot update dns state"
	mv "$WORK/dns-state.new" "$base"
}

lkg_copy() {
	local host="$1"
	local addr norm
	: > "$WORK/dns/$host"
	while IFS= read -r addr; do
		[ -n "$addr" ] || continue
		norm=$(check_dns_addr "$addr") || return 1
		printf '%s\n' "$norm" >> "$WORK/dns/$host"
	done < <(jq -r --arg h "$host" '.[$h][]?' "$DNS_STATE")
	[ -s "$WORK/dns/$host" ] || return 1
	sort -u "$WORK/dns/$host" -o "$WORK/dns/$host"
}

resolve_one() {
	local host="$1"
	local rc=0 out line addr norm
	out=$(host -W 5 "$host" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		return 1
	fi
	: > "$WORK/dns-one"
	: > "$WORK/dns-bad"
	printf '%s\n' "$out" | while IFS= read -r line; do
		case "$line" in
			*"has IPv6 address "*) addr=${line##* } ;;
			*"has address "*) addr=${line##* } ;;
			*) continue ;;
		esac
		if norm=$(check_dns_addr "$addr"); then
			printf '%s\n' "$norm" >> "$WORK/dns-one"
		else
			printf 'bad\n' >> "$WORK/dns-bad"
		fi
	done
	if [ -s "$WORK/dns-bad" ]; then
		return 1
	fi
	if [ ! -s "$WORK/dns-one" ]; then
		return 1
	fi
	sort -u "$WORK/dns-one" -o "$WORK/dns/$host"
	return 0
}

resolve_all() {
	local host
	mkdir -p "$WORK/dns"
	: > "$WORK/dns-ok"
	: > "$WORK/dns-hard"
	: > "$WORK/dns-soft"
	if [ ! -s "$WORK/hostnames" ]; then
		printf '%s\n' '{}' > "$WORK/dns-empty"
		write_dns_file "$WORK/dns-empty"
		return 0
	fi
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		if resolve_one "$host"; then
			printf '%s\n' "$host" >> "$WORK/dns-ok"
		else
			if [ -f "$DNS_STATE" ] && jq -e --arg h "$host" 'has($h) and (.[$h] | type == "array") and (.[$h] | length > 0)' "$DNS_STATE" >/dev/null 2>&1 && lkg_copy "$host"; then
				printf '%s\n' "$host" >> "$WORK/dns-soft"
				printf '%s\n' "fwdynhosts: warning: DNS failed for $host; using last-known-good" >&2
				log_event warning "DNS failed for $host; using last-known-good"
			else
				printf '%s\n' "$host" >> "$WORK/dns-hard"
				printf '%s\n' "fwdynhosts: DNS failed for $host and no last-known-good exists" >&2
				log_event error "DNS failed for $host and no last-known-good exists"
			fi
		fi
	done < "$WORK/hostnames"
	if [ -s "$WORK/dns-hard" ]; then
		if [ -s "$WORK/dns-ok" ]; then
			if [ -f "$DNS_STATE" ]; then
				cp "$DNS_STATE" "$WORK/dns-partial.json"
			else
				printf '%s\n' '{}' > "$WORK/dns-partial.json"
			fi
			while IFS= read -r host; do
				[ -n "$host" ] || continue
				dns_put "$host" "$WORK/dns/$host" "$WORK/dns-partial.json"
			done < "$WORK/dns-ok"
			write_dns_file "$WORK/dns-partial.json"
		fi
		die "DNS failed and no last-known-good exists"
	fi
	if [ -s "$WORK/dns-soft" ]; then
		if [ -f "$DNS_STATE" ]; then
			cp "$DNS_STATE" "$WORK/dns-partial.json"
		else
			printf '%s\n' '{}' > "$WORK/dns-partial.json"
		fi
		while IFS= read -r host; do
			[ -n "$host" ] || continue
			dns_put "$host" "$WORK/dns/$host" "$WORK/dns-partial.json"
		done < "$WORK/dns-ok"
		write_dns_file "$WORK/dns-partial.json"
	else
		printf '%s\n' '{}' > "$WORK/dns-full.json"
		while IFS= read -r host; do
			[ -n "$host" ] || continue
			dns_put "$host" "$WORK/dns/$host" "$WORK/dns-full.json"
		done < "$WORK/hostnames"
		write_dns_file "$WORK/dns-full.json"
	fi
	local zone
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		while IFS= read -r host; do
			[ -n "$host" ] || continue
			if [ -f "$WORK/dns/$host" ]; then
				cat "$WORK/dns/$host" >> "$WORK/z/$zone/sources"
			fi
		done < "$WORK/z/$zone/hostnames"
		sort -u "$WORK/z/$zone/sources" -o "$WORK/z/$zone/sources"
	done < "$WORK/zones"
	: > "$WORK/all-sources"
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		while IFS= read -r norm; do
			[ -n "$norm" ] || continue
			printf '%s\t%s\n' "$zone" "$norm" >> "$WORK/all-sources"
		done < "$WORK/z/$zone/sources"
	done < "$WORK/zones"
}

reject_duplicate_sources() {
	local prev="" prevz="" z s
	: > "$WORK/dups"
	sort -t '	' -k2,2 -k1,1 "$WORK/all-sources" > "$WORK/all-sources.sorted"
	while IFS="$(printf '\t')" read -r z s; do
		[ -n "$s" ] || continue
		if [ "$s" = "$prev" ] && [ "$z" != "$prevz" ]; then
			printf '%s\n' "$s" >> "$WORK/dups"
		fi
		prev=$s
		prevz=$z
	done < "$WORK/all-sources.sorted"
	if [ -s "$WORK/dups" ]; then
		die "source appears in more than one zone: $(head -n 1 "$WORK/dups")"
	fi
}

validate_feed_file() {
	local family="$1"
	local file="$2"
	local min="$3"
	local max="$4"
	local line norm flags count=0
	: > "$WORK/feed-$family"
	tr -d '\r' < "$file" > "$WORK/feed-$family.raw"
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -n "$line" ] || die "cloudflare $family feed contains an empty line"
		case "$line" in
			*[[:space:]]*) die "cloudflare $family feed rejected line: $line" ;;
		esac
		case "$line" in
			*/*) ;;
			*) die "cloudflare $family feed rejected line: $line" ;;
		esac
		if [ "$family" = v4 ]; then
			case "$line" in
				*:*) die "cloudflare v4 feed rejected line: $line" ;;
			esac
			norm=$(parse_v4 "$line") || die "cloudflare v4 feed rejected line: $line"
		else
			norm=$(parse_v6 "$line") || die "cloudflare v6 feed rejected line: $line"
			case "$norm" in
				*:*) ;;
				*) die "cloudflare v6 feed rejected line: $line" ;;
			esac
		fi
		flags=$(ip_flags "$norm") || die "cloudflare $family feed rejected line: $line"
		if has_flag loopback "$flags" || has_flag linklocal "$flags" || has_flag multicast "$flags" || has_flag unspecified "$flags" || has_flag defaultroute "$flags"; then
			die "cloudflare $family feed contains forbidden network $norm"
		fi
		printf '%s\n' "$norm" >> "$WORK/feed-$family"
		count=$((count + 1))
	done < "$WORK/feed-$family.raw"
	if [ "$count" -eq 0 ]; then
		die "cloudflare $family feed is empty"
	fi
	local dups
	dups=$(sort "$WORK/feed-$family" | uniq -d || true)
	if [ -n "$dups" ]; then
		die "cloudflare $family feed contains duplicates"
	fi
	if [ "$count" -lt "$min" ] || [ "$count" -gt "$max" ]; then
		die "cloudflare $family feed count $count is outside $min..$max"
	fi
}

do_refresh() {
	local count old norm
	validate_structure
	count=$(jq --arg z "$CF_ZONE" '[.[] | select(.zone == $z)] | length' "$CONFIG")
	if [ "$count" -eq 0 ]; then
		die "config has no zone named $CF_ZONE"
	fi
	if [ "$count" -ne 1 ]; then
		die "config has more than one zone named $CF_ZONE"
	fi
	need_bin curl
	if ! curl -fsS --max-time 20 --proto '=https' --tlsv1.2 --retry 0 --max-redirs 0 "$CF_V4_URL" > "$WORK/cf-v4-body"; then
		die "cloudflare download failed: $CF_V4_URL"
	fi
	if ! curl -fsS --max-time 20 --proto '=https' --tlsv1.2 --retry 0 --max-redirs 0 "$CF_V6_URL" > "$WORK/cf-v6-body"; then
		die "cloudflare download failed: $CF_V6_URL"
	fi
	validate_feed_file v4 "$WORK/cf-v4-body" 10 64
	validate_feed_file v6 "$WORK/cf-v6-body" 4 32
	cat "$WORK/feed-v4" "$WORK/feed-v6" > "$WORK/cf-ordered"
	sort -u "$WORK/cf-ordered" > "$WORK/cf-new"
	: > "$WORK/cf-old"
	while IFS= read -r old; do
		[ -n "$old" ] || continue
		norm=$(parse_source "$old") || norm=$old
		printf '%s\n' "$norm" >> "$WORK/cf-old"
	done < <(jq -r --arg z "$CF_ZONE" '.[] | select(.zone == $z) | .ips[]?' "$CONFIG")
	sort -u "$WORK/cf-old" -o "$WORK/cf-old"
	: > "$WORK/cf-added"
	: > "$WORK/cf-removed"
	comm -13 "$WORK/cf-old" "$WORK/cf-new" > "$WORK/cf-added"
	comm -23 "$WORK/cf-old" "$WORK/cf-new" > "$WORK/cf-removed"
	local cidr
	while IFS= read -r cidr; do
		[ -n "$cidr" ] || continue
		say "cloudflare ip removed $cidr"
	done < "$WORK/cf-removed"
	while IFS= read -r cidr; do
		[ -n "$cidr" ] || continue
		say "cloudflare ip added $cidr"
	done < "$WORK/cf-added"
	if cmp -s "$WORK/cf-old" "$WORK/cf-new"; then
		say "Cloudflare ips unchanged"
		return 0
	fi
	if [ "$MODE" != apply ]; then
		say "Not writing config"
		return 0
	fi
	write_cloudflare_ips
}

write_cloudflare_ips() {
	local mode dir tmp backup
	mode=$(file_mode "$CONFIG") || die "cannot read config mode"
	CONFIG_MODE=$mode
	dir=$(dirname "$CONFIG")
	backup="$STATE_DIR/backups/config-$(date -u '+%Y%m%dT%H%M%SZ')-$$.json"
	mkdir -p "$STATE_DIR/backups"
	cp "$CONFIG" "$backup" || die "cannot backup config"
	chmod 0600 "$backup" || die "cannot chmod config backup"
	CONFIG_BACKUP=$backup
	tmp=$(mktemp "$dir/.dynhosts.XXXXXX") || die "cannot create config temp file"
	jq -R -s 'split("\n") | map(select(length > 0))' "$WORK/cf-ordered" > "$WORK/cf-ips.json" || {
		rm -f "$tmp"
		die "cannot encode cloudflare ips"
	}
	if ! jq --arg z "$CF_ZONE" --slurpfile ips "$WORK/cf-ips.json" \
		'map(if .zone == $z then .ips = $ips[0] else . end)' \
		"$CONFIG" > "$tmp"; then
		rm -f "$tmp"
		die "cannot rewrite config"
	fi
	chmod "$mode" "$tmp" || { rm -f "$tmp"; die "cannot chmod config temp file"; }
	mv "$tmp" "$CONFIG" || die "cannot replace config"
	CONFIG_CHANGED=1
	log_event info "updated cloudflare ips" "$CF_ZONE" "" "refresh"
	say "Wrote cloudflare ips"
}

take_backup_from() {
	local list="$1"
	local ts dir zone
	ts=$(date -u '+%Y%m%dT%H%M%SZ')-$$
	dir="$STATE_DIR/backups/$ts"
	mkdir -p "$dir/xml" || die "cannot create backup dir"
	chmod 0700 "$dir" "$dir/xml" || die "cannot chmod backup dir"
	: > "$dir/manifest"
	read_perm_zones
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		if [ -f "$ZONES_DIR/$zone.xml" ]; then
			cp "$ZONES_DIR/$zone.xml" "$dir/xml/$zone.xml" || die "cannot copy zone xml for $zone"
			printf '%s file\n' "$zone" >> "$dir/manifest"
		elif zone_listed "$zone" "$WORK/perm-zones"; then
			printf '%s builtin\n' "$zone" >> "$dir/manifest"
		else
			printf '%s absent\n' "$zone" >> "$dir/manifest"
		fi
	done < "$list"
	printf '%s\n' "$dir" > "$STATE_DIR/in-progress"
	chmod 0600 "$STATE_DIR/in-progress" || die "cannot chmod in-progress"
	BACKUP_DIR=$dir
}

restore_backup() {
	local dir="$1"
	local zone status
	[ -f "$dir/manifest" ] || return 1
	while IFS=' ' read -r zone status; do
		[ -n "${zone:-}" ] || continue
		case "$status" in
			file)
				cp "$dir/xml/$zone.xml" "$ZONES_DIR/$zone.xml" || return 1
				;;
			builtin)
				rm -f "$ZONES_DIR/$zone.xml"
				;;
			absent)
				if [ -f "$ZONES_DIR/$zone.xml" ]; then
					printf 'firewall-cmd --permanent --delete-zone=%s\n' "$zone"
					firewall-cmd --permanent --delete-zone="$zone" || true
					rm -f "$ZONES_DIR/$zone.xml"
				fi
				;;
			*)
				return 1
				;;
		esac
	done < "$dir/manifest"
	printf 'firewall-cmd --reload\n'
	firewall-cmd --reload || return 1
	return 0
}

restore_config_if_needed() {
	if [ "$CONFIG_CHANGED" -eq 1 ] && [ "$COMMITTED" -ne 1 ] && [ -n "$CONFIG_BACKUP" ] && [ -f "$CONFIG_BACKUP" ]; then
		cp "$CONFIG_BACKUP" "$CONFIG" || true
		if [ -n "$CONFIG_MODE" ]; then
			chmod "$CONFIG_MODE" "$CONFIG" || true
		fi
	fi
}

cleanup() {
	rc=$?
	trap - EXIT INT TERM
	set +e
	if [ "$CONFIG_CHANGED" -eq 1 ] && [ "$COMMITTED" -ne 1 ]; then
		restore_config_if_needed
	fi
	if [ "$MUTATION_STARTED" -eq 1 ] && [ "$COMMITTED" -ne 1 ]; then
		if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
			if restore_backup "$BACKUP_DIR"; then
				rm -f "$STATE_DIR/in-progress"
				ROLLED_BACK=1
			fi
		fi
		if [ "$rc" -eq 0 ]; then
			rc=1
		fi
	fi
	write_run_status "$rc" || true
	case "$WORK" in
		*/fwdynhosts.*) rm -rf "$WORK" ;;
	esac
	exit "$rc"
}

recover_in_progress() {
	local dir
	[ -f "$STATE_DIR/in-progress" ] || return 0
	IFS= read -r dir < "$STATE_DIR/in-progress" || true
	[ -n "$dir" ] || die "in-progress marker is empty"
	[ -d "$dir" ] || die "in-progress backup missing: $dir"
	say "Recovering interrupted run"
	log_event warning "recovering interrupted run" "" "" "recover"
	restore_backup "$dir" || die "recovery failed"
	rm -f "$STATE_DIR/in-progress"
	RECOVERED=1
	log_event info "recovered interrupted run" "" "" "recover"
	say "Recovery complete"
}

do_rollback() {
	local dir=""
	if [ -f "$STATE_DIR/in-progress" ]; then
		IFS= read -r dir < "$STATE_DIR/in-progress" || true
	elif [ -f "$STATE_DIR/latest-backup" ]; then
		IFS= read -r dir < "$STATE_DIR/latest-backup" || true
	else
		die "no backup to roll back"
	fi
	[ -n "$dir" ] || die "backup path is empty"
	[ -d "$dir" ] || die "backup not found: $dir"
	say "Rolling back $dir"
	log_event info "rollback starting" "" "" "rollback"
	printf '%s\n' "$dir" > "$STATE_DIR/in-progress"
	chmod 0600 "$STATE_DIR/in-progress"
	BACKUP_DIR=$dir
	MUTATION_STARTED=1
	restore_backup "$dir" || die "rollback failed"
	rm -f "$STATE_DIR/in-progress"
	COMMITTED=1
	log_event info "rollback complete" "" "" "rollback"
	say "Rollback complete"
}

commit_success() {
	local update_latest="$1"
	if [ "$update_latest" -eq 1 ] && [ -n "$BACKUP_DIR" ]; then
		printf '%s\n' "$BACKUP_DIR" > "$STATE_DIR/latest-backup"
		chmod 0600 "$STATE_DIR/latest-backup"
	fi
	rm -f "$STATE_DIR/in-progress"
	COMMITTED=1
}

files_differ() {
	if [ -f "$1" ] && [ -f "$2" ]; then
		if cmp -s "$1" "$2"; then
			return 1
		fi
		return 0
	fi
	if [ ! -f "$1" ] && [ ! -f "$2" ]; then
		return 1
	fi
	return 0
}

plan_name_diff() {
	local zone="$1"
	local kind="$2"
	local cur="$3"
	local des="$4"
	local addop="add-$kind"
	local rmop="remove-$kind"
	local item
	sort -u "$cur" > "$WORK/cmp-cur"
	sort -u "$des" > "$WORK/cmp-des"
	comm -23 "$WORK/cmp-cur" "$WORK/cmp-des" > "$WORK/cmp-rm"
	comm -13 "$WORK/cmp-cur" "$WORK/cmp-des" > "$WORK/cmp-add"
	while IFS= read -r item; do
		[ -n "$item" ] || continue
		plan_add "$rmop" "$zone" "$item"
		note_drift "drift zone $zone $kind remove $item"
	done < "$WORK/cmp-rm"
	while IFS= read -r item; do
		[ -n "$item" ] || continue
		plan_add "$addop" "$zone" "$item"
		note_drift "drift zone $zone $kind add $item"
	done < "$WORK/cmp-add"
}

plan_sources() {
	local zone="$1"
	local exists="$2"
	local des="$WORK/z/$zone/sources"
	local raw="$WORK/z/$zone/perm_sources"
	local map="$WORK/z/$zone/srcmap"
	local n rawtok keep
	: > "$map"
	if [ "$exists" -eq 1 ] && [ -f "$raw" ]; then
		while IFS= read -r rawtok; do
			[ -n "$rawtok" ] || continue
			n=$(parse_source "$rawtok") || n=$rawtok
			printf '%s\t%s\n' "$n" "$rawtok" >> "$map"
		done < "$raw"
	fi
	if [ -s "$map" ]; then
		cut -f 1 "$map" | sort -u > "$WORK/z/$zone/cur-norms"
	else
		: > "$WORK/z/$zone/cur-norms"
	fi
	sort -u "$des" > "$WORK/z/$zone/des-norms"
	comm -23 "$WORK/z/$zone/cur-norms" "$WORK/z/$zone/des-norms" > "$WORK/z/$zone/rm-norms"
	comm -13 "$WORK/z/$zone/cur-norms" "$WORK/z/$zone/des-norms" > "$WORK/z/$zone/add-norms"
	comm -12 "$WORK/z/$zone/cur-norms" "$WORK/z/$zone/des-norms" > "$WORK/z/$zone/keep-norms"
	while IFS= read -r n; do
		[ -n "$n" ] || continue
		awk -F '\t' -v n="$n" '$1 == n { print $2 }' "$map" | while IFS= read -r rawtok; do
			[ -n "$rawtok" ] || continue
			plan_add remove-source "$zone" "$rawtok"
			note_drift "drift zone $zone source remove $rawtok"
		done
	done < "$WORK/z/$zone/rm-norms"
	while IFS= read -r n; do
		[ -n "$n" ] || continue
		awk -F '\t' -v n="$n" '$1 == n { print $2 }' "$map" > "$WORK/z/$zone/raws-one"
		keep=""
		if grep -Fxq -- "$n" "$WORK/z/$zone/raws-one"; then
			keep=$n
		else
			keep=$(head -n 1 "$WORK/z/$zone/raws-one")
		fi
		while IFS= read -r rawtok; do
			[ -n "$rawtok" ] || continue
			[ "$rawtok" = "$keep" ] && continue
			plan_add remove-source "$zone" "$rawtok"
			note_drift "drift zone $zone source remove $rawtok"
		done < "$WORK/z/$zone/raws-one"
	done < "$WORK/z/$zone/keep-norms"
	while IFS= read -r n; do
		[ -n "$n" ] || continue
		plan_add add-source "$zone" "$n"
		note_drift "drift zone $zone source add $n"
	done < "$WORK/z/$zone/add-norms"
}

compare_runtime() {
	local zone="$1"
	local exists_p="$2"
	local prop
	if [ "$exists_p" -eq 0 ]; then
		if zone_listed "$zone" "$WORK/run-zones"; then
			note_runtime "runtime differs from permanent for zone $zone presence"
		fi
		return 0
	fi
	if ! zone_listed "$zone" "$WORK/run-zones"; then
		note_runtime "runtime differs from permanent for zone $zone presence"
		return 0
	fi
	for prop in sources services ports interfaces; do
		read_list_prop runtime "$zone" "$prop" "$WORK/z/$zone/run_$prop"
		if files_differ "$WORK/z/$zone/perm_$prop" "$WORK/z/$zone/run_$prop"; then
			note_runtime "runtime differs from permanent for zone $zone $prop"
		fi
	done
	read_target_prop runtime "$zone" "$WORK/z/$zone/run_target"
	local pt rt
	pt=$(cat "$WORK/z/$zone/perm_target")
	rt=$(cat "$WORK/z/$zone/run_target")
	if [ "$pt" != "$rt" ]; then
		note_runtime "runtime differs from permanent for zone $zone target"
	fi
}

build_plan() {
	local zone exists target pt manage
	: > "$WORK/plan"
	: > "$WORK/drift"
	: > "$WORK/runtime-drift"
	read_perm_zones
	read_run_zones
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		exists=0
		if zone_listed "$zone" "$WORK/perm-zones"; then
			exists=1
		fi
		if [ "$exists" -eq 1 ]; then
			read_list_prop permanent "$zone" sources "$WORK/z/$zone/perm_sources"
			read_list_prop permanent "$zone" services "$WORK/z/$zone/perm_services"
			read_list_prop permanent "$zone" ports "$WORK/z/$zone/perm_ports"
			read_list_prop permanent "$zone" interfaces "$WORK/z/$zone/perm_interfaces"
			read_target_prop permanent "$zone" "$WORK/z/$zone/perm_target"
		else
			: > "$WORK/z/$zone/perm_sources"
			: > "$WORK/z/$zone/perm_services"
			: > "$WORK/z/$zone/perm_ports"
			: > "$WORK/z/$zone/perm_interfaces"
			printf '%s\n' "default" > "$WORK/z/$zone/perm_target"
		fi
		compare_runtime "$zone" "$exists"
		if [ "$exists" -eq 0 ]; then
			plan_add new-zone "$zone" "-"
			note_drift "drift zone $zone missing"
		fi
		manage=$(cat "$WORK/z/$zone/manage_target")
		if [ "$manage" -eq 1 ]; then
			target=$(cat "$WORK/z/$zone/target")
			pt=$(cat "$WORK/z/$zone/perm_target")
			if [ "$exists" -eq 0 ]; then
				if [ "$target" != "default" ]; then
					plan_add set-target "$zone" "$target"
					note_drift "drift zone $zone target permanent missing desired $target"
				fi
			elif [ "$pt" != "$target" ]; then
				plan_add set-target "$zone" "$target"
				note_drift "drift zone $zone target permanent $pt desired $target"
			fi
		fi
		manage=$(cat "$WORK/z/$zone/manage_services")
		if [ "$manage" -eq 1 ]; then
			plan_name_diff "$zone" service "$WORK/z/$zone/perm_services" "$WORK/z/$zone/services"
		fi
		manage=$(cat "$WORK/z/$zone/manage_ports")
		if [ "$manage" -eq 1 ]; then
			plan_name_diff "$zone" port "$WORK/z/$zone/perm_ports" "$WORK/z/$zone/ports"
		fi
		plan_sources "$zone" "$exists"
	done < "$WORK/zones"
}

check_source_conflicts() {
	local zone tok norm owner
	read_perm_zones
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		read_list_prop permanent "$zone" sources "$WORK/conflict-$zone"
		while IFS= read -r tok; do
			[ -n "$tok" ] || continue
			norm=$(parse_source "$tok") || norm=$tok
			owner=$(awk -F '\t' -v n="$norm" '$2 == n { print $1; exit }' "$WORK/all-sources")
			if [ -n "$owner" ] && [ "$owner" != "$zone" ]; then
				die "source $tok is already bound to zone $zone"
			fi
		done < "$WORK/conflict-$zone"
	done < "$WORK/perm-zones"
	read_run_zones
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		read_list_prop runtime "$zone" sources "$WORK/conflict-run-$zone"
		while IFS= read -r tok; do
			[ -n "$tok" ] || continue
			norm=$(parse_source "$tok") || norm=$tok
			owner=$(awk -F '\t' -v n="$norm" '$2 == n { print $1; exit }' "$WORK/all-sources")
			if [ -n "$owner" ] && [ "$owner" != "$zone" ]; then
				die "source $tok is already bound to zone $zone"
			fi
		done < "$WORK/conflict-run-$zone"
	done < "$WORK/run-zones"
}

check_cloudflare_guards() {
	local zone
	zone_listed "$CF_ZONE" "$WORK/zones" || return 0
	read_perm_zones
	if ! zone_listed "$PUBLIC_ZONE" "$WORK/perm-zones"; then
		die "zone $PUBLIC_ZONE does not exist"
	fi
	read_run_zones
	if ! zone_listed "$PUBLIC_ZONE" "$WORK/run-zones"; then
		die "zone $PUBLIC_ZONE does not exist"
	fi
	read_list_prop permanent "$PUBLIC_ZONE" interfaces "$WORK/public-ifaces-p"
	read_list_prop runtime "$PUBLIC_ZONE" interfaces "$WORK/public-ifaces-r"
	if ! grep -Fxq -- "$PUBLIC_IFACE" "$WORK/public-ifaces-p"; then
		die "zone $PUBLIC_ZONE interfaces do not include $PUBLIC_IFACE"
	fi
	if ! grep -Fxq -- "$PUBLIC_IFACE" "$WORK/public-ifaces-r"; then
		die "zone $PUBLIC_ZONE interfaces do not include $PUBLIC_IFACE"
	fi
	if zone_listed "$CF_ZONE" "$WORK/perm-zones"; then
		read_list_prop permanent "$CF_ZONE" interfaces "$WORK/cf-ifaces-p"
		if [ -s "$WORK/cf-ifaces-p" ]; then
			die "zone $CF_ZONE has an interface; not removing it"
		fi
	fi
	if zone_listed "$CF_ZONE" "$WORK/run-zones"; then
		read_list_prop runtime "$CF_ZONE" interfaces "$WORK/cf-ifaces-r"
		if [ -s "$WORK/cf-ifaces-r" ]; then
			die "zone $CF_ZONE has an interface; not removing it"
		fi
	fi
}

zone_allows_ssh_files() {
	local target_file="$1"
	local services_file="$2"
	local ports_file="$3"
	local target
	target=$(cat "$target_file")
	if [ "$target" = "ACCEPT" ]; then
		return 0
	fi
	if grep -Fxq -- ssh "$services_file"; then
		return 0
	fi
	if grep -Fxq -- "22/tcp" "$ports_file"; then
		return 0
	fi
	return 1
}

prepare_effective_ssh() {
	local zone="$1"
	local manage
	manage=$(cat "$WORK/z/$zone/manage_target")
	if [ "$manage" -eq 1 ]; then
		cp "$WORK/z/$zone/target" "$WORK/z/$zone/eff_target"
	else
		cp "$WORK/z/$zone/perm_target" "$WORK/z/$zone/eff_target"
	fi
	manage=$(cat "$WORK/z/$zone/manage_services")
	if [ "$manage" -eq 1 ]; then
		cp "$WORK/z/$zone/services" "$WORK/z/$zone/eff_services"
	else
		cp "$WORK/z/$zone/perm_services" "$WORK/z/$zone/eff_services"
	fi
	manage=$(cat "$WORK/z/$zone/manage_ports")
	if [ "$manage" -eq 1 ]; then
		cp "$WORK/z/$zone/ports" "$WORK/z/$zone/eff_ports"
	else
		cp "$WORK/z/$zone/perm_ports" "$WORK/z/$zone/eff_ports"
	fi
}

client_covered_by() {
	local client="$1"
	local file="$2"
	local src norm family
	case "$client" in
		*:*) family=v6 ;;
		*) family=v4 ;;
	esac
	while IFS= read -r src; do
		[ -n "$src" ] || continue
		norm=$(parse_source "$src") || continue
		if [ "$family" = v4 ]; then
			if ipv4_contains "$norm" "$client"; then
				return 0
			fi
		else
			case "$norm" in
				*/*) continue ;;
			esac
			if ipv6_exact "$norm" "$client"; then
				return 0
			fi
		fi
	done < "$file"
	return 1
}

check_ssh() {
	local zone client="" have_client=0 covered=0
	local any_unmanaged=0 any_managed_with_src=0
	if [ -n "${SSH_CONNECTION:-}" ]; then
		have_client=1
		client=${SSH_CONNECTION%% *}
		[ -n "$client" ] || die "SSH_CONNECTION is set but the client address is empty"
	else
		log_event info "SSH client check skipped; SSH_CONNECTION is unset"
		say "SSH client check skipped"
	fi
	read_perm_zones
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		if zone_listed "$zone" "$WORK/zones"; then
			prepare_effective_ssh "$zone"
			if zone_allows_ssh_files "$WORK/z/$zone/eff_target" "$WORK/z/$zone/eff_services" "$WORK/z/$zone/eff_ports"; then
				if [ -s "$WORK/z/$zone/sources" ]; then
					any_managed_with_src=1
				fi
				if [ "$have_client" -eq 1 ]; then
					if client_covered_by "$client" "$WORK/z/$zone/sources"; then
						covered=1
					fi
				fi
			fi
		else
			read_list_prop permanent "$zone" services "$WORK/ssh-$zone-services"
			read_list_prop permanent "$zone" ports "$WORK/ssh-$zone-ports"
			read_target_prop permanent "$zone" "$WORK/ssh-$zone-target"
			if zone_allows_ssh_files "$WORK/ssh-$zone-target" "$WORK/ssh-$zone-services" "$WORK/ssh-$zone-ports"; then
				any_unmanaged=1
				if [ "$have_client" -eq 1 ]; then
					read_list_prop permanent "$zone" sources "$WORK/ssh-$zone-sources"
					if client_covered_by "$client" "$WORK/ssh-$zone-sources"; then
						covered=1
					fi
				fi
			fi
		fi
	done < "$WORK/perm-zones"
	if [ "$any_unmanaged" -eq 0 ] && [ "$any_managed_with_src" -eq 0 ]; then
		die "no zone would allow SSH after these changes"
	fi
	if [ "$have_client" -eq 1 ] && [ "$covered" -eq 0 ]; then
		die "SSH client $client is not covered by a zone that will allow SSH"
	fi
}

execute_plan() {
	local op a b
	while IFS="$(printf '\t')" read -r op a b; do
		[ -n "$op" ] || continue
		case "$op" in
			new-zone)
				say "Creating zone $a"
				log_event info "creating zone" "$a" "" "new-zone"
				fw_mut --permanent --new-zone="$a"
				;;
			set-target)
				say "Setting target $b on zone $a"
				log_event info "setting target" "$a" "$b" "set-target"
				fw_mut --permanent --zone="$a" --set-target="$b"
				;;
			add-service)
				say "Adding service $b to zone $a"
				log_event info "adding service" "$a" "$b" "add-service"
				fw_mut --permanent --zone="$a" --add-service="$b"
				;;
			remove-service)
				say "Removing service $b from zone $a"
				log_event info "removing service" "$a" "$b" "remove-service"
				fw_mut --permanent --zone="$a" --remove-service="$b"
				;;
			add-port)
				say "Adding port $b to zone $a"
				log_event info "adding port" "$a" "$b" "add-port"
				fw_mut --permanent --zone="$a" --add-port="$b"
				;;
			remove-port)
				say "Removing port $b from zone $a"
				log_event info "removing port" "$a" "$b" "remove-port"
				fw_mut --permanent --zone="$a" --remove-port="$b"
				;;
			add-source)
				say "Adding source $b to zone $a"
				log_event info "adding source" "$a" "$b" "add-source"
				fw_mut --permanent --zone="$a" --add-source="$b"
				;;
			remove-source)
				say "Removing source $b from zone $a"
				log_event info "removing source" "$a" "$b" "remove-source"
				fw_mut --permanent --zone="$a" --remove-source="$b"
				;;
			*)
				die "unknown plan op $op"
				;;
		esac
		CHANGES=$((CHANGES + 1))
	done < "$WORK/plan"
}

do_reload() {
	say "Reloading firewalld"
	log_event info "reloading firewalld" "" "" "reload"
	fw_mut --reload
	RELOADED=1
}

verify_apply() {
	local zone manage rt src n
	read_run_zones
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		if ! zone_listed "$zone" "$WORK/run-zones"; then
			die "verify failed: zone $zone missing from runtime"
		fi
		read_list_prop runtime "$zone" sources "$WORK/z/$zone/verify_sources"
		: > "$WORK/z/$zone/verify_norms"
		while IFS= read -r src; do
			[ -n "$src" ] || continue
			n=$(parse_source "$src") || n=$src
			printf '%s\n' "$n" >> "$WORK/z/$zone/verify_norms"
		done < "$WORK/z/$zone/verify_sources"
		sort -u "$WORK/z/$zone/verify_norms" -o "$WORK/z/$zone/verify_norms"
		sort -u "$WORK/z/$zone/sources" -o "$WORK/z/$zone/sources"
		if ! cmp -s "$WORK/z/$zone/verify_norms" "$WORK/z/$zone/sources"; then
			die "verify failed: sources for zone $zone"
		fi
		manage=$(cat "$WORK/z/$zone/manage_services")
		if [ "$manage" -eq 1 ]; then
			read_list_prop runtime "$zone" services "$WORK/z/$zone/verify_services"
			sort -u "$WORK/z/$zone/services" -o "$WORK/z/$zone/services"
			if ! cmp -s "$WORK/z/$zone/verify_services" "$WORK/z/$zone/services"; then
				die "verify failed: services for zone $zone"
			fi
		fi
		manage=$(cat "$WORK/z/$zone/manage_ports")
		if [ "$manage" -eq 1 ]; then
			read_list_prop runtime "$zone" ports "$WORK/z/$zone/verify_ports"
			sort -u "$WORK/z/$zone/ports" -o "$WORK/z/$zone/ports"
			if ! cmp -s "$WORK/z/$zone/verify_ports" "$WORK/z/$zone/ports"; then
				die "verify failed: ports for zone $zone"
			fi
		fi
		manage=$(cat "$WORK/z/$zone/manage_target")
		if [ "$manage" -eq 1 ]; then
			read_target_prop runtime "$zone" "$WORK/z/$zone/verify_target"
			rt=$(cat "$WORK/z/$zone/verify_target")
			if [ "$rt" != "$(cat "$WORK/z/$zone/target")" ]; then
				die "verify failed: target for zone $zone"
			fi
		fi
	done < "$WORK/zones"
}

print_plan() {
	local op a b
	while IFS="$(printf '\t')" read -r op a b; do
		[ -n "$op" ] || continue
		case "$op" in
			new-zone)
				say "Creating zone $a"
				printf 'firewall-cmd --permanent --new-zone=%s\n' "$a"
				;;
			set-target)
				say "Setting target $b on zone $a"
				printf 'firewall-cmd --permanent --zone=%s --set-target=%s\n' "$a" "$b"
				;;
			add-service)
				say "Adding service $b to zone $a"
				printf 'firewall-cmd --permanent --zone=%s --add-service=%s\n' "$a" "$b"
				;;
			remove-service)
				say "Removing service $b from zone $a"
				printf 'firewall-cmd --permanent --zone=%s --remove-service=%s\n' "$a" "$b"
				;;
			add-port)
				say "Adding port $b to zone $a"
				printf 'firewall-cmd --permanent --zone=%s --add-port=%s\n' "$a" "$b"
				;;
			remove-port)
				say "Removing port $b from zone $a"
				printf 'firewall-cmd --permanent --zone=%s --remove-port=%s\n' "$a" "$b"
				;;
			add-source)
				say "Adding source $b to zone $a"
				printf 'firewall-cmd --permanent --zone=%s --add-source=%s\n' "$a" "$b"
				;;
			remove-source)
				say "Removing source $b from zone $a"
				printf 'firewall-cmd --permanent --zone=%s --remove-source=%s\n' "$a" "$b"
				;;
			*)
				die "unknown plan op $op"
				;;
		esac
	done < "$WORK/plan"
}

do_check() {
	if [ -s "$WORK/drift" ]; then
		cat "$WORK/drift"
	fi
	if [ -s "$WORK/runtime-drift" ]; then
		cat "$WORK/runtime-drift"
	fi
	if [ -s "$WORK/drift" ] || [ -s "$WORK/runtime-drift" ]; then
		printf '%s\n' "fwdynhosts: drift detected" >&2
		exit 1
	fi
	say "No drift"
	finish
}

do_dry_run() {
	say "Dry run"
	print_plan
	if [ -s "$WORK/plan" ] || [ -s "$WORK/runtime-drift" ]; then
		say "Reloading firewalld"
		printf '%s\n' "firewall-cmd --reload"
	fi
	if [ -s "$WORK/runtime-drift" ]; then
		cat "$WORK/runtime-drift"
	fi
	finish
}

do_apply() {
	local update_latest=0
	if [ ! -s "$WORK/plan" ] && [ ! -s "$WORK/runtime-drift" ]; then
		if [ "$CONFIG_CHANGED" -eq 1 ]; then
			COMMITTED=1
		fi
		say "No changes"
		finish
	fi
	[ -d "$ZONES_DIR" ] || die "zones directory does not exist: $ZONES_DIR"
	if [ -s "$WORK/runtime-drift" ]; then
		cat "$WORK/runtime-drift"
	fi
	take_backup_from "$WORK/zones"
	MUTATION_STARTED=1
	if [ -s "$WORK/plan" ]; then
		execute_plan
		update_latest=1
	fi
	do_reload
	verify_apply
	commit_success "$update_latest"
	log_event info "apply complete" "" "" "apply"
	finish
}

list_contains() {
	local file="$1"
	local item="$2"
	grep -Fxq -- "$item" "$file"
}

migration_preconditions() {
	local target
	read_perm_zones
	read_run_zones
	if ! zone_listed "$CF_ZONE" "$WORK/perm-zones" || ! zone_listed "$CF_ZONE" "$WORK/run-zones"; then
		die "zone $CF_ZONE does not exist in permanent and runtime"
	fi
	read_list_prop permanent "$CF_ZONE" sources "$WORK/mig-cf-sources-p"
	read_list_prop runtime "$CF_ZONE" sources "$WORK/mig-cf-sources-r"
	if [ ! -s "$WORK/mig-cf-sources-p" ]; then
		die "zone $CF_ZONE has no sources"
	fi
	if ! cmp -s "$WORK/mig-cf-sources-p" "$WORK/mig-cf-sources-r"; then
		die "zone $CF_ZONE runtime and permanent sources differ"
	fi
	read_list_prop permanent "$CF_ZONE" services "$WORK/mig-cf-services"
	if ! list_contains "$WORK/mig-cf-services" http || ! list_contains "$WORK/mig-cf-services" https; then
		die "zone $CF_ZONE services do not include http and https"
	fi
	if list_contains "$WORK/mig-cf-services" ssh; then
		die "zone $CF_ZONE includes service ssh"
	fi
	read_list_prop permanent "$CF_ZONE" ports "$WORK/mig-cf-ports"
	if list_contains "$WORK/mig-cf-ports" "22/tcp" || list_contains "$WORK/mig-cf-ports" "22/udp"; then
		die "zone $CF_ZONE includes port 22"
	fi
	read_target_prop permanent "$CF_ZONE" "$WORK/mig-cf-target"
	target=$(cat "$WORK/mig-cf-target")
	case "$target" in
		default|DROP|REJECT) ;;
		*) die "zone $CF_ZONE target is $target" ;;
	esac
	read_list_prop permanent "$CF_ZONE" interfaces "$WORK/mig-cf-ifaces-p"
	read_list_prop runtime "$CF_ZONE" interfaces "$WORK/mig-cf-ifaces-r"
	if [ -s "$WORK/mig-cf-ifaces-p" ] || [ -s "$WORK/mig-cf-ifaces-r" ]; then
		die "zone $CF_ZONE has an interface"
	fi
	if ! zone_listed "$PUBLIC_ZONE" "$WORK/perm-zones" || ! zone_listed "$PUBLIC_ZONE" "$WORK/run-zones"; then
		die "zone $PUBLIC_ZONE does not exist"
	fi
	read_list_prop permanent "$PUBLIC_ZONE" interfaces "$WORK/mig-public-ifaces-p"
	read_list_prop runtime "$PUBLIC_ZONE" interfaces "$WORK/mig-public-ifaces-r"
	if ! list_contains "$WORK/mig-public-ifaces-p" "$PUBLIC_IFACE" || ! list_contains "$WORK/mig-public-ifaces-r" "$PUBLIC_IFACE"; then
		die "zone $PUBLIC_ZONE does not have interface $PUBLIC_IFACE"
	fi
	read_list_prop permanent "$PUBLIC_ZONE" services "$WORK/mig-public-services"
}

migration_plan_removes() {
	local svc
	: > "$WORK/mig-remove"
	for svc in http https; do
		if list_contains "$WORK/mig-public-services" "$svc"; then
			printf '%s\n' "$svc" >> "$WORK/mig-remove"
		fi
	done
}

do_migrate() {
	local svc
	[ -d "$ZONES_DIR" ] || die "zones directory does not exist: $ZONES_DIR"
	migration_preconditions
	migration_plan_removes
	if [ "$MODE" = dry-run ]; then
		say "Dry run"
		while IFS= read -r svc; do
			[ -n "$svc" ] || continue
			say "Removing service $svc from zone $PUBLIC_ZONE"
			printf 'firewall-cmd --permanent --zone=%s --remove-service=%s\n' "$PUBLIC_ZONE" "$svc"
		done < "$WORK/mig-remove"
		if [ -s "$WORK/mig-remove" ]; then
			say "Reloading firewalld"
			printf '%s\n' "firewall-cmd --reload"
		fi
		finish
	fi
	if [ "$CONFIRM" -ne 1 ]; then
		if [ -s "$WORK/mig-remove" ]; then
			while IFS= read -r svc; do
				[ -n "$svc" ] || continue
				say "Would remove service $svc from zone $PUBLIC_ZONE"
			done < "$WORK/mig-remove"
		else
			say "Zone $PUBLIC_ZONE does not have http or https"
		fi
		printf '%s\n' "fwdynhosts: refusing migration without --confirm" >&2
		exit 2
	fi
	cp "$WORK/mig-cf-sources-p" "$WORK/mig-cf-sources-before"
	cp "$WORK/mig-public-ifaces-p" "$WORK/mig-public-ifaces-before"
	printf '%s\n' "$PUBLIC_ZONE" > "$WORK/mig-zones"
	if [ ! -s "$WORK/mig-remove" ]; then
		say "Zone $PUBLIC_ZONE does not have http or https"
		finish
	fi
	take_backup_from "$WORK/mig-zones"
	MUTATION_STARTED=1
	while IFS= read -r svc; do
		[ -n "$svc" ] || continue
		say "Removing service $svc from zone $PUBLIC_ZONE"
		fw_mut --permanent --zone="$PUBLIC_ZONE" --remove-service="$svc"
		CHANGES=$((CHANGES + 1))
	done < "$WORK/mig-remove"
	do_reload
	read_list_prop runtime "$PUBLIC_ZONE" interfaces "$WORK/mig-public-ifaces-after"
	read_list_prop runtime "$PUBLIC_ZONE" services "$WORK/mig-public-services-after"
	read_list_prop runtime "$CF_ZONE" sources "$WORK/mig-cf-sources-after"
	read_list_prop runtime "$CF_ZONE" services "$WORK/mig-cf-services-after"
	if ! cmp -s "$WORK/mig-public-ifaces-before" "$WORK/mig-public-ifaces-after"; then
		die "migration verify failed: $PUBLIC_ZONE interfaces changed"
	fi
	if ! list_contains "$WORK/mig-public-ifaces-after" "$PUBLIC_IFACE"; then
		die "migration verify failed: $PUBLIC_ZONE lost $PUBLIC_IFACE"
	fi
	if list_contains "$WORK/mig-public-services-after" http || list_contains "$WORK/mig-public-services-after" https; then
		die "migration verify failed: $PUBLIC_ZONE still has http or https"
	fi
	: > "$WORK/mig-public-expected"
	while IFS= read -r svc; do
		[ -n "$svc" ] || continue
		case "$svc" in
			http|https) ;;
			*) printf '%s\n' "$svc" >> "$WORK/mig-public-expected" ;;
		esac
	done < "$WORK/mig-public-services"
	sort -u "$WORK/mig-public-expected" -o "$WORK/mig-public-expected"
	sort -u "$WORK/mig-public-services-after" -o "$WORK/mig-public-services-after"
	if ! cmp -s "$WORK/mig-public-expected" "$WORK/mig-public-services-after"; then
		die "migration verify failed: $PUBLIC_ZONE services"
	fi
	sort -u "$WORK/mig-cf-sources-before" -o "$WORK/mig-cf-sources-before"
	sort -u "$WORK/mig-cf-sources-after" -o "$WORK/mig-cf-sources-after"
	if ! cmp -s "$WORK/mig-cf-sources-before" "$WORK/mig-cf-sources-after"; then
		die "migration verify failed: $CF_ZONE sources"
	fi
	if ! list_contains "$WORK/mig-cf-services-after" http || ! list_contains "$WORK/mig-cf-services-after" https; then
		die "migration verify failed: $CF_ZONE lost http or https"
	fi
	commit_success 1
	log_event info "migration complete" "$PUBLIC_ZONE" "" "migrate"
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--config)
				[ $# -ge 2 ] || usage "--config requires a path"
				[ -n "$2" ] || usage "--config requires a path"
				CONFIG=$2
				CONFIG_SET=1
				shift 2
				;;
			--state-dir)
				[ $# -ge 2 ] || usage "--state-dir requires a path"
				[ -n "$2" ] || usage "--state-dir requires a path"
				STATE_DIR=$2
				shift 2
				;;
			--check|--dry-run|--apply|--rollback|--status)
				[ "$MODE_SET" -eq 0 ] || usage "at most one of --check, --dry-run, --apply, --rollback, --status"
				MODE=${1#--}
				MODE_SET=1
				shift
				;;
			--max-age)
				[ $# -ge 2 ] || usage "--max-age requires a positive integer"
				[[ "$2" =~ ^[1-9][0-9]*$ ]] || usage "--max-age requires a positive integer"
				MAX_AGE=$2
				MAX_AGE_SET=1
				shift 2
				;;
			--refresh-cloudflare)
				REFRESH=1
				shift
				;;
			--migrate-public-web)
				MIGRATE=1
				shift
				;;
			--confirm)
				CONFIRM=1
				shift
				;;
			*)
				usage "unknown argument: $1"
				;;
		esac
	done
	if [ "$CONFIRM" -eq 1 ] && [ "$MIGRATE" -eq 0 ]; then
		usage "--confirm requires --migrate-public-web"
	fi
	if [ "$MIGRATE" -eq 1 ] && [ "$REFRESH" -eq 1 ]; then
		usage "--migrate-public-web cannot be combined with --refresh-cloudflare"
	fi
	if [ "$MIGRATE" -eq 1 ] && [ "$CONFIRM" -eq 1 ] && [ "$MODE" = dry-run ]; then
		usage "--confirm cannot be combined with --dry-run"
	fi
	if [ "$MIGRATE" -eq 1 ]; then
		case "$MODE" in
			""|dry-run) ;;
			*) usage "--migrate-public-web cannot be combined with --$MODE" ;;
		esac
	fi
	if [ "$REFRESH" -eq 1 ] && [ "$MODE" = rollback ]; then
		usage "--refresh-cloudflare cannot be combined with --rollback"
	fi
	if [ "$MODE" = status ]; then
		if [ "$REFRESH" -eq 1 ] || [ "$MIGRATE" -eq 1 ] || [ "$CONFIRM" -eq 1 ] || [ "$CONFIG_SET" -eq 1 ]; then
			usage "--status cannot be combined with other modes or flags except --state-dir and --max-age"
		fi
	fi
	if [ "$MAX_AGE_SET" -eq 1 ] && [ "$MODE" != status ]; then
		usage "--max-age requires --status"
	fi
	if [ -z "$MODE" ]; then
		if [ "$REFRESH" -eq 1 ]; then
			MODE=refresh-only
		elif [ "$MIGRATE" -eq 1 ]; then
			MODE=migrate
		else
			MODE=apply
			DEFAULTED_APPLY=1
		fi
	fi
}

prepare_runtime() {
	# FWDYNHOSTS_ASSUME_ROOT is a test-only seam. It does not grant privileges.
	if [ "$(id -u)" -ne 0 ] && [ "${FWDYNHOSTS_ASSUME_ROOT:-}" != 1 ]; then
		die "must run as root"
	fi
	need_bin jq
	need_bin host
	need_bin firewall-cmd
	need_bin flock
	mkdir -p "$STATE_DIR/backups" || die "cannot create state dir"
	chmod 0700 "$STATE_DIR" || die "cannot chmod state dir"
	LOG_FILE="$STATE_DIR/fwdynhosts.log"
	DNS_STATE="$STATE_DIR/dns-state.json"
	rotate_log_if_needed
	touch "$LOG_FILE"
	chmod 0600 "$LOG_FILE" || die "cannot chmod log"
	if [ "$DEFAULTED_APPLY" -eq 1 ]; then
		log_event info "no mode given; applying. explicit --apply is the documented form"
		say "Applying. explicit --apply is the documented form"
	fi
	exec 9>"$STATE_DIR/fwdynhosts.lock" || die "cannot open lock"
	if ! flock -n 9; then
		die "lock is busy"
	fi
	# Status is recorded only after this process owns the lock.
	case "$MODE" in
		apply|rollback)
			RECORD_STATUS=1
			;;
		migrate)
			if [ "$CONFIRM" -eq 1 ]; then
				RECORD_STATUS=1
			fi
			;;
	esac
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/fwdynhosts.XXXXXX") || die "cannot create work dir"
	: > "$WORK/drift"
	: > "$WORK/runtime-drift"
	: > "$WORK/plan"
}

main() {
	parse_args "$@"
	if [ "$MODE" = status ]; then
		do_status
	fi
	prepare_runtime
	if [ "$MODE" = rollback ]; then
		do_rollback
		finish
	fi
	recover_in_progress
	if [ "$MIGRATE" -eq 1 ]; then
		do_migrate
		finish
	fi
	[ -f "$CONFIG" ] || die "config not found: $CONFIG"
	if [ "$REFRESH" -eq 1 ]; then
		do_refresh
		if [ "$MODE" = refresh-only ]; then
			finish
		fi
	fi
	[ -d "$ZONES_DIR" ] || die "zones directory does not exist: $ZONES_DIR"
	validate_structure
	load_config_fields
	resolve_all
	reject_duplicate_sources
	build_plan
	check_source_conflicts
	check_cloudflare_guards
	check_ssh
	case "$MODE" in
		check) do_check ;;
		dry-run) do_dry_run ;;
		apply) do_apply ;;
		*) die "unhandled mode $MODE" ;;
	esac
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
