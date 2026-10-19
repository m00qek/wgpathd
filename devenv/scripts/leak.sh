#!/bin/sh
# Runs inside the openwrt container: memory each component keeps per use.
cd "$(dirname "$0")/../.."
exec ucode -L "$PWD/src" test/leak/leak.uc
