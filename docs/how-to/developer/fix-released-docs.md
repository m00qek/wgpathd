# How to Fix the Docs of the Released Version

A docs fix reaches the published site through the docs branch of the newest minor, `docs/X.Y`: pushing the branch republishes `/X.Y/`. Only the newest minor gets fixes; older versions stay as they are. The examples fix `0.2`.

## Prerequisites

- The fix is merged into `main`. Fixes always land on `main` first.
- The fix changes only files under `docs/`, `mkdocs.yml` or `mkdocs.mike.yml`. A code fix needs a release instead: [How to publish the docs of a patch release](publish-patch-docs.md).

---

## 1. Cherry-pick the fix onto the docs branch

```bash
git fetch origin --tags
git switch docs/0.2
git cherry-pick <sha>
```

Cherry-pick each commit you need. Never merge or rebase `main` into `docs/0.2`: it would publish the docs of unreleased work ([why](../../explanation/versioned-docs.md#why-fixes-go-to-main-first-and-why-never-rebase)).

If a commit also changes files outside the docs, take only its docs part:

```bash
git cherry-pick -n <sha>
git restore --source=HEAD --staged --worktree -- . ':!docs/' ':!mkdocs.yml' ':!mkdocs.mike.yml'
git commit -C <sha>
```

## 2. Check the branch

```bash
devenv/scripts/docs-guard.sh docs/0.2
```

It prints the release tag when the branch may publish. If it refuses, see [below](#if-the-guard-refuses).

## 3. Push

```bash
git push origin docs/0.2
```

The `docs` workflow republishes `/0.2/`. Check that its `publish` job succeeded.

---

## If the guard refuses

The message tells you which case you are in; every message is listed in [Docs-only guard](../../reference/docs-publishing.md#docs-only-guard).

- **`docs/0.2 changes files outside docs/: <files>; code fixes need a release`**: a commit on the branch changes code. If you have not pushed yet, drop it with `git reset --hard origin/docs/0.2` and cherry-pick again as in step 1. If it is already pushed, revert it and push the revert:

    ```bash
    git revert <sha>
    git push origin docs/0.2
    ```

    The code fix ships with the next release.

- **`v0.2.1 is not an ancestor of docs/0.2`**: a patch release was tagged and the branch has not moved to it. Move it as in [How to publish the docs of a patch release](publish-patch-docs.md#2-move-the-docs-branch-to-the-tag), then push again.

- **`docs/0.2 has no v0.2.* release tag`**: the tags are missing locally. Run `git fetch origin --tags`. In CI, the minor has not been released yet, and the branch should not exist.
