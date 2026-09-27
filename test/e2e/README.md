# e2e — network failover suite

Real OpenWrt nodes (procd as PID 1, netifd, fw4, rpcd, logd, kernel WireGuard)
running the built package, driven from the host with `docker exec`. See
the design record (E2E test harness) and `docs/how-to/developer/testing.md`.

```bash
make e2e                                   # every scenario
make e2e SCENARIO=kill-direct              # one (or several, space-separated)
```

- `../../devenv/scripts/e2e.sh` — the runner: host safety checks, `make package`,
  image build, one `up` for the whole run, convergence, scenarios, teardown.
- `../../devenv/e2e.compose.yaml`, `../../devenv/services/e2e/` — the topology:
  `hub`, `spoke-a` (anchor), `spoke-b` (roamer) on one internal docker network (IPv4 in docker, IPv6 from netifd).
- `lib.sh` — helpers: `docker exec`, status via `jsonfilter`, waits, the
  background ping, nftables faults in a table `inet e2e` beside fw4's.
- `<scenario>.sh` — one file per scenario, sourced in a subshell with `lib.sh`.
  Each starts from both spokes DIRECT; the runner undoes whatever it left behind
  (`restore_all`).

| Scenario | Proves |
| :--- | :--- |
| `baseline` | both DIRECT, cross-site ping, status/check/discovery/fw4 rules |
| `kill-direct` | direct dies → both RELAY, traffic survives via the hub; restore → DIRECT |
| `anchor-only` | spoke-b unreachable → both DIRECT (anchor promotes on roams, R2) |
| `crash` | `kill -9` → procd respawn → RELAY → DIRECT |
| `hang` | `kill -STOP` → procd watchdog restart (G2) → RELAY → DIRECT |
| `neither-reachable` | no anchor → both stay RELAY |
| `one-way` | direct loss in one direction → never promoted |
| `roam` | spoke-b changes its v6 → spoke-a follows |
| `hub-down` | hub dark → direct sessions survive, a roam is still followed |
| `mixed` | one side DIRECT, the other held by backoff → no ping loss |
| `observe` | observe mode → relay endpoints only, `ready` reported |

Output lands in `bin/e2e/`: `results.tsv`, `timings.tsv`, per-failure node
diagnostics, and the host guard's logs (`ip-monitor.log`, `kernel.log`,
`sysctl.before`/`sysctl.after`).
