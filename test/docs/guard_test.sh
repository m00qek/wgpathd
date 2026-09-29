#!/bin/sh
# docs-guard.sh: a docs/X.Y branch differs from its newest release tag only in the docs.
. "$(dirname "$0")/lib.sh"

repo=$TMP/repo
git init -q "$repo"
commit "$repo" src/wgpathd.uc 'code 0.9.0'
commit "$repo" docs/index.md 'docs 0.9.0'
commit "$repo" mkdocs.yml 'site_name: test'
git -C "$repo" tag v0.9.0

guard() { at "$repo" "$SCRIPTS/docs-guard.sh" "$@"; }
on() { git -C "$repo" checkout -q "$@"; }

on -b docs/0.9 v0.9.0
check "branch at its tag passes" outputs v0.9.0 guard docs/0.9
check "refs/heads/ form passes" outputs v0.9.0 guard refs/heads/docs/0.9

commit "$repo" docs/index.md 'docs fix'
commit "$repo" mkdocs.yml 'site_name: test fixed'
commit "$repo" mkdocs.mike.yml 'INHERIT: mkdocs.yml'
commit "$repo" docs/overrides/main.html 'banner'
check "docs and mkdocs config changes pass" outputs v0.9.0 guard docs/0.9

on -b code-fix
commit "$repo" src/wgpathd.uc 'code fix'
commit "$repo" files/etc/config/wgpathd 'config fix'
git -C "$repo" branch -f docs/0.9 code-fix
on docs/0.9
check "code changes are refused" refuses \
	"docs/0.9 changes files outside docs/: files/etc/config/wgpathd src/wgpathd.uc; code fixes need a release" \
	guard docs/0.9

on -B docs/0.9 v0.9.0
commit "$repo" src/docs/notes.md 'not the docs'
check "a docs/ folder elsewhere is refused" refuses \
	"docs/0.9 changes files outside docs/: src/docs/notes.md; code fixes need a release" \
	guard docs/0.9

on -B docs/0.9 v0.9.0
check "a tag of another minor is refused" refuses "v0.10.0 is not a 0.9 release" guard docs/0.9 v0.10.0
check "a branch as the tag is refused" refuses "not a release tag: docs/0.9" guard docs/0.9 docs/0.9
check "not a docs branch is refused" refuses "not a docs/X.Y branch: main" guard main
check "a release tag is not a docs branch" refuses "not a docs/X.Y branch: v0.9.0" guard v0.9.0
check "a minor without a release tag is refused" refuses "docs/0.8 has no v0.8.* release tag" guard docs/0.8

# A patch release made on main that docs/0.9 has not moved to yet.
on -b main-0.9.1 v0.9.0
commit "$repo" src/wgpathd.uc 'code 0.9.1'
git -C "$repo" tag v0.9.1
on docs/0.9
check "the newest tag not being an ancestor is refused" \
	refuses "v0.9.1 is not an ancestor of docs/0.9" guard docs/0.9

# v0.9.10 is newer than v0.9.9, although it sorts first as text.
on -B docs/0.9 v0.9.1
commit "$repo" src/wgpathd.uc 'code 0.9.9'
git -C "$repo" tag v0.9.9
commit "$repo" src/wgpathd.uc 'code 0.9.10'
git -C "$repo" tag v0.9.10
git -C "$repo" tag v0.9.11-rc1
commit "$repo" docs/index.md 'docs for 0.9.10'
check "the newest tag is chosen by version (v0.9.10 over v0.9.9)" outputs v0.9.10 guard docs/0.9

finish
