# How to Set Up Documentation Publishing

Nothing is published until the repository is on GitHub, the site's URL is known, and the first release is tagged. Do these steps once, in this order. The examples use `https://<user>.github.io/wgpathd/` as the site's URL and `0.1.0` as the first release.

## Prerequisites

- A GitHub repository for wgpathd, with admin rights to change its Pages settings.
- The first release, `0.1.0`, is ready on `main`: `PKG_VERSION:=0.1.0` in `openwrt/wgpathd/Makefile`.

---

## 1. Push `main`

```bash
git remote add origin git@github.com:<user>/wgpathd.git
git push -u origin main
```

## 2. Set the site's URL and pin the links

1. In `mkdocs.yml`, set `site_url` to the site's base URL, without a version:

    ```yaml
    site_url: https://<user>.github.io/wgpathd/
    ```

2. In `openwrt/wgpathd/Makefile`, point `URL:=` to the docs of the package's minor:

    ```makefile
    URL:=https://<user>.github.io/wgpathd/0.1/
    ```

3. Link the README to `https://<user>.github.io/wgpathd/latest/`.

4. Check the pinned links:

    ```bash
    make lint
    ```

Commit the change and push it to `main`. Which link goes where is in [Links to the documentation](../../reference/docs-publishing.md#links-to-the-documentation).

## 3. Tag the first release

```bash
git tag v0.1.0
git push origin v0.1.0
```

The `docs` workflow creates `gh-pages` and publishes `/0.1/` and `/latest/`. Wait for its `publish` job to succeed.

## 4. Turn on GitHub Pages

In the repository's **Settings → Pages**, set the source to **Deploy from a branch**, branch `gh-pages`, folder `/ (root)`. The site then answers at `https://<user>.github.io/wgpathd/`, which redirects to `/latest/`.

## 5. Create the docs branch

```bash
git branch docs/0.1 v0.1.0
git push origin docs/0.1
```

Doc fixes for 0.1 go through this branch: see [How to fix the docs of the released version](fix-released-docs.md).

---

## Clear an unversioned deploy from `gh-pages`

If `gh-pages` carries files from an earlier unversioned deploy, for example from `mkdocs gh-deploy`, remove them once: they shadow the [404 redirect](../../reference/docs-publishing.md#404-redirect) and keep serving stale pages. Do it while no `docs` workflow is running.

1. Check out `gh-pages` and list its root:

    ```bash
    git fetch origin gh-pages
    git switch gh-pages
    git ls-tree --name-only HEAD
    ```

2. Remove everything that is not part of the [versioned layout](../../reference/docs-publishing.md#site-layout): the version folders, `latest`, `versions.json`, `index.html`, `404.html` and `.nojekyll` stay.

    ```bash
    git ls-tree --name-only HEAD |
        grep -vxE '[0-9]+\.[0-9]+|latest|versions\.json|index\.html|404\.html|\.nojekyll' |
        xargs git rm -r -q
    git commit -m 'Remove the unversioned site'
    git push origin gh-pages
    git switch main
    ```

If `gh-pages` has not been published with mike yet, publish first (step 3), so that `index.html` is mike's redirect and not the old site's home page.
