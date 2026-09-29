#!/bin/sh
# usage: docs-guard.sh docs/X.Y [TAG]
# Refuses to publish HEAD, the tip of docs/X.Y, unless it differs from its
# release tag only in the docs. TAG defaults to the newest vX.Y.* tag.
# Prints the tag.
set -e
here=$(dirname "$0")

die() { echo "$*" >&2; exit 1; }

newest_tag() { git tag -l "v$1.*" | grep -xE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n 1; }

branch=${1#refs/heads/}
case $branch in
docs/*) ;;
*) die "not a docs/X.Y branch: $1" ;;
esac
minor=$("$here/docs-version.sh" "$branch")

tag=${2:-$(newest_tag "$minor")}
[ -n "$tag" ] || die "$branch has no v$minor.* release tag"
case $tag in
v*) [ "$("$here/docs-version.sh" "$tag")" = "$minor" ] || die "$tag is not a $minor release" ;;
*) die "not a release tag: $tag" ;;
esac

git merge-base --is-ancestor "$tag" HEAD || die "$tag is not an ancestor of $branch"

outside=$(git diff --name-only "$tag" HEAD |
	grep -vx -e 'docs/.*' -e 'mkdocs\.yml' -e 'mkdocs\.mike\.yml' | tr '\n' ' ') || true
[ -z "$outside" ] || die "$branch changes files outside docs/: ${outside% }; code fixes need a release"

echo "$tag"
