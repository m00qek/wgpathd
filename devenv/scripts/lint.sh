#!/bin/sh
# Runs inside the openwrt container.
cd "$(dirname "$0")/../.."
status=0

check() {
	ucode -L "$PWD/src" -L "$PWD/test" -c -o /dev/null "$1" || { echo "  in $2" >&2; status=1; }
}

# ucode -c compiles its input as a script, where `export` is a syntax error, so
# modules are checked through a one-line importer. The utest config and the rpcd
# plugin are programs that `return` at top level, so they stay scripts.
importer=$(mktemp)
for f in $(find src test -name '*.uc' ! -name utest.config.uc); do
	echo "import * as _ from '$PWD/$f';" >"$importer"
	check "$importer" "$f"
done
rm -f "$importer"

for f in test/utest.config.uc files/usr/libexec/wgpathd/*.uc files/usr/share/rpcd/ucode/*.uc; do
	check "$f" "$f"
done

for f in files/etc/init.d/wgpathd devenv/scripts/*.sh devenv/services/*/*.sh test/e2e/*.sh test/docs/*.sh; do
	sh -n "$f" || { echo "  in $f" >&2; status=1; }
done

for f in $(find luci -name '*.json'); do
	ucode -e 'json(require("fs").readfile(ARGV[0]))' "$f" || { echo "  in $f" >&2; status=1; }
done

# LuCI compiles a view as a function body (top-level `return`), so it is parsed the same way.
for f in $(find luci -name '*.js'); do
	qjs --std -e 'new Function(std.loadFile(scriptArgs[0]))' "$f" || { echo "  in $f" >&2; status=1; }
done

devenv/scripts/luci-dom-lint.sh $(find luci/htdocs -name '*.js') || status=1

# The check above must still catch what it is for.
bad=$(mktemp)
for line in "el.innerHTML = x;" "_('Peer %s').format(name);" "'%s'.format(name);"; do
	echo "$line" >"$bad"
	devenv/scripts/luci-dom-lint.sh "$bad" >/dev/null 2>&1 &&
		{ echo "luci-dom-lint.sh let through: $line" >&2; status=1; }
done
rm -f "$bad"

devenv/scripts/docs-links.sh || status=1

exit $status
