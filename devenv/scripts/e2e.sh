#!/bin/sh
# End-to-end failover suite (the design record, "E2E test harness"). Runs on the
# host and drives one long-lived topology through docker.
# usage: e2e.sh [SCENARIO...]   (default: every scenario, in the order of ALL)
#
# The host is guarded for the whole run (host-guard.sh).
set -u
cd "$(dirname "$0")/../.."

: "${PKG_DEPENDS:?run through make e2e}"
PROJECT=wgpathd-e2e
E2E_OUT=$PWD/bin/e2e
OUT=$E2E_OUT
ALL="baseline kill-direct mtu-blackhole anchor-only anchor-traffic relay-traffic crash hang neither-reachable one-way roam hub-down mixed observe"
WATCHDOG_PID=
. devenv/scripts/host-guard.sh

guard_start() {
	monitors_start
	echo preflight >"$E2E_OUT/current"
	watchdog kill -TERM $$ &
	WATCHDOG_PID=$!
}

teardown() {
	trap - EXIT INT TERM
	[ -z "$WATCHDOG_PID" ] || kill "$WATCHDOG_PID" 2>/dev/null
	echo "e2e: tearing down"
	stack_down
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
