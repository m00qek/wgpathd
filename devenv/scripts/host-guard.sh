# Host safety for the e2e runner and the lab, sourced by both. Nothing starts
# while another project's containers run, the host's IPv6 sysctls are recorded
# before and after, and a watchdog tears the stack down as soon as the Wi-Fi
# interface drops or the kernel log mentions it.
# The caller sets PROJECT (the compose project) and OUT (where the logs go).

export E2E_PROJECT=$PROJECT
COMPOSE="docker compose -p $PROJECT -f devenv/e2e.compose.yaml"
WATCH_IFACE=${E2E_WATCH_IFACE:-wlan0}

die() { echo "${PROJECT#wgpathd-}: $*" >&2; exit 1; }

iface_up() { ip -o link show "$WATCH_IFACE" 2>/dev/null | grep -q 'state UP'; }

# Read from /proc: sysctl(8) is often not on an unprivileged user's PATH.
host_sysctls() {
	for key in net/ipv6/conf/all/forwarding "net/ipv6/conf/$WATCH_IFACE/accept_ra"; do
		echo "$key = $(cat "/proc/sys/$key" 2>&1)"
	done
}

preflight() {
	iface_up || die "$WATCH_IFACE is not up, not starting"
	# The lab and the suite share one addressing plan, so they can never run together.
	sibling=$(docker ps --format '{{.Label "com.docker.compose.project"}}' |
		grep '^wgpathd-' | grep -vx "$PROJECT" | sort -u | tr '\n' ' ')
	[ -z "$sibling" ] || die "$sibling is running, not starting"
	others=$(docker ps --format '{{.Names}} {{.Label "com.docker.compose.project"}}' |
		awk '$2 !~ /^wgpathd-/ { printf " %s", $1 }')
	if [ -n "$others" ]; then
		[ "${E2E_STRICT:-}" != 1 ] || die "other containers are running, not starting (E2E_STRICT=1):$others"
		echo "${PROJECT#wgpathd-}: warning: other containers are running:$others"
	fi
	if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ]; then
		echo "${PROJECT#wgpathd-}: removing a leftover $PROJECT stack"
		$COMPOSE down -v --remove-orphans >/dev/null 2>&1
	fi
}

# setsid keeps the monitors out of the terminal's process group, so a Ctrl-C
# or a closed terminal cannot stop them before the teardown is recorded.
monitors_start() {
	rm -rf "$OUT" && mkdir -p "$OUT"
	host_sysctls >"$OUT/sysctl.before"
	setsid ip monitor link address route </dev/null >"$OUT/ip-monitor.log" 2>&1 &
	echo $! >"$OUT/ip-monitor.pid"
	setsid journalctl -k -f -n 0 -o short-iso </dev/null >"$OUT/kernel.log" 2>&1 &
	echo $! >"$OUT/kernel.pid"
}

monitors_stop() {
	for f in "$OUT/ip-monitor.pid" "$OUT/kernel.pid"; do
		[ -f "$f" ] || continue
		kill "$(cat "$f")" 2>/dev/null
		rm -f "$f"
	done
}

wifi_trouble() {
	if ! iface_up; then
		echo "$WATCH_IFACE is missing or down"
	elif grep -qiE "mt7921|$WATCH_IFACE" "$OUT/kernel.log"; then
		echo "the kernel log mentions the Wi-Fi"
	else
		return 1
	fi
}

watchdog() { # command to run once the stack is down
	while sleep 2; do
		reason=$(wifi_trouble) || continue
		echo "$(date -Is) $reason during: $(cat "$OUT/current")" | tee "$OUT/ABORTED" >&2
		$COMPOSE down -v --remove-orphans >/dev/null 2>&1
		"$@"
		exit
	done
}

stack_down() {
	$COMPOSE down -v --remove-orphans >"$OUT/down.log" 2>&1
	sleep 2 # the monitors see the teardown too
	monitors_stop
	host_sysctls >"$OUT/sysctl.after"
}

host_report() {
	echo "--- host"
	if cmp -s "$OUT/sysctl.before" "$OUT/sysctl.after"; then
		sed 's/^/unchanged: /' "$OUT/sysctl.after"
	else
		echo "HOST SYSCTLS CHANGED:"
		diff "$OUT/sysctl.before" "$OUT/sysctl.after"
	fi
	if iface_up; then echo "$WATCH_IFACE: up"; else echo "$WATCH_IFACE: NOT UP"; fi
	echo "ip monitor: $(wc -l <"$OUT/ip-monitor.log") lines, kernel log: $(wc -l <"$OUT/kernel.log") lines (in $OUT)"
	grep -iE "mt7921|$WATCH_IFACE" "$OUT/kernel.log" && echo "THE KERNEL LOG MENTIONS THE WI-FI"
	[ ! -f "$OUT/ABORTED" ] || { echo "ABORTED:"; cat "$OUT/ABORTED"; }
}
