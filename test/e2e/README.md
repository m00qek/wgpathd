# e2e — network failover suite

Real OpenWrt nodes (procd as PID 1, netifd, fw4, rpcd, logd, kernel WireGuard)
running the built package, driven from the host with `docker exec`. See
`docs/how-to/developer/testing.md`; the failures the scenarios reproduce are
explained in `docs/explanation/state-machine.md` ("When things fail").

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
| `baseline` | both DIRECT, cross-site ping, status/check/discovery, the firewall rules the check confirms |
| `kill-direct` | direct dies → both RELAY, traffic survives via the hub; restore → DIRECT |
| `mtu-blackhole` | the direct path drops full-size packets only → both RELAY on the full-size tunnel probe, full-size traffic crosses via the hub; restore → DIRECT |
| `anchor-only` | spoke-b unreachable → both DIRECT (the anchor promotes on roams) |
| `anchor-traffic` | spoke-b unreachable, 100–1000 packets/s from either site, both daemons restarted → both still DIRECT, only answers from the target commit |
| `relay-traffic` | direct dead, relay traffic from spoke-a → it keeps crossing, spoke-b's answers over the relay are refused (`relayed_answers`), it is never committed, its backoff grows; giving up is off here, so trials go on |
| `direct-filtered` | direct UDP filtered, ICMPv6 answers → 3 trial timeouts, the address given up, no more trials and no gaps in relayed traffic; filter lifted → nothing until a new address (spoke-a) and a roam (spoke-b) resume, both DIRECT; again with a short pause → resumed when it is over |
| `crash` | `kill -9` → procd respawn → RELAY → DIRECT |
| `hang` | `kill -STOP` → procd watchdog restart → RELAY → DIRECT |
| `neither-reachable` | no anchor → both stay RELAY |
| `one-way` | direct loss in one direction → never promoted, both give the address up |
| `roam` | spoke-b changes its v6 → spoke-a follows |
| `recreate` | netifd creates spoke-b's wg_mesh again with a stale configured endpoint for spoke-a → not taken for a roam, the direct endpoint asserted again, spoke-b stays DIRECT, both back on the direct path |
| `hub-down` | hub dark → direct sessions survive, a roam is still followed |
| `mixed` | one side DIRECT, the other held by backoff → no ping loss |
| `observe` | observe mode → relay endpoints only, `ready` reported |

The same topology can be left running as a lab, with the substrate in place
and wgpathd installed but disabled, for `docs/tutorials/first-failover.md`:

```bash
make lab-up                                # guards on, nodes up, wgpathd disabled
make lab-shell NODE=spoke-a                # a login shell on a node
make lab-fault NAME=kill-direct            # the kill-direct fault; NAME=restore clears it
make lab-down                              # always: tear down, stop the guards, host report
```

`../../devenv/scripts/lab.sh` runs it as compose project `wgpathd-lab` with the
runner's host guards (`../../devenv/scripts/host-guard.sh`); the watchdog runs
detached until `make lab-down`. The lab and the suite refuse to start while the
other runs. Guard logs land in `bin/lab/`.

Output lands in `bin/e2e/`: `results.tsv`, `timings.tsv`, per-failure node
diagnostics, and the host guard's logs (`ip-monitor.log`, `kernel.log`,
`sysctl.before`/`sysctl.after`).
