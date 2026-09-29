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
MODULE=/www/luci-static/resources/wgpathd.js
INCLUDE=/www/luci-static/resources/view/status/include/70_wgpathd.js
MENU=/usr/share/luci/menu.d/luci-app-wgpathd.json
ACL=/usr/share/rpcd/acl.d/luci-app-wgpathd.json
MIGRATION=/etc/uci-defaults/50-wgpathd-peers

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
# The upgrade from a release with the fw4 include, at the end, needs a ruleset to reload.
check "fw4 loads the base ruleset" fw4_starts_clean
check "package installs" sh -c 'apk add --allow-untrusted --no-network "$1" >/tmp/install.log 2>&1' - "$APK"
# The default postinst runs `/etc/init.d/wgpathd start`; shipped disabled, it must not even validate.
check "install start is inert" sh -c '! grep -qE "not starting|Runtime error" /tmp/install.log'

check "config 0600"         has_mode 600 /etc/config/wgpathd
check "init script 0755"    has_mode 755 /etc/init.d/wgpathd
for f in daemon status check migrate; do
	check "libexec $f.uc 0755" has_mode 755 /usr/libexec/wgpathd/$f.uc
done
check "nothing on the PATH" test ! -e /usr/sbin/wgpathd
check "ships no firewall rules" sh -c '! grep -q nftables /lib/apk/packages/wgpathd.list'
check "install loads no firewall rule" wgpathd_rules_are 0
check "modules 0644"        has_mode 644 /usr/share/ucode/wgpathd/daemon.uc
check "components shipped"  test -f /usr/share/ucode/wgpathd/components/exec.uc -a -f /usr/share/ucode/wgpathd/components/icmp.uc
check "uci-defaults shipped" grep -qx "$MIGRATION" /lib/apk/packages/wgpathd.list
check "uci-defaults consumed on install" test ! -e "$MIGRATION"
check "config is a conffile" grep -qx /etc/config/wgpathd /lib/apk/packages/wgpathd.conffiles

check "modules on default search path" ucode -e 'import * as d from "wgpathd.daemon"; exit(type(d.run) == "function" ? 0 : 1);'
check "shipped disabled" sh -c '[ "$(uci -q get wgpathd.main.enabled)" = 0 ]'
# The daemon echoes its log to stderr only on a tty or when asked to.
check "daemon with default config fails cleanly" fails_cleanly env WGPATHD_STDERR=1 /usr/libexec/wgpathd/daemon.uc
check "config check fails cleanly on the example" fails_cleanly /usr/libexec/wgpathd/check.uc --config
check "status without a daemon fails cleanly" fails_cleanly /usr/libexec/wgpathd/status.uc

# Without ubus the full check skips the interfaces, so a valid hub config passes.
PRIVATE_KEY=aGVsbG8gdGhpcyBpcyBub3QgYSByZWFsIGtleSEhISE=
PRESHARED_KEY=cHJlc2hhcmVkIGtleSBub3QgZm9yIGFueSBleWVzISE=
SPOKE_B_KEY=O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=
touch /etc/config/network
uci -q batch <<-EOF
	set network.wg_mesh=interface
	set network.wg_mesh.proto=wireguard
	set network.wg_mesh.private_key=$PRIVATE_KEY
	add_list network.wg_mesh.addresses=192.0.2.1/24
	set network.spoke_b=wireguard_wg_mesh
	set network.spoke_b.public_key=$SPOKE_B_KEY
	set network.spoke_b.preshared_key=$PRESHARED_KEY
	set network.spoke_b.endpoint_host=2001:db8::12
	set wgpathd.main.role=hub
	set wgpathd.main.read_iface=wg_mesh
	set wgpathd.main.serve_addr=192.0.2.1
	set wgpathd.main.serve_port=7780
	add_list firewall.@zone[1].network=wg_mesh
EOF
# The default firewall's wan zone, which now holds wg_mesh, rejects input.
check "full check passes a valid config without ubus" /usr/libexec/wgpathd/check.uc
check "full check prints the firewall rule the hub needs" sh -c \
	"/usr/libexec/wgpathd/check.uc | grep -qx \"        uci set firewall.@rule\\[-1\\].dest_port='7780'\""

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
# The hub's read interface is the default; network holds its private key and a preshared key.
lists_peers_without_secrets() {
	out=$(ubus call wgpathd.config peers 2>&1) || return 1
	echo "$out" | grep -q '"section": "spoke_b"' && echo "$out" | grep -q '"iface": "wg_mesh"' &&
		! echo "$out" | grep -q -e "$PRIVATE_KEY" -e "$PRESHARED_KEY" -e 2001:db8::12
}
gives_parameter_bounds() {
	ubus call wgpathd.config schema | grep -q '"name": "cycle"'
}
# rpcd runs the plugin as root: it reads /etc/config/firewall itself, whatever the caller may read.
reports_missing_rule() {
	out=$(config_check) || return 1
	echo "$out" | grep -q '"message": "firewall: TCP port 7780 (peer list) from wg_mesh (zone wan): no rule accepts it"' &&
		echo "$out" | grep -q "uci set firewall.@rule\[-1\].dest_port='7780'"
}

