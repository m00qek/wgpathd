# How to Republish a Version

Republish a version when its publish failed or was cancelled, or when `gh-pages` lost it. The `docs` workflow can be run by hand for any release tag or docs branch. The examples republish `0.2`.

---

## 1. Choose the ref

- If the minor has a docs branch, use it: `docs/0.2`. It holds the release plus its doc fixes.
- Otherwise use the minor's newest release tag, for example `v0.2.1`.

Republishing an older tag than the newest, or a tag instead of the branch, replaces `/0.2/` with older docs.

## 2. Run the workflow

In the repository, open **Actions → docs → Run workflow**, enter the ref, and run it. With the GitHub CLI:

```bash
gh workflow run docs.yml -f ref=docs/0.2
```

Republishing an older minor leaves `latest` on the newest one. A docs branch still has to pass the [docs-only guard](../../reference/docs-publishing.md#docs-only-guard); if it refuses, see [How to fix the docs of the released version](fix-released-docs.md#if-the-guard-refuses).
