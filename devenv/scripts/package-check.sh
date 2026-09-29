#!/bin/sh
# Installs the built packages offline into a rootfs that already carries their
# dependencies, with NET_ADMIN in an otherwise empty network namespace, so fw4
# can load rules for real. Nothing here boots procd; ubusd and rpcd run only
# for the checks of the wgpathd.config plugin.
set -u

# The version openwrt/wgpathd/Makefile builds: bin/ keeps older builds too.
: "${PKG_FULLVERSION:?run through make package-check}"
APK=/artifacts/wgpathd-$PKG_FULLVERSION.apk
APP=/artifacts/luci-app-wgpathd-$PKG_FULLVERSION.apk
failures=0
exec 3>&1

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

has_mode() { [ -n "$(find "$2" -prune -perm "$1")" ]; }

# A ucode exception prints "Runtime error" / "Syntax error" and a stack of
# "In ..., file ..., line ..." frames; a clean failure prints one reason.
fails_cleanly() {
	out=$("$@" 2>&1) && return 1
	[ -n "$out" ] || return 1
	echo "$out" | grep -qE 'Runtime error|Syntax error|called from|^In ' && return 1
	echo "     -> $out" >&3
}

# Splits the apk's embedded install scripts into files and syntax-checks each.
scripts_parse() {
	rm -f /tmp/script.*
	apk adbdump "$1" | awk '
		/^scripts:/                   { in_scripts = 1; next }
		/^[^ ]/                       { in_scripts = 0; out = "" }
		in_scripts && /^  [a-z-]+: \|$/ { out = "/tmp/script." $1; next }
		out != ""                     { sub(/^    /, ""); print > out }'
	for s in /tmp/script.*; do sh -n "$s" || return 1; done
}

[ -f "$APK" ] || { echo "no $APK (run make package)" >&2; exit 1; }
[ -f "$APP" ] || { echo "no $APP (run make package)" >&2; exit 1; }
echo "checking $APK and $APP"

VIEWS=/www/luci-static/resources/view/wgpathd
MENU=/usr/share/luci/menu.d/luci-app-wgpathd.json
ACL=/usr/share/rpcd/acl.d/luci-app-wgpathd.json

apk_version() { apk adbdump "$1" | sed -n 's/^  version: //p'; }
pins_daemon_version() { apk adbdump "$APP" | grep -qx "    - wgpathd=$(apk_version "$APK")"; }

# No second wgpathd build to install, so the installed one is made to look like another release.
refuses_other_daemon_release() {
	cp /lib/apk/db/installed /tmp/installed.db
	sed -i '/^P:wgpathd$/,/^$/s/^V:.*/V:0.0.0-r0/' /lib/apk/db/installed
	apk add --allow-untrusted --no-network --simulate "$APP" 2>&1 | grep -q 'breaks: luci-app-wgpathd'
	refused=$?
	cp /tmp/installed.db /lib/apk/db/installed
	return $refused
}

seed_luci_caches() { mkdir -p /tmp/luci-modulecache && touch /tmp/luci-indexcache.test.json /tmp/luci-modulecache/test; }
luci_caches_cleared() { [ ! -e /tmp/luci-indexcache.test.json ] && [ ! -e /tmp/luci-modulecache ]; }

json_parses() { ucode -e 'json(require("fs").readfile(ARGV[0]))' "$1"; }
# LuCI compiles a view as a function body (top-level `return`), so it is parsed the same way.
view_parses() { qjs --std -e 'new Function(std.loadFile(scriptArgs[0]))' "$1"; }

