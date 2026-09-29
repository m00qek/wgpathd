#!/bin/sh
# docs-version.sh: the docs version X.Y a ref publishes.
. "$(dirname "$0")/lib.sh"

version() { "$SCRIPTS/docs-version.sh" "$@"; }

check "tag v0.10.3 publishes 0.10" outputs 0.10 version v0.10.3
check "tag v1.2.0 publishes 1.2" outputs 1.2 version v1.2.0
check "refs/tags/v0.9.12 publishes 0.9" outputs 0.9 version refs/tags/v0.9.12
check "branch docs/0.9 publishes 0.9" outputs 0.9 version docs/0.9
check "refs/heads/docs/0.10 publishes 0.10" outputs 0.10 version refs/heads/docs/0.10

for junk in '' main v0.9 0.9.1 v0.9.1-rc1 v0.9.1.2 vX.Y.Z docs/0.9.1 docs/v0.9 docs/0.9/x \
	feature/docs/0.9 refs/heads/v0.9.1 refs/tags/docs/0.9; do
	check "refuses '$junk'" \
		refuses "not a release tag vX.Y.Z or a docs/X.Y branch: $junk" version "$junk"
done

finish
