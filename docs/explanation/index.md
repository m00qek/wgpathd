# Explanation

Explanation is understanding-oriented. These pages discuss why wgpathd works the way it does. Read them away from the terminal.

---

- [About wgpathd](about.md) - Direct and relay paths, data plane versus control plane, and what wgpathd deliberately does not do.
- [About the Path State Machine](state-machine.md) - Evidence, trial proof, fast-down/slow-up hysteresis, backoff, roaming, and observe versus steer.
- [About Discovery](discovery.md) - How the hub knows each spoke's IPv6 endpoint, and why discovery is soft state.
- [Trust Model](trust-model.md) - The untrusted hub, the endpoints-only scope, and the locally configured relay floor.
- [Architecture](architecture.md) - The pure decision core, the thin I/O shell, and what one cycle does.
- [About Versioned Documentation](versioned-docs.md) - One published version per minor, one maintained, docs-only branches, pinned links, and the trade-offs.

For the complete rationale, including the failure-mode catalog, see the [design record](../design.md).
