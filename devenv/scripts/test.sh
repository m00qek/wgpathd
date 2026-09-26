#!/bin/sh
# Runs inside the openwrt container.
# usage: test.sh {unit|integration|all|watch} [-f FILTER] [-v] [PATH...]
set -e
cd "$(dirname "$0")/../.."

suites() {
	case "$1" in
	unit) roots=test/unit ;;
	integration) roots=test/integration ;;
	*) roots="test/unit test/integration" ;;
	esac
	find $roots -name '*_test*.uc' -exec dirname {} \; | sort -u
}

run() {
	kind=$1
	shift
	[ $# -gt 0 ] || set -- $(suites "$kind")
	utest -c test/utest.config.uc -r "$reporter" ${filter:+-f "$filter"} "$@"
}

cmd=${1:-all}
[ $# -gt 0 ] && shift
reporter=compact
filter=
while getopts f:v opt; do
	case $opt in
	f) filter=$OPTARG ;;
	v) reporter=detailed ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))

case $cmd in
unit | integration | all) run "$cmd" "$@" ;;
watch)
	trap 'exit 130' INT TERM
	while :; do
		run all "$@" || true
		inotifywait -qq -r -e close_write,create,delete,move src test files
	done
	;;
*)
	echo "usage: $0 {unit|integration|all|watch} [-f FILTER] [-v] [PATH...]" >&2
	exit 2
	;;
esac
