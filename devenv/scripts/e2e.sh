#!/bin/sh
# End-to-end failover suite (the design record, "E2E test harness"). Runs on the
# host and drives one long-lived topology through docker.
# usage: e2e.sh [SCENARIO...]   (default: every scenario, in the order of ALL)
#
# The host is guarded for the whole run: nothing starts while another project's
# containers run, and a watchdog tears the stack down as soon as the Wi-Fi
# interface drops or the kernel log mentions it.
set -u
cd "$(dirname "$0")/../.."

: "${PKG_DEPENDS:?run through make e2e}"
PROJECT=wgpathd-e2e
COMPOSE="docker compose -p $PROJECT -f devenv/e2e.compose.yaml"
WATCH_IFACE=${E2E_WATCH_IFACE:-wlan0}
E2E_OUT=$PWD/bin/e2e
ALL="baseline kill-direct anchor-only crash hang neither-reachable one-way roam hub-down mixed observe"
WATCHDOG_PID= MONITOR_PID= KLOG_PID=

die() { echo "e2e: $*" >&2; exit 1; }

iface_up() { ip -o link show "$WATCH_IFACE" 2>/dev/null | grep -q 'state UP'; }

host_sysctls() {
	for key in net.ipv6.conf.all.forwarding "net.ipv6.conf.$WATCH_IFACE.accept_ra"; do
		echo "$key = $(sysctl -n "$key" 2>&1)"
	done
}

# An allowlisted container is tolerated only while it has no privileges that
# could touch the host's networking.
tolerated() {
	case " ${E2E_IGNORE_CONTAINERS:-} " in *" $1 "*) ;; *) return 1 ;; esac
	case $(docker inspect -f '{{.HostConfig.Privileged}} {{.HostConfig.NetworkMode}} {{len .HostConfig.CapAdd}}' "$1") in
	"false bridge 0" | "false default 0") ;;
	*) return 1 ;;
	esac
}

preflight() {
	iface_up || die "$WATCH_IFACE is not up, not starting"
	others=
	for c in $(docker ps --format '{{.Names}} {{.Label "com.docker.compose.project"}}' |
		awk -v p="$PROJECT" '$2 != p { print $1 }'); do
		if tolerated "$c"; then echo "e2e: tolerating $c (E2E_IGNORE_CONTAINERS)"; else others="$others $c"; fi
	done
	[ -z "$others" ] || die "other containers are running, not starting:$others"
	if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ]; then
		echo "e2e: removing a leftover $PROJECT stack"
		$COMPOSE down -v --remove-orphans >/dev/null 2>&1
	fi
}

watchdog() { # runner-pid
	while sleep 2; do
		if ! iface_up; then
			reason="$WATCH_IFACE is missing or down"
		elif grep -qiE "mt7921|$WATCH_IFACE" "$E2E_OUT/kernel.log"; then
			reason="the kernel log mentions the Wi-Fi"
		else
			continue
		fi
		echo "$(date -Is) $reason during: $(cat "$E2E_OUT/current")" | tee "$E2E_OUT/ABORTED" >&2
		$COMPOSE down -v --remove-orphans >/dev/null 2>&1
		kill -TERM "$1"
		exit
	done
}

guard_start() {
	rm -rf "$E2E_OUT" && mkdir -p "$E2E_OUT"
	echo preflight >"$E2E_OUT/current"
	host_sysctls >"$E2E_OUT/sysctl.before"
	ip monitor link address route >"$E2E_OUT/ip-monitor.log" 2>&1 &
	MONITOR_PID=$!
	journalctl -k -f -n 0 -o short-iso >"$E2E_OUT/kernel.log" 2>&1 &
	KLOG_PID=$!
	watchdog $$ &
	WATCHDOG_PID=$!
}

