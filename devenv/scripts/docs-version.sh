#!/bin/sh
# usage: docs-version.sh REF
# Prints the docs version X.Y that REF publishes: a release tag vX.Y.Z or a
# docs/X.Y branch, bare or as refs/tags/... or refs/heads/...
version=$(printf '%s\n' "$1" | sed -nE \
	-e 's/^(refs\/tags\/)?v([0-9]+\.[0-9]+)\.[0-9]+$/\2/p' \
	-e 's/^(refs\/heads\/)?docs\/([0-9]+\.[0-9]+)$/\2/p')

if [ -z "$version" ]; then
	echo "not a release tag vX.Y.Z or a docs/X.Y branch: $1" >&2
	exit 1
fi
echo "$version"
