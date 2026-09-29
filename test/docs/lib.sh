# Helpers for the docs tooling tests, sourced by each test/docs/*_test.sh.
# They run in the docs tools image (make -C docs test), without network.

TOP=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPTS=$TOP/devenv/scripts
failures=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Away from the checkout: a worktree's .git may point outside the container.
cd "$TMP" || exit 1

# mike reads the committer from git config, not from the environment.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main
git config --global advice.detachedHead false

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

# check DESCRIPTION COMMAND...: shows the command's output only when it fails.
check() {
	desc=$1
	shift
	if out=$("$@" 2>&1); then
		pass "$desc"
	else
		fail "$desc"
		[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/     /'
	fi
}

finish() { exit $((failures > 0)); }

# outputs EXPECTED COMMAND...: succeeds, printing exactly EXPECTED.
outputs() {
	expected=$1
	shift
	actual=$("$@" 2>&1) || { echo "failed: $actual"; return 1; }
	[ "$actual" = "$expected" ] || { echo "got: $actual"; return 1; }
}

# refuses MESSAGE COMMAND...: fails, with exactly MESSAGE on stderr.
refuses() {
	expected=$1
	shift
	actual=$("$@" 2>&1 >/dev/null) && { echo "succeeded"; return 1; }
	[ "$actual" = "$expected" ] || { echo "got: $actual"; return 1; }
}

# at DIR COMMAND...: runs COMMAND in DIR.
at() (
	cd "$1" || exit
	shift
	"$@"
)

# commit DIR FILE CONTENT: writes FILE and commits it.
commit() {
	mkdir -p "$(dirname "$1/$2")"
	printf '%s\n' "$3" >"$1/$2"
	git -C "$1" add "$2"
	git -C "$1" commit -qm "$2: $3"
}
