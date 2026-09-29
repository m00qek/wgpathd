# Documentation Publishing

The documentation is published with [mike](https://github.com/jimporter/mike) to the `gh-pages` branch, one version per minor release, by the `docs` workflow in `.github/workflows/docs.yml`. The make targets that build and test it locally are in [Make targets](make-targets.md#docsmakefile). For the reasons behind this design, see [About versioned documentation](../explanation/versioned-docs.md).

---

## Triggers

| Event | Ref | Job | Publishes | Version title |
| :--- | :--- | :--- | :--- | :--- |
| Push of a tag | `v[0-9]+.[0-9]+.[0-9]+`, for example `v0.2.1` | `publish` | version `X.Y` | `X.Y.Z`, the tag without its `v` |
| Push to a branch | `docs/[0-9]+.[0-9]+`, for example `docs/0.2` | `publish` | version `X.Y`, if the [docs-only guard](#docs-only-guard) passes | the newest `vX.Y.*` tag without its `v` |
| Push to a branch | `main` | `build` | nothing | — |
| Pull request | into `main` | `build` | nothing | — |
| Manual run (`workflow_dispatch`) | the input `ref`: a release tag `vX.Y.Z` or a branch `docs/X.Y` | `publish` | as for a push of that ref | as for a push of that ref |

Branch pushes and pull requests start the workflow only when they change at least one of these paths. Tag pushes and manual runs always start it.

- `docs/**`
- `mkdocs.yml`, `mkdocs.mike.yml`
- `devenv/gh-pages/**`
- `devenv/scripts/docs-*.sh`
- `devenv/services/docs/**`
- `test/docs/**`
- `.github/workflows/docs.yml`

Nothing else publishes: `main`, pull requests and pre-release tags such as `v0.3.0-rc1` never reach `gh-pages`.

## Jobs

### `build`

Runs on pull requests and on pushes to `main`.

1. `make -C docs build`: strict build with `mkdocs.yml`.
2. `make -C docs build-mike`: strict build with `mkdocs.mike.yml`.
3. `make -C docs test`: the tests in `test/docs/`.

### `publish`

Runs on release tags, `docs/*` branches and manual runs. `REF` is the manual run's `ref` input, or else the pushed ref.

1. Checks out `REF` with its full history and tags.
2. Installs Python 3.12 and `devenv/services/docs/requirements.txt` with `pip`.
3. Sets the git committer to `github-actions[bot]`.
4. `mkdocs build --strict --config-file mkdocs.mike.yml`.
5. `devenv/scripts/docs-publish.sh "$REF"`.

### Permissions and concurrency

| Setting | Value |
| :--- | :--- |
| Workflow permissions | `contents: read` |
| `publish` permissions | `contents: write` |
| `publish` concurrency group | `gh-pages`, with `cancel-in-progress: false` |

One `publish` job runs at a time; a later one waits. GitHub keeps at most one waiting job per concurrency group: a newer one cancels the one already waiting.

## The latest rule

A publish of version `X.Y` also points `latest` to `X.Y`, and makes `latest` the default version, only if `X.Y` is the newest of the version folders already on `gh-pages` together with `X.Y` itself, compared with `sort -V`: `0.10` is newer than `0.9`. Otherwise `latest` stays where it is. The first publish always takes `latest`.

The script prints which case applied:

```
publishing 0.10 (0.10.0) as latest
publishing 0.9 (0.9.1); latest stays on 0.10
```

## Site layout

The published site on `gh-pages`:

| Path | Written by | Content |
| :--- | :--- | :--- |
| `/X.Y/` | mike | One folder per minor, without a `v`: `0.9`, `0.10`. |
| `/latest/` | mike | A full copy of the newest minor's folder (`alias_type: copy`), not a symlink or a redirect. |
| `/versions.json` | mike | The versions, their titles and aliases, for the version selector. |
| `/index.html` | mike | Redirects to `/latest/` (`mike set-default latest`). |
| `/404.html` | `docs-publish.sh` | Copy of `devenv/gh-pages/404.html`. See [below](#404-redirect). |
| `/.nojekyll` | `docs-publish.sh` | Empty. Tells GitHub Pages to serve the files as they are. |

Every page carries a version selector. With `site_url` set, its canonical URL is the same page under `/latest/` (`canonical_version: latest`). Pages of a version that is not `latest` show a banner, `docs/overrides/main.html`:

> You are reading the documentation of an older release. **Go to the latest.**

The link goes to the site's root, which redirects to `/latest/`.

### 404 redirect

GitHub Pages serves `/404.html` for every missing path. Its script redirects `/<site>/<path>` to `/<site>/latest/<path>`, keeping the query string and the `#anchor`. `/<site>` and `/<site>/` go to `/<site>/latest/`.

It does not redirect, and shows "Page not found", when the first segment after `/<site>/` is `latest`, `dev` or a version `X.Y`, or when the path is `/`. The first path segment is always taken as the site, so the redirect works only on a project site, `https://<user>.github.io/<site>/`.

## Docs-only guard

`devenv/scripts/docs-guard.sh` runs before every publish of a `docs/X.Y` branch, whether pushed or run manually. It does not run for release tags. It checks the checked-out commit, `HEAD`, against the release tag of its minor:

1. The tag is the newest tag of the form `vX.Y.Z` with the branch's `X.Y`, by `sort -V`: `v0.9.10` is newer than `v0.9.9`. Other tags, such as `v0.9.11-rc1`, are ignored.
2. The tag must be an ancestor of `HEAD`.
3. `HEAD` may differ from the tag only in these files: anything under the top-level `docs/`, `mkdocs.yml`, `mkdocs.mike.yml`. A `docs/` folder anywhere else, such as `src/docs/`, does not count.

On success the guard prints the tag, which becomes the version's title. On failure it prints one of these messages on stderr, exits 1, and nothing is published:

| Message | Cause |
| :--- | :--- |
| `not a docs/X.Y branch: <ref>` | The first argument is not a `docs/` branch. |
| `not a release tag vX.Y.Z or a docs/X.Y branch: <ref>` | The branch is `docs/` but not `docs/X.Y`. |
| `docs/X.Y has no vX.Y.* release tag` | No release tag of that minor exists. |
| `<tag> is not a X.Y release` | The tag given as the second argument is of another minor. |
| `not a release tag: <tag>` | The second argument does not start with `v`. |
| `<tag> is not an ancestor of docs/X.Y` | The branch does not contain its newest release tag, for example after a patch release it has not moved to. |
| `docs/X.Y changes files outside docs/: <files>; code fixes need a release` | The branch changes other files than the docs. The files are listed, space-separated. |

For example:

```
docs/0.2 changes files outside docs/: src/wgpathd/daemon.uc; code fixes need a release
```

To run it locally, check out the branch, make sure the release tags are fetched, and pass the branch name:

```bash
devenv/scripts/docs-guard.sh docs/0.2
```

## Links to the documentation

| Where the link is | It points to |
| :--- | :--- |
| Always-current places: the README, the repository's homepage, forum posts | `<site_url>latest/...` |
| `CHANGELOG.md` | `<site_url>X.Y/...`, the minor of the section the link is in |
| Release notes | `<site_url>X.Y/...`, the minor of the release |
| Shipped files: everything under `files/` and `src/`, and `openwrt/wgpathd/Makefile` (including `URL:=`) | `<site_url>X.Y/...`, the package's current minor |
| Pages of the documentation | Relative paths, never the site's URL |

`site_url` is the site's base URL without a version, set in `mkdocs.yml`, for example `https://<user>.github.io/wgpathd/`.

### Link check

`make lint` runs `devenv/scripts/docs-links.sh`, which checks every pinned link, `<site_url><X.Y>/`, in the shipped files and in `CHANGELOG.md`:

- `site_url` is read from `mkdocs.yml`, with or without quotes; a missing trailing `/` is added. While `site_url` is unset, nothing is checked and the check passes.
- In shipped files the minor must be the one of `PKG_VERSION` in `openwrt/wgpathd/Makefile`: `PKG_VERSION:=0.1.0` requires `0.1`.
- In `CHANGELOG.md` the minor must be the one of the enclosing `## [X.Y.Z]` heading. Any other `## ` heading, such as `## [Unreleased]`, and the text before the first `## ` heading allow no pinned link at all. `###` headings do not change the section.
- Links to `latest/` and links under other URLs are not checked.

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/): `## [Unreleased]` on top, then one `## [X.Y.Z] - YYYY-MM-DD` section per release, newest first. Only the `## [X.Y.Z]` part of the heading is read.

A failure prints every wrong link and exits 1:

```
pinned docs links to the wrong version:
files/etc/config/wgpathd:1: https://example.org/wgpathd/0.9/ (expected 0.10)
CHANGELOG.md:5: https://example.org/wgpathd/0.10/ (outside a release section)
```

## Files and scripts

| File | Role |
| :--- | :--- |
| `.github/workflows/docs.yml` | The `docs` workflow: [triggers](#triggers), [jobs](#jobs). |
| `mkdocs.yml` | The site. Has no mike settings; `make -C docs build` and `serve` use it. |
| `mkdocs.mike.yml` | The versioned site: inherits `mkdocs.yml` and adds the `search` and `mike` plugins (`canonical_version: latest`, `alias_type: copy`), the version selector (`extra.version.provider: mike`) and the theme overrides in `docs/overrides/`. Used by `build-mike` and by the `publish` job. |
| `docs/overrides/main.html` | The outdated-version banner. |
| `devenv/gh-pages/404.html` | The [404 redirect](#404-redirect), copied to the root of `gh-pages` on every publish. |
| `devenv/services/docs/Dockerfile` | The docs tools image, `wgpathd-docs`: the mkdocs-material image plus `requirements.txt`, git, coreutils and Node. |
| `devenv/services/docs/requirements.txt` | Pinned mkdocs-material and mike, for the tools image and the `publish` job. |
| `devenv/scripts/docs-version.sh` | Maps a ref to its docs version. |
| `devenv/scripts/docs-guard.sh` | The [docs-only guard](#docs-only-guard). |
| `devenv/scripts/docs-publish.sh` | Publishes one version. |
| `devenv/scripts/docs-links.sh` | The [link check](#link-check). |
| `test/docs/` | Tests of the four scripts and of the 404 redirect, run by `make -C docs test`. |

### `docs-version.sh REF`

Prints the version `X.Y` of a release tag `vX.Y.Z` or of a branch `docs/X.Y`. `REF` may carry a `refs/tags/` or `refs/heads/` prefix. Anything else prints `not a release tag vX.Y.Z or a docs/X.Y branch: REF` on stderr and exits 1.

```
$ devenv/scripts/docs-version.sh refs/tags/v0.10.2
0.10
```

### `docs-guard.sh BRANCH [TAG]`

Checks `HEAD` as the tip of `BRANCH`, `docs/X.Y` with an optional `refs/heads/` prefix, against `TAG`, by default the newest `vX.Y.Z` tag of that minor. See [Docs-only guard](#docs-only-guard). Prints the tag and exits 0, or prints a message on stderr and exits 1.

### `docs-publish.sh REF`

Publishes the current checkout as version `X.Y` of `REF`, a release tag or a `docs/X.Y` branch, with an optional `refs/` prefix, to `origin`'s `gh-pages`. Run from the repository root, with `mike` installed and a git committer configured.

1. Maps `REF` to its version with `docs-version.sh`. For a `docs/` branch, runs `docs-guard.sh` and takes the title from the tag it prints; for a tag, the title is the tag. The leading `v` is dropped.
2. Fetches `gh-pages` from `origin` into the local `gh-pages` branch, if it exists there.
3. Applies [the latest rule](#the-latest-rule): `mike deploy -F mkdocs.mike.yml --title <title> --update-aliases X.Y latest` and `mike set-default -F mkdocs.mike.yml latest`, or only `mike deploy -F mkdocs.mike.yml --title <title> X.Y`.
4. Writes `404.html` and `.nojekyll` to the root of `gh-pages`, in a separate commit, `Root files: 404 redirect to latest, .nojekyll`, only if they changed.
5. Pushes `gh-pages` to `origin`.

It exits non-zero, before anything is pushed, if `REF` is not a release tag or a docs branch, or if the guard refuses.

### `docs-links.sh [ROOT]`

Runs the [link check](#link-check) on the repository at `ROOT`, by default the one the script is in. Exits 0 when every pinned link is right or `site_url` is unset, 1 otherwise.

## Pinned versions

| Tool | Version | Pinned in |
| :--- | :--- | :--- |
| mkdocs-material image | `squidfunk/mkdocs-material:9.5.17` | `MKDOCS_IMAGE` in `docs/Makefile` |
| mkdocs-material | `9.5.17` | `devenv/services/docs/requirements.txt` |
| mike | `2.1.3` | `devenv/services/docs/requirements.txt` |
| Docs tools image | `wgpathd-docs:9.5.17`, tag taken from `MKDOCS_IMAGE` | `docs/Makefile` |
| Python (`publish` job) | `3.12` | `.github/workflows/docs.yml` |
| `actions/checkout`, `actions/setup-python` | `v4`, `v5` | `.github/workflows/docs.yml` |

The `publish` job installs the requirements with `pip` on the runner and does not use the docs tools image. The dependencies of mkdocs-material and mike are not pinned there.
