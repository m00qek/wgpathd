#!/bin/sh
# docs-publish.sh end to end: mike deploys to a local bare repository as origin.
. "$(dirname "$0")/lib.sh"

remote=$TMP/remote.git
repo=$TMP/repo

git init -q --bare "$remote"
git init -q "$repo"
git -C "$repo" remote add origin "$remote"

# A one-page site with the real mike config, banner and 404 page.
mkdir -p "$repo/docs/overrides" "$repo/devenv/gh-pages"
cp "$TOP/mkdocs.mike.yml" "$repo/"
cp "$TOP/docs/overrides/main.html" "$repo/docs/overrides/"
cp "$TOP/devenv/gh-pages/404.html" "$repo/devenv/gh-pages/"
printf 'site_name: test\ntheme:\n  name: material\nexclude_docs: |\n  overrides/\n' >"$repo/mkdocs.yml"
git -C "$repo" add .
commit "$repo" docs/index.md 'docs 0.9.0'
commit "$repo" src/wgpathd.uc 'code 0.9.0'
git -C "$repo" tag v0.9.0

publish() {
	git -C "$repo" checkout -q "$1"
	at "$repo" "$SCRIPTS/docs-publish.sh" "$1"
}

pages() { git -C "$remote" "$@"; }
page_has() { pages show "gh-pages:$1" | grep -q "$2"; }
is_folder() { [ "$(pages cat-file -t "gh-pages:$1")" = tree ]; }

# versions.json as "version:title:aliases" lines, newest first.
versions() {
	pages show gh-pages:versions.json | python3 -c '
import json, sys
for v in json.load(sys.stdin):
    print("%s:%s:%s" % (v["version"], v["title"], ",".join(v["aliases"])))'
}
versions_are() { outputs "$(printf '%s\n' "$@")" versions; }

check "first publish of v0.9.0" publish v0.9.0
check "0.9 takes latest" versions_are 0.9:0.9.0:latest
check "0.9/ holds the 0.9 docs" page_has 0.9/index.html 'docs 0.9.0'
check "latest/ is a copy, not a symlink" is_folder latest
check "latest/ holds the 0.9 docs" page_has latest/index.html 'docs 0.9.0'
check "the root redirects to latest/" page_has index.html 'latest/'
check "the root has the 404 redirect" \
	outputs "$(cat "$TOP/devenv/gh-pages/404.html")" pages show gh-pages:404.html
check "the root has .nojekyll" pages cat-file -e gh-pages:.nojekyll
check "the version selector is on" page_has 0.9/index.html '"provider": *"mike"'

commit "$repo" docs/index.md 'docs 0.10.0'
git -C "$repo" tag v0.10.0
check "publish v0.10.0" publish v0.10.0
check "0.10 takes latest from 0.9" versions_are 0.10:0.10.0:latest 0.9:0.9.0:
check "latest/ holds the 0.10 docs" page_has latest/index.html 'docs 0.10.0'
check "0.9/ is untouched" page_has 0.9/index.html 'docs 0.9.0'

git -C "$repo" branch docs/0.9 v0.9.0
git -C "$repo" checkout -q docs/0.9
commit "$repo" docs/index.md 'docs 0.9.0 fixed'
check "republish 0.9 from docs/0.9" publish docs/0.9
check "latest stays on 0.10, 0.9 keeps its release title" versions_are 0.10:0.10.0:latest 0.9:0.9.0:
check "0.9/ holds the fix" page_has 0.9/index.html 'docs 0.9.0 fixed'
check "latest/ still holds the 0.10 docs" page_has latest/index.html 'docs 0.10.0'

git -C "$repo" checkout -q v0.9.0
commit "$repo" src/wgpathd.uc 'code 0.9.1'
git -C "$repo" tag v0.9.1
check "a patch release retitles its minor" publish v0.9.1
check "latest still on 0.10" versions_are 0.10:0.10.0:latest 0.9:0.9.1:

before=$(pages rev-parse gh-pages)
git -C "$repo" checkout -q -B docs/0.9 v0.9.1
commit "$repo" src/wgpathd.uc 'code sneaked in'
check "a docs branch with code changes is refused" refuses \
	"docs/0.9 changes files outside docs/: src/wgpathd.uc; code fixes need a release" \
	at "$repo" "$SCRIPTS/docs-publish.sh" docs/0.9
check "gh-pages unchanged after the refusal" outputs "$before" pages rev-parse gh-pages

check "junk refs are refused" refuses "not a release tag vX.Y.Z or a docs/X.Y branch: main" \
	at "$repo" "$SCRIPTS/docs-publish.sh" main

finish
