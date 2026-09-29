# How to Publish the Docs of a Patch Release

A patch release, such as `0.2.1`, republishes its minor, `/0.2/`, from the new tag. Afterwards the docs branch has to move onto the tag, or it cannot publish again. The examples release `0.2.1`.

## Prerequisites

- The minor's docs branch exists: [How to publish the docs of a new minor release](publish-minor-docs.md).
- The release is ready, with `PKG_VERSION:=0.2.1` in `openwrt/wgpathd/Makefile`, and `make lint` passes.

---

## 1. Tag the release

```bash
git tag v0.2.1
git push origin v0.2.1
```

The `docs` workflow republishes `/0.2/`, now titled `0.2.1`. `latest` follows if `0.2` is the newest minor.

## 2. Move the docs branch to the tag

```bash
git fetch origin
git switch docs/0.2
git merge --ff-only v0.2.1
```

If the fast-forward fails because the branch has fix commits of its own, merge the tag instead:

```bash
git merge v0.2.1
```

If the merge conflicts, keep the tag's side for every file outside `docs/`, `mkdocs.yml` and `mkdocs.mike.yml`: the branch may only differ from the tag in the docs.

Then push:

```bash
git push origin docs/0.2
```

Until the branch contains `v0.2.1`, every publish from it is refused with `v0.2.1 is not an ancestor of docs/0.2`. See [Docs-only guard](../../reference/docs-publishing.md#docs-only-guard).
