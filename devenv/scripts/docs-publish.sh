#!/bin/sh
# usage: docs-publish.sh REF
# Publishes the docs of the current checkout of REF, a release tag vX.Y.Z or a
# docs/X.Y branch, as version X.Y on origin's gh-pages branch with mike. Run
# from the repository root, one publish at a time (CI: .github/workflows/docs.yml).
set -e
here=$(dirname "$0")
ref=${1#refs/tags/}
ref=${ref#refs/heads/}

version=$("$here/docs-version.sh" "$ref")
case $ref in
docs/*) tag=$("$here/docs-guard.sh" "$ref") ;;
*) tag=$ref ;;
esac
title=${tag#v}

# CI checkouts carry no local gh-pages, and mike builds on the local branch.
fetch_gh_pages() {
	if git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
		git fetch -q origin +gh-pages:refs/heads/gh-pages
	fi
}

published_versions() {
	git ls-tree -d --name-only gh-pages 2>/dev/null | grep -xE '[0-9]+\.[0-9]+' || true
}

# Republishing an older minor must not take latest from a newer one.
is_newest() {
	[ "$({ published_versions; echo "$1"; } | sort -V | tail -n 1)" = "$1" ]
}

# mike owns the version folders, versions.json and the default redirect; the
# rest of gh-pages' root is ours.
put_root_files() {
	scratch=$(mktemp -d)
	export GIT_INDEX_FILE="$scratch/index"
	git read-tree gh-pages
	git update-index --add --cacheinfo "100644,$(git hash-object -w devenv/gh-pages/404.html),404.html"
	git update-index --add --cacheinfo "100644,$(git hash-object -w --stdin </dev/null),.nojekyll"
	tree=$(git write-tree)
	unset GIT_INDEX_FILE
	rm -rf "$scratch"

	[ "$tree" != "$(git rev-parse 'gh-pages^{tree}')" ] || return 0
	git update-ref refs/heads/gh-pages \
		"$(git commit-tree "$tree" -p gh-pages -m 'Root files: 404 redirect to latest, .nojekyll')"
}

fetch_gh_pages
if is_newest "$version"; then
	echo "publishing $version ($title) as latest"
	mike deploy -F mkdocs.mike.yml --title "$title" --update-aliases "$version" latest
	mike set-default -F mkdocs.mike.yml latest
else
	echo "publishing $version ($title); latest stays on $(published_versions | sort -V | tail -n 1)"
	mike deploy -F mkdocs.mike.yml --title "$title" "$version"
fi
put_root_files
git push -q origin gh-pages
