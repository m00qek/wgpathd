# Reference

Reference documentation is technical description of the machinery. It is information-oriented: consult it, don't read it end to end.

---

## Configuration
- [UCI Configuration](uci-config.md) - Every option in `/etc/config/wgpathd`, per role, with validation rules.
- [Substrate Annotations](substrate.md) - The per-peer options wgpathd reads from `/etc/config/network`, and the unmanaged reasons.
- [Timing Parameters](parameters.md) - Every timing parameter, its default and exact behavior, plus the fixed limits.

## Interfaces
- [Service Commands](service-commands.md) - `service wgpathd start`, `reload`, `status` and `check`: behavior, output and exit status.
- [ubus Status](ubus-status.md) - The `wgpathd` ubus object, field by field, for spoke and hub.
- [Discovery HTTP API](discovery-api.md) - `GET /peers`: payload, status codes, connection limits and spoke-side validation.

## Diagnostics
- [Log Messages](log-messages.md) - Every message, its level and what it means.
- [Error Codes](error-codes.md) - Every error code and its details.

## Package
- [Firewall Rules](firewall.md) - The shipped fw4 include, rule by rule.
- [Files and Dependencies](files.md) - Installed files, runtime files, the init script, package scripts and dependencies.
- [Make Targets](make-targets.md) - Development targets and variables.
