#!/bin/sh
# Fails on the ways a LuCI view can turn data into markup: HTML sinks, and `%s`
# formatting, which does not escape (`%h` does). Takes the files to check.
status=0

if grep -nE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write' "$@"; then
	echo "  HTML sink: build nodes with E() and array children" >&2
	status=1
fi

if grep -nE "%s[^'\"]*['\"][[:space:]]*\)?[[:space:]]*\.format\(" "$@"; then
	echo "  %s in .format(): use %h for text, %d for numbers" >&2
	status=1
fi

exit $status