check "rpcd serves wgpathd.config" start_rpcd
check "config check answers without the daemon" answers_without_daemon
check "config check takes a candidate" takes_candidate
check "config check refuses a malformed candidate" refuses_malformed_candidate
check "peers lists a peer without its keys or endpoint" lists_peers_without_secrets
check "schema gives the parameter bounds" gives_parameter_bounds
check "config check reports a missing firewall rule, with the rule to add" reports_missing_rule
stop_rpcd

# An upgrade from a release that kept the peer settings in /etc/config/network. There is
# no such build here, so the package is reinstalled over that config: apk runs its
# post-upgrade script for a reinstall as for an upgrade, and extracts every file again.
cat >/etc/config/network <<-EOF
	config interface 'wg_mesh'
		option proto 'wireguard'
		option private_key '$PRIVATE_KEY'

	config interface 'wg_hub'
		option proto 'wireguard'

	config wireguard_wg_mesh 'spoke_b'
		option public_key '$SPOKE_B_KEY'
		option preshared_key '$PRESHARED_KEY'
		option wgpathd_relay '10.10.0.12:51820'
		option wgpathd_tunnel '10.20.0.12'
EOF
uci -q batch <<-EOF
	delete wgpathd.main.read_iface
	delete wgpathd.main.serve_addr
	delete wgpathd.main.serve_port
	set wgpathd.main.role=spoke
	set wgpathd.main.mesh_iface=wg_mesh
	set wgpathd.main.hub_iface=wg_hub
	set wgpathd.main.discovery=http://10.10.0.1:7780/peers
	commit wgpathd
EOF
upgrade_from_older_release() {
	apk add --allow-untrusted --no-network --force-reinstall "$APK" >/tmp/upgrade.log 2>&1 &&
		grep -q 'Executing wgpathd-.*\.post-upgrade' /tmp/upgrade.log || { sed 's/^/     -> /' /tmp/upgrade.log >&3; return 1; }
}
settings_moved() {
	[ "$(uci -q get wgpathd.@peer[0].public_key)" = "$SPOKE_B_KEY" ] &&
		[ "$(uci -q get wgpathd.@peer[0].relay)" = 10.10.0.12:51820 ] &&
		[ "$(uci -q get wgpathd.@peer[0].tunnel)" = 10.20.0.12 ] && [ -z "$(uci -q get wgpathd.@peer[1])" ]
}
# No copy of network, which holds the private keys, is left behind.
network_kept_but_settings() {
	! grep -q wgpathd_ /etc/config/network && [ "$(uci -q get network.spoke_b.preshared_key)" = "$PRESHARED_KEY" ] &&
		[ "$(uci -q get network.wg_mesh.private_key)" = "$PRIVATE_KEY" ] && [ "$(ls -A /etc/config | grep network)" = network ]
}
# default_postinst runs the package's uci-defaults; the restart comes after it.
migrates_before_restart() {
	scripts_parse "$APK" || return 1
	script=$(ls /tmp/script.post-upgrade*)
	runs=$(grep -n -x 'default_postinst' "$script" | cut -d: -f1)
	restarts=$(grep -n 'init.d/wgpathd restart$' "$script" | cut -d: -f1)
	[ -n "$runs" ] && [ -n "$restarts" ] && [ "$runs" -lt "$restarts" ] &&
		sed -n '/^default_postinst()/,/^}/p' /lib/functions.sh | grep -q '/etc/uci-defaults/'
}
check "upgrade from a release with peer settings in network" upgrade_from_older_release
check "upgrade consumed the uci-defaults" test ! -e "$MIGRATION"
check "upgrade moved the peer settings to wgpathd" settings_moved
check "config still 0600" has_mode 600 /etc/config/wgpathd
check "upgrade left network as it was, but for the settings" network_kept_but_settings
check "config check passes with the peer steered" sh -c '/usr/libexec/wgpathd/check.uc --config | grep -q "1 steered peer, 0 not steered"'
check "migration runs before the upgrade restarts the daemon" migrates_before_restart
check "migrate command has nothing left to move" sh -c '/etc/init.d/wgpathd migrate && /usr/libexec/wgpathd/check.uc --config'

/etc/init.d/wgpathd disable
check "init script enables" sh -c '/etc/init.d/wgpathd enable && [ -L /etc/rc.d/S95wgpathd ]'

