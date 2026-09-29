#!/bin/sh
# Runs inside the docs tools image (make -C docs test).
cd "$(dirname "$0")/../.."
failed=

for t in test/docs/*_test.sh test/docs/*_test.js; do
	echo "# $t"
	case $t in
	*.js) node "$t" ;;
	*) sh "$t" ;;
	esac || failed="$failed $t"
done

[ -z "$failed" ] || { echo "failed:$failed" >&2; exit 1; }
echo "all docs tooling tests passed"
