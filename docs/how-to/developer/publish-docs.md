# How to Publish the Documentation

The documentation is published once per minor release, with [mike](https://github.com/jimporter/mike), to the `gh-pages` branch: `/0.1/`, `/0.2/` and so on, plus `/latest/` for the newest. Only the newest release is maintained. Older versions stay online, frozen at their last publish, and documentation for unreleased work is never published.

You do not run the publish yourself. The `docs` workflow (`.github/workflows/docs.yml`) does, when a release tag or a docs branch is pushed.

---

## What publishes

| Push | Publishes | Notes |
| :--- | :--- | :--- |
| Release tag `vX.Y.Z` | version `X.Y`, titled `X.Y.Z` | A patch release overwrites its minor. |
| Branch `docs/X.Y` | version `X.Y`, titled after its newest `vX.Y.*` tag | Only if the branch is docs-only (see [the guard](#the-docs-only-guard)). |
| `main`, pull requests | nothing | A strict build with `mkdocs.yml` and with `mkdocs.mike.yml`, and `make -C docs test`. |
| Manual run (**Actions → docs → Run workflow**) | the tag or `docs/X.Y` branch you enter | Use it to retry a failed publish. |

In every case `latest` moves to `X.Y` only if `X.Y` is the newest minor already on `gh-pages` (compared with `sort -V`, so `0.10` is newer than `0.9`). Republishing an old version never takes `latest` away from a newer one. Only one publish runs at a time.

The published site looks like this:

| Path | Content |
| :--- | :--- |
| `/X.Y/` | One folder per minor, without a `v`: `0.9`, `0.10`. |
| `/latest/` | A copy of the newest minor. |
| `/` | Redirects to `/latest/`. |
| `/404.html` | Redirects an unversioned link, `/<site>/<path>`, to `/<site>/latest/<path>`, keeping the query and `#anchor`. Paths already under `latest/`, a version folder or `dev/` are left alone. Its source is `devenv/gh-pages/404.html`. |
| `/.nojekyll` | Tells GitHub Pages to serve the files as they are. |

Pages of an older version show a banner linking to the latest.

## Release a new minor version

1. Tag the release on `main` and push the tag. The tag publishes `/X.Y/` and moves `latest` to it:

    ```bash
    git tag v0.2.0
    git push origin v0.2.0
    ```

2. Create the docs branch for this minor from the tag and push it:

    ```bash
    git branch docs/0.2 v0.2.0
    git push origin docs/0.2
    ```

From now on, leave the previous branch, `docs/0.1`, alone. `/0.1/` stays as it was last published.

## Fix the docs of the released version

Docs fixes always land on `main` first. If a fix also applies to the released version, cherry-pick it onto the docs branch and push; `/X.Y/` updates:

```bash
git checkout docs/0.2
git cherry-pick <sha>
git push origin docs/0.2
```

Never rebase or merge `main` into `docs/X.Y`: that would publish the docs of features that are not released yet. Only fix the docs branch of the newest minor; older versions stay frozen.

## Release a patch version

1. Tag and push the patch release, `v0.2.1`. It republishes `/0.2/`, titled `0.2.1`.
2. Move the docs branch to the tag and push it. A fast-forward works when the branch has no fixes of its own; otherwise merge:

    ```bash
    git checkout docs/0.2
    git merge --ff-only v0.2.1 || git merge v0.2.1
    git push origin docs/0.2
    ```

## The docs-only guard

On a push to `docs/X.Y`, `devenv/scripts/docs-guard.sh` refuses to publish unless:

- the branch has a release tag `vX.Y.*` (the newest one, by version, is used),
- that tag is an ancestor of the branch, and
- the branch differs from that tag only under `docs/` and in `mkdocs.yml` and `mkdocs.mike.yml`.

A code change fails the publish with:

```
docs/0.2 changes files outside docs/: src/wgpathd/daemon.uc; code fixes need a release
```

Code fixes need a release. Drop the commit from the branch; the fix ships in the next tag.

The guard runs locally too, from the repository root on the docs branch:

```bash
git checkout docs/0.2
devenv/scripts/docs-guard.sh docs/0.2
```

## Link to the documentation

- **Always current** places, such as the README, the repository homepage or a forum post, link to `/latest/...`.
- **Release-bound** places link to the pinned minor, `/X.Y/...`: CHANGELOG entries, release notes, and every URL in the shipped package (`files/`, `src/`, `openwrt/wgpathd/Makefile`), so an installed version links to its own docs.
- Links between pages of the documentation stay relative.

`make lint` checks the pinned links, using `site_url` from `mkdocs.yml` as the base: in shipped files they must use the package's current minor (`PKG_VERSION` in `openwrt/wgpathd/Makefile`), and in `CHANGELOG.md` the minor of the section they are in. When you bump the minor, update the pinned links in shipped files in the same change.

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/): one `## [X.Y.Z] - YYYY-MM-DD` section per release, newest first, and `## [Unreleased]` on top. Pinned links under `[Unreleased]` fail the check; pin them when the section gets its version.

While `site_url` is unset, there is nothing to check and `make lint` passes.

## Build and test locally

```bash
make -C docs build-mike   # strict build with mkdocs.mike.yml
make -C docs test         # tests of the publishing scripts and the 404 redirect
```

`make -C docs build` and `serve` keep using the plain `mkdocs.yml`, without versions. See [Make targets](../../reference/make-targets.md).

## One-time setup

Nothing is published until these are done, in this order:

1. Add the GitHub remote and push `main`.
2. Set `site_url` in `mkdocs.yml` to the site's base URL without a version, for example `https://<user>.github.io/wgpathd/`, and point the package's `URL:=` in `openwrt/wgpathd/Makefile` to the pinned docs, `https://<user>.github.io/wgpathd/0.1/`. Link the README to `/latest/`. Run `make lint`.
3. Push the first release tag, `v0.1.0`. The `docs` workflow creates `gh-pages` and publishes `/0.1/` and `/latest/`.
4. In the repository's **Settings → Pages**, set the source to **Deploy from a branch**, branch `gh-pages`, folder `/ (root)`.
5. Create and push `docs/0.1` from `v0.1.0`, as in [Release a new minor version](#release-a-new-minor-version).

If `gh-pages` ever carries files from an unversioned deploy (`mkdocs gh-deploy`), delete them from its root once: they would shadow the 404 redirect and keep serving stale pages.
