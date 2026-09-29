# Reference

Reference documentation is technical description of the machinery. It is information-oriented: consult it, don't read it end to end.

---

## Configuration
- [UCI Configuration](uci-config.md) - Every option in `/etc/config/wgpathd`, per role, the `peer` sections of a spoke with the unmanaged reasons, and validation rules.
- [WireGuard Substrate](substrate.md) - What wgpathd reads from `/etc/config/network`, and what it needs of the WireGuard setup.
- [Timing Parameters](parameters.md) - Every timing parameter, its default and exact behavior, plus the fixed limits.

## Interfaces
- [Service Commands](service-commands.md) - `service wgpathd start`, `reload`, `status` and `check`: behavior, output and exit status.
- [ubus Status](ubus-status.md) - The `wgpathd` ubus object, field by field, for spoke and hub.
- [ubus Config Check](ubus-config-check.md) - The `wgpathd.config` ubus object: the configuration check for saved or unsaved values, the mesh peers without their keys, and the parameter bounds.
- [Discovery HTTP API](discovery-api.md) - `GET /peers`: payload, status codes, connection limits and spoke-side validation.

## Diagnostics
- [Log Messages](log-messages.md) - Every message, its level and what it means.
- [Error Codes](error-codes.md) - Every error code and its details.

## Package
- [Firewall Rules](firewall.md) - What each role needs the firewall to accept and why, and what the check can confirm. The package ships no rules.
- [Files and Dependencies](files.md) - Installed files, runtime files, the init script, package scripts and dependencies.
- [Make Targets](make-targets.md) - Development targets and variables.
- [Documentation Publishing](docs-publishing.md) - The `docs` workflow, the `gh-pages` layout, the `latest` rule, the docs-only guard, the link check and the scripts behind them.
