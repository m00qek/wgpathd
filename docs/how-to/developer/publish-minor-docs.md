# How to Publish the Docs of a New Minor Release

A new minor release, such as `0.2.0`, publishes its docs as `/0.2/` and moves `/latest/` to them. It also starts a new docs branch and freezes the previous one. The examples release `0.2.0` after `0.1`.

## Prerequisites

- Publishing is set up: [How to set up documentation publishing](setup-docs-publishing.md).
- The release is ready on `main`, with `PKG_VERSION:=0.2.0` in `openwrt/wgpathd/Makefile`.
- Every pinned docs link in the shipped files points to `/0.2/`, including `URL:=` in `openwrt/wgpathd/Makefile`. If the project keeps a `CHANGELOG.md`, the release's entries are under `## [0.2.0]`. `make lint` passes.

---

## 1. Tag the release

```bash
git tag v0.2.0
git push origin v0.2.0
```

The `docs` workflow publishes `/0.2/`, titled `0.2.0`, and moves `latest` to it. Check that its `publish` job succeeded and that `/latest/` shows `0.2.0` in the version selector.

## 2. Create the docs branch

```bash
git branch docs/0.2 v0.2.0
git push origin docs/0.2
```

## 3. Freeze the previous branch

Stop pushing to `docs/0.1`. `/0.1/` stays online as it was last published. From now on, doc fixes go to `docs/0.2`: see [How to fix the docs of the released version](fix-released-docs.md).

---

What each push publishes, and when `latest` moves, is in [Documentation publishing](../../reference/docs-publishing.md#triggers). Why only the newest minor gets fixes: [About versioned documentation](../../explanation/versioned-docs.md#one-version-per-minor-and-only-one-maintained).