host_report() {
	echo "--- host"
	if cmp -s "$E2E_OUT/sysctl.before" "$E2E_OUT/sysctl.after"; then
		sed 's/^/unchanged: /' "$E2E_OUT/sysctl.after"
	else
		echo "HOST SYSCTLS CHANGED:"
		diff "$E2E_OUT/sysctl.before" "$E2E_OUT/sysctl.after"
	fi
	if iface_up; then echo "$WATCH_IFACE: up"; else echo "$WATCH_IFACE: NOT UP"; fi
	echo "ip monitor: $(wc -l <"$E2E_OUT/ip-monitor.log") lines, kernel log: $(wc -l <"$E2E_OUT/kernel.log") lines (in $E2E_OUT)"
	grep -iE "mt7921|$WATCH_IFACE" "$E2E_OUT/kernel.log" && echo "THE KERNEL LOG MENTIONS THE WI-FI"
	[ ! -f "$E2E_OUT/ABORTED" ] || { echo "ABORTED:"; cat "$E2E_OUT/ABORTED"; }
}

teardown() {
	trap - EXIT INT TERM
	[ -z "$WATCHDOG_PID" ] || kill "$WATCHDOG_PID" 2>/dev/null
	echo "e2e: tearing down"
	$COMPOSE down -v --remove-orphans >"$E2E_OUT/down.log" 2>&1
	sleep 2 # the monitors see the teardown too
	kill $MONITOR_PID $KLOG_PID 2>/dev/null
	host_sysctls >"$E2E_OUT/sysctl.after"
	host_report
}

diagnose() { # label
	for n in hub spoke-a spoke-b; do
		x "$n" 'logread; echo; ubus call wgpathd status; wg show; ip addr; ip route; ip -6 route; nft list table inet e2e' \
			>"$E2E_OUT/$1.$n.log" 2>&1
	done
	echo "     diagnostics in $E2E_OUT/$1.*.log"
}

summary() {
	echo "--- timings"
	awk -F'\t' '{ printf "%-18s %-20s %s\n", $1, $2, $3 }' "$E2E_OUT/timings.tsv" 2>/dev/null
	echo "--- scenarios"
	for s in $scenarios; do
		if grep -q "^$s	FAIL" "$E2E_OUT/results.tsv"; then r=FAIL
		elif grep -q "^$s	ok" "$E2E_OUT/results.tsv"; then r=ok
		else r="not run"; fi
		printf '%-18s %s\n' "$s" "$r"
	done
	! grep -q '	FAIL	' "$E2E_OUT/results.tsv"
}

scenarios=${*:-$ALL}
for s in $scenarios; do
	[ -f "test/e2e/$s.sh" ] || die "unknown scenario '$s' (have: $ALL)"
done

preflight
guard_start
trap teardown EXIT
trap 'exit 130' INT TERM
. test/e2e/lib.sh
: >"$E2E_OUT/results.tsv"

echo "e2e: building the package and the image"
make -s package CI=1 >"$E2E_OUT/build.log" 2>&1 || die "make package failed, see $E2E_OUT/build.log"
$COMPOSE build -q >>"$E2E_OUT/build.log" 2>&1 || die "image build failed, see $E2E_OUT/build.log"

echo setup >"$E2E_OUT/current"
SCENARIO=setup
echo "e2e: starting hub, spoke-a and spoke-b"
started=$(now)
$COMPOSE up -d --quiet-pull >"$E2E_OUT/up.log" 2>&1 || die "compose up failed, see $E2E_OUT/up.log"
if ! check "both spokes DIRECT after boot" wait_for 120 converged; then
	diagnose setup
	exit 1
fi
timing time_to_direct "$(since "$started")"

for s in $scenarios; do
	echo "$s" >"$E2E_OUT/current"
	echo "=== $s"
	(SCENARIO=$s; . "test/e2e/$s.sh") || true
	grep -q "^$s	FAIL" "$E2E_OUT/results.tsv" && diagnose "$s"
	restore_all
done

summary
