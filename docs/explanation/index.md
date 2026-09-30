# Explanation

Explanation is understanding-oriented. These pages discuss why wgpathd works the way it does. Read them away from the terminal.

---

- [Why wgpathd?](why.md) - What going direct buys, how wgpathd compares with the alternatives, and when to choose something else.
- [About wgpathd](about.md) - Direct and relay paths, data plane versus control plane, and what wgpathd deliberately does not do.
- [About the Path State Machine](state-machine.md) - Evidence, trial proof, fast-down/slow-up hysteresis, backoff, roaming, observe versus steer, and what happens when things fail.
- [About Discovery](discovery.md) - How the hub knows each spoke's IPv6 endpoint, and why discovery is soft state.
- [Trust Model](trust-model.md) - The untrusted hub, the endpoints-only scope, and the locally configured relay floor.
- [Architecture](architecture.md) - The pure decision core, the thin I/O shell, what one cycle does, and the invariants the tests check.
- [About Versioned Documentation](versioned-docs.md) - One published version per minor, one maintained, docs-only branches, pinned links, and the trade-offs.
