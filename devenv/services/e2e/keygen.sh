#!/bin/sh
# Throwaway keys, one pair per node and interface, shared through a volume that
# lives only as long as the stack.
set -e
cd /keys
for node in hub spoke-a spoke-b; do
	for iface in wg_hub wg_mesh; do
		[ -s "$node.$iface.key" ] && continue
		wg genkey >"$node.$iface.key"
		wg pubkey <"$node.$iface.key" >"$node.$iface.pub"
	done
done
