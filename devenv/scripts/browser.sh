#!/bin/sh
# make browser: LuCI with the built packages and a fake wgpathd in a container with
# no network, and Playwright in a second container that joins only that container's
# network namespace, so the two share nothing but its loopback. No bridge network,
# no capabilities. Results and screenshots go to bin/browser/.
set -eu
cd "$(dirname "$0")/../.."

: "${LUCI_IMAGE:?run through make browser}" "${BROWSER_IMAGE:?}" "${PKG_FULLVERSION:?}"

name=wgpathd-browser-$$
out=bin/browser

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

rm -rf "$out"
mkdir -p "$out/screenshots"
chmod -R a+rwx "$out"

docker run -d --name "$name" --network none -e PKG_FULLVERSION \
	-v "$PWD/bin:/artifacts:ro" \
	-v "$PWD/test/fixtures/luci:/fixtures:ro" \
	-v "$PWD/devenv/services/luci:/opt/luci:ro" \
	"$LUCI_IMAGE" /opt/luci/start.sh >/dev/null

tries=0
until docker exec "$name" wget -q -O /dev/null http://127.0.0.1/luci-static/resources/wgpathd.js 2>/dev/null; do
	tries=$((tries + 1))
	if [ "$tries" -gt 60 ] || [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
		echo "LuCI did not come up:" >&2
		docker logs "$name" >&2
		exit 1
	fi
	sleep 0.5
done

status=0
docker run --rm $(if [ -z "${CI:-}" ] && [ -t 1 ]; then echo -t; fi) \
	--network "container:$name" -u "$(id -u):$(id -g)" -e HOME=/tmp \
	-v "$PWD/test/playwright.config.js:/app/playwright.config.js:ro" \
	-v "$PWD/test/browser:/app/tests:ro" \
	-v "$PWD/$out:/app/results" \
	"$BROWSER_IMAGE" npx playwright test ${FILTER:+--grep "$FILTER"} || status=$?

[ "$status" -eq 0 ] || docker logs "$name" >"$out/luci.log" 2>&1
exit "$status"
