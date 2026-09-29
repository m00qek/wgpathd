# How to Write Documentation

The documentation is built with MkDocs Material, inside Docker. You need Docker and `make`.

---

## Preview while you write

```bash
make -C docs serve
```

Open `http://localhost:8000`. The page reloads when you save a file under `docs/` or change `mkdocs.yml`. `make docs-serve` from the repository root does the same. If port 8000 is taken, for example by another project's preview, choose another: `make -C docs serve DOCS_PORT=8001`.

## Build the site

```bash
make -C docs build
```

`make docs` from the repository root does the same. The site goes to `bin/site/`, and `make -C docs clean` removes it.

The build runs `mkdocs build --strict`, so a broken link or any other warning fails it. CI runs the same strict build on pushes and pull requests to `main` that touch the docs, and a second one with the versioned config, `mkdocs.mike.yml` (`make -C docs build-mike` locally).

Merging to `main` publishes nothing: the docs go online with the next release. To correct the docs already online, see [How to fix the docs of the released version](fix-released-docs.md); what publishes when is in [Documentation publishing](../../reference/docs-publishing.md).

## Where a page goes

Pick the folder by what the reader is doing, following [Diátaxis](https://diataxis.fr/):

| Folder | The reader is... | Example |
| :--- | :--- | :--- |
| `tutorials/` | learning by doing, guided step by step | Developer onboarding |
| `how-to/` | working toward a goal they already have | Configure a spoke |
| `reference/` | looking up a fact | Every status field |
| `explanation/` | trying to understand why | The state machine |

Keep one type per page and link to the others instead of mixing them. Add every new page to `nav` in `mkdocs.yml` and to the `index.md` of its folder. Link between pages with relative paths, never with the site's URL, so each published version links to itself.

the design record and the build history are project records. Link to them for deep rationale; do not edit them to match the user docs.

## Keep it true

Reference pages describe the code as it is. When you change an option, parameter, status field, log message, error code, HTTP behavior or installed file, update the matching reference page in the same change:

| Code | Reference page |
| :--- | :--- |
| `config.uc`, `files/etc/config/wgpathd` | [UCI configuration](../../reference/uci-config.md), [Substrate annotations](../../reference/substrate.md) |
| `params.uc` | [Timing parameters](../../reference/parameters.md) |
| `daemon.uc` status | [ubus status](../../reference/ubus-status.md) |
| `publisher.uc`, `discovery.uc` | [Discovery HTTP API](../../reference/discovery-api.md) |
| `deps.log(...)` calls | [Log messages](../../reference/log-messages.md) |
| `errors.uc` | [Error codes](../../reference/error-codes.md) |
| `files/etc/init.d/wgpathd`, `check.uc`, `status_view.uc`, daemon reload | [Service commands](../../reference/service-commands.md) |
| `files/`, `openwrt/wgpathd/Makefile` | [Files and dependencies](../../reference/files.md), [Firewall rules](../../reference/firewall.md) |
| root `Makefile` | [Make targets](../../reference/make-targets.md) |
| `docs/Makefile`, `devenv/scripts/docs-*.sh`, `.github/workflows/docs.yml`, `mkdocs.mike.yml`, `docs/overrides/`, `devenv/gh-pages/`, `devenv/services/docs/` | [Make targets](../../reference/make-targets.md), [Documentation publishing](../../reference/docs-publishing.md) |

## Diagrams and examples

- Use Mermaid in a fenced block with the `mermaid` language. Add a diagram only where a picture explains more than a paragraph.
- Use generic names (hub, spoke-a, spoke-b) and documentation addresses: `2001:db8::/32` for IPv6, `192.0.2.0/24`, `198.51.100.0/24` and `203.0.113.0/24` for public IPv4. Never use real site names, keys or public addresses.
- Output captured from the e2e lab is the exception: paste it as it is. Its private addresses and keys are disposable and match what the reader sees when they run the lab.