check "only install and upgrade may reload fw4" sh -c \
	'[ "$(apk adbdump "$1" | grep -c "/etc/init.d/firewall reload")" = 2 ]' - "$APK"
check "install, upgrade and removal reload rpcd" sh -c \
	'[ "$(apk adbdump "$1" | grep -c "/etc/init.d/rpcd reload")" = 3 ]' - "$APK"
check "upgrade restarts a running daemon" sh -c \
	'[ "$(apk adbdump "$1" | grep -c "/etc/init.d/wgpathd restart")" = 2 ]' - "$APK"
check "package scripts parse" scripts_parse "$APK"

check "app refuses another wgpathd release" refuses_other_daemon_release
seed_luci_caches
check "app installs" apk add --allow-untrusted --no-network "$APP"
check "app install clears the LuCI caches" luci_caches_cleared
check "app ships only its menu, ACL, views, module and Overview include" sh -c \
	'[ "$(grep -c . /lib/apk/packages/luci-app-wgpathd.list)" = 6 ]'
for f in "$MENU" "$ACL" "$VIEWS/status.js" "$VIEWS/settings.js" "$MODULE" "$INCLUDE"; do
	check "$f 0644" has_mode 644 "$f"
done
check "menu JSON parses" json_parses "$MENU"
check "ACL JSON parses" json_parses "$ACL"
check "status view parses" view_parses "$VIEWS/status.js"
check "settings view parses" view_parses "$VIEWS/settings.js"
check "shared module parses" view_parses "$MODULE"
check "Overview include parses" view_parses "$INCLUDE"
check "app scripts parse" scripts_parse "$APP"
seed_luci_caches
check "app removes cleanly and keeps the daemon" sh -c \
	'apk del luci-app-wgpathd >/dev/null 2>&1 && [ ! -e "$1" ] && [ ! -d "$2" ] && [ ! -e "$3" ] && [ ! -e "$4" ] &&
		apk info -e wgpathd' - "$MENU" "$VIEWS" "$MODULE" "$INCLUDE"
check "app removal clears the LuCI caches" luci_caches_cleared

check "package removes cleanly" sh -c 'apk del wgpathd >/dev/null 2>&1 && [ ! -e /usr/share/rpcd/ucode/wgpathd.uc ]'

# An upgrade from a release that shipped an fw4 include, up to 5. There is no such build
# here, so the package is installed again and the database made to say it is an older
# one that owns the include, which is put in place and loaded as that release did.
FW4_INCLUDE=/usr/share/nftables.d/chain-pre/input/wgpathd.nft
as_release_with_include() {
	apk add --allow-untrusted --no-network "$APK" >/dev/null 2>&1 || return 1
	mkdir -p "${FW4_INCLUDE%/*}"
	cat >"$FW4_INCLUDE" <<-'EOF'
		icmpv6 type echo-request accept comment "wgpathd: underlay probe"
		meta iifkind "wireguard" icmp type echo-request accept comment "wgpathd: tunnel probe"
		meta iifkind "wireguard" tcp dport 7780 accept comment "wgpathd: discovery publisher"
		meta iifkind "wireguard" udp dport 51820 accept comment "wgpathd: relay ingress"
	EOF
	awk '
		/^C:/ { held = $0; next }
		/^P:/ { pkg = substr($0, 3); print (pkg == "wgpathd") ? "C:Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA=" : held }
		/^V:/ && pkg == "wgpathd" { print "V:0.1.0-r5"; next }
		{ print }
		pkg == "wgpathd" && $0 == "F:usr/share" {
			print "F:usr/share/nftables.d"; print "F:usr/share/nftables.d/chain-pre"
			print "F:usr/share/nftables.d/chain-pre/input"; print "R:wgpathd.nft"
		}' /lib/apk/db/installed >/tmp/installed.db && cp /tmp/installed.db /lib/apk/db/installed &&
		apk info -L wgpathd 2>/dev/null | grep -qx "${FW4_INCLUDE#/}" && fw4 reload >/dev/null 2>&1 && wgpathd_rules_are 4
}
upgrade_from_release_with_include() {
	apk add --allow-untrusted --no-network "$APK" >/tmp/upgrade.log 2>&1 &&
		grep -q ' wgpathd (0.1.0-r5 -> ' /tmp/upgrade.log || { sed 's/^/     -> /' /tmp/upgrade.log >&3; return 1; }
}
check "a release with the fw4 include, its rules loaded" as_release_with_include
check "upgrade from a release with the fw4 include" upgrade_from_release_with_include
check "upgrade removed the include" test ! -e "$FW4_INCLUDE"
check "upgrade unloaded its rules" wgpathd_rules_are 0

[ "$failures" -eq 0 ] && echo "package-check: all passed" && exit 0
echo "package-check: $failures failed"
exit 1