wgpathd_rules_are() { [ "$(nft list ruleset 2>/dev/null | grep -c 'comment "wgpathd: ')" = "$1" ]; }
fw4_starts_clean() { fw4 start >/dev/null 2>&1 && wgpathd_rules_are 0; }

# The image build already installed every dependency from the feeds.
check "dependencies present" apk add --allow-untrusted --no-network --simulate "$APK" "$APP"
check "app pins the daemon's version" pins_daemon_version
# The postinst reloads fw4, which only has a ruleset to reload if it is running.
check "fw4 loads the base ruleset" fw4_starts_clean
check "package installs" sh -c 'apk add --allow-untrusted --no-network "$1" >/tmp/install.log 2>&1' - "$APK"
# The default postinst runs `/etc/init.d/wgpathd start`; shipped disabled, it must not even validate.
check "install start is inert" sh -c '! grep -qE "not starting|Runtime error" /tmp/install.log'

check "config 0600"         has_mode 600 /etc/config/wgpathd
check "init script 0755"    has_mode 755 /etc/init.d/wgpathd
for f in daemon status check; do
	check "libexec $f.uc 0755" has_mode 755 /usr/libexec/wgpathd/$f.uc
done
check "nothing on the PATH" test ! -e /usr/sbin/wgpathd
check "fw4 include 0644"    has_mode 644 /usr/share/nftables.d/chain-pre/input/wgpathd.nft
check "modules 0644"        has_mode 644 /usr/share/ucode/wgpathd/daemon.uc
check "components shipped"  test -f /usr/share/ucode/wgpathd/components/exec.uc -a -f /usr/share/ucode/wgpathd/components/icmp.uc
check "no uci-defaults" sh -c '! grep -q uci-defaults /lib/apk/packages/wgpathd.list'
check "config is a conffile" grep -qx /etc/config/wgpathd /lib/apk/packages/wgpathd.conffiles

check "modules on default search path" ucode -e 'import * as d from "wgpathd.daemon"; exit(type(d.run) == "function" ? 0 : 1);'
check "shipped disabled" sh -c '[ "$(uci -q get wgpathd.main.enabled)" = 0 ]'
# The daemon echoes its log to stderr only on a tty or when asked to.
check "daemon with default config fails cleanly" fails_cleanly env WGPATHD_STDERR=1 /usr/libexec/wgpathd/daemon.uc
check "config check fails cleanly on the example" fails_cleanly /usr/libexec/wgpathd/check.uc --config
check "status without a daemon fails cleanly" fails_cleanly /usr/libexec/wgpathd/status.uc

# Without ubus the full check skips the interfaces, so a valid hub config passes.
touch /etc/config/network
uci -q batch <<-EOF
	set network.wg_mesh=interface
	set network.wg_mesh.proto=wireguard
	set wgpathd.main.role=hub
	set wgpathd.main.read_iface=wg_mesh
	set wgpathd.main.serve_addr=192.0.2.1
	set wgpathd.main.serve_port=7780
EOF
check "full check passes a valid config without ubus" /usr/libexec/wgpathd/check.uc

check "rpcd plugin 0644"      has_mode 644 /usr/share/rpcd/ucode/wgpathd.uc
check "rpcd plugin compiles"  ucode -c -o /dev/null /usr/share/rpcd/ucode/wgpathd.uc

# A real ubusd and rpcd, started by hand since nothing here runs procd; stopped
# again before the checks below, which expect no ubus.
start_rpcd() {
	mkdir -p /var/run/ubus
	ubusd >/dev/null 2>&1 &
	for _ in 1 2 3 4 5; do [ -S /var/run/ubus/ubus.sock ] && break; sleep 1; done
	rpcd >/dev/null 2>&1 &
	ubus -t 5 wait_for wgpathd.config
}
stop_rpcd() { killall rpcd ubusd 2>/dev/null; }
config_check() { ubus call wgpathd.config check "$@" 2>&1; }

# The valid hub config above passes, and ubus being up adds no interface finding.
answers_without_daemon() {
	out=$(config_check) || return 1
	echo "$out" | grep -q '"ok": true' && ! echo "$out" | grep -q '"subject": "wg_mesh"'
}
takes_candidate() {
	config_check '{"candidate":{"main":{"serve_port":""}}}' | grep -q '"option": "serve_port"'
}
refuses_malformed_candidate() {
	config_check '{"candidate":{"peers":{"nope":{}}}}' | grep -q '"error": "CHECK_INVALID_CANDIDATE"'
}

check "rpcd serves wgpathd.config" start_rpcd
check "config check answers without the daemon" answers_without_daemon
check "config check takes a candidate" takes_candidate
check "config check refuses a malformed candidate" refuses_malformed_candidate
stop_rpcd

/etc/init.d/wgpathd disable
check "init script enables" sh -c '/etc/init.d/wgpathd enable && [ -L /etc/rc.d/S95wgpathd ]'

check "fw4 includes the nft file" sh -c \
	'fw4 print 2>/dev/null | grep -q "include \"/usr/share/nftables.d/chain-pre/input/wgpathd.nft\""'
check "install loads the four wgpathd rules" wgpathd_rules_are 4
check "fw4 ruleset passes nft -c" sh -c 'fw4 print 2>/dev/null | nft -c -f -'
check "install, upgrade and removal reload fw4" sh -c \
	'[ "$(apk adbdump "$1" | grep -c "/etc/init.d/firewall reload")" = 3 ]' - "$APK"
check "install, upgrade and removal reload rpcd" sh -c \
	'[ "$(apk adbdump "$1" | grep -c "/etc/init.d/rpcd reload")" = 3 ]' - "$APK"
check "upgrade restarts a running daemon" sh -c \
	'[ "$(apk adbdump "$1" | grep -c "/etc/init.d/wgpathd restart")" = 2 ]' - "$APK"
check "package scripts parse" scripts_parse "$APK"

check "app refuses another wgpathd release" refuses_other_daemon_release
seed_luci_caches
check "app installs" apk add --allow-untrusted --no-network "$APP"
check "app install clears the LuCI caches" luci_caches_cleared
check "app ships only its menu, ACL and views" sh -c \
	'[ "$(grep -c . /lib/apk/packages/luci-app-wgpathd.list)" = 4 ]'
for f in "$MENU" "$ACL" "$VIEWS/status.js" "$VIEWS/settings.js"; do
	check "$f 0644" has_mode 644 "$f"
done
check "menu JSON parses" json_parses "$MENU"
check "ACL JSON parses" json_parses "$ACL"
check "status view parses" view_parses "$VIEWS/status.js"
check "settings view parses" view_parses "$VIEWS/settings.js"
check "app scripts parse" scripts_parse "$APP"
seed_luci_caches
check "app removes cleanly and keeps the daemon" sh -c \
	'apk del luci-app-wgpathd >/dev/null 2>&1 && [ ! -e "$1" ] && [ ! -d "$2" ] && apk info -e wgpathd' - "$MENU" "$VIEWS"
check "app removal clears the LuCI caches" luci_caches_cleared

check "package removes cleanly" sh -c \
	'apk del wgpathd >/dev/null 2>&1 && [ ! -e /usr/share/nftables.d/chain-pre/input/wgpathd.nft ] &&
		[ ! -e /usr/share/rpcd/ucode/wgpathd.uc ]'
check "removal unloads the wgpathd rules" wgpathd_rules_are 0

[ "$failures" -eq 0 ] && echo "package-check: all passed" && exit 0
echo "package-check: $failures failed"
exit 1
