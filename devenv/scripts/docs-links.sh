#!/bin/sh
# usage: docs-links.sh [ROOT]
# Checks links to a pinned docs version, <site_url><X.Y>/..., in the repository
# at ROOT (default: this one): shipped files must link to the package's current
# minor, and each CHANGELOG.md section `## [X.Y.Z]` to its own minor. Passes
# while mkdocs.yml has no site_url.
cd "${1:-$(dirname "$0")/../..}" || exit 1

site_url=$(sed -nE 's/^site_url:[[:space:]]*["'\'']?([^"'\'' ]*).*/\1/p' mkdocs.yml)
[ -n "$site_url" ] || exit 0
site_url=${site_url%/}/
minor=$(sed -nE 's/^PKG_VERSION:=([0-9]+\.[0-9]+)\..*/\1/p' openwrt/wgpathd/Makefile)

# misses {shipped|changelog} FILE...: prints FILE:LINE: URL (why) for every
# pinned link to the wrong minor.
misses() {
	kind=$1
	shift
	awk -v base="$site_url" -v minor="$minor" -v kind="$kind" '
		BEGIN { want = kind == "shipped" ? minor : "" }
		kind == "changelog" && /^## / {
			want = ""
			if (match($0, /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/)) {
				split(substr($0, 5, RLENGTH - 5), v, ".")
				want = v[1] "." v[2]
			}
		}
		{
			rest = $0
			while ((i = index(rest, base)) > 0) {
				rest = substr(rest, i + length(base))
				if (!match(rest, /^[0-9]+\.[0-9]+\//)) continue
				got = substr(rest, 1, RLENGTH - 1)
				if (got == want) continue
				printf "%s:%d: %s%s/ (%s)\n", FILENAME, FNR, base, got,
					want == "" ? "outside a release section" : "expected " want
			}
		}' "$@"
}

bad=$(
	misses shipped $(find files src openwrt/wgpathd/Makefile -type f)
	[ ! -f CHANGELOG.md ] || misses changelog CHANGELOG.md
)
[ -z "$bad" ] && exit 0
echo "pinned docs links to the wrong version:" >&2
echo "$bad" >&2
exit 1
