#!/bin/sh
# Runs inside the openwrt container.
cd "$(dirname "$0")/../.."
status=0

check() {
	ucode -L "$PWD/src" -L "$PWD/test" -c -o /dev/null "$1" || { echo "  in $2" >&2; status=1; }
}

# ucode -c compiles its input as a script, where `export` is a syntax error, so
# modules are checked through a one-line importer. Proxies and the utest config
# are require()d programs that `return` at top level, so they stay scripts.
importer=$(mktemp)
for f in $(find src test -name '*.uc' ! -path 'test/proxies/*' ! -name utest.config.uc); do
	echo "import * as _ from '$PWD/$f';" >"$importer"
	check "$importer" "$f"
done
rm -f "$importer"

for f in test/proxies/*.uc test/utest.config.uc files/usr/libexec/wgpathd/*.uc; do
	check "$f" "$f"
done

for f in files/etc/init.d/wgpathd devenv/scripts/*.sh devenv/services/*/*.sh; do
	sh -n "$f" || { echo "  in $f" >&2; status=1; }
done

exit $status
