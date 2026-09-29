# About Versioned Documentation

The documentation describes a package that people install and then keep running for months. A router on last year's release should be able to read the docs of last year's release, and a reader who just arrived should land on the newest. This page explains how the publishing setup serves both, and why it is stricter than it first looks. The machinery itself is described in [Documentation publishing](../reference/docs-publishing.md).

---

## One version per minor, and only one maintained

The site has a folder per minor release, `/0.1/`, `/0.2/`, and `/latest/` for the newest. Patch releases do not get their own folder; they overwrite their minor. A patch release changes behaviour in small ways at most, and a reader choosing between `0.2.0`, `0.2.1` and `0.2.2` in a version selector gains nothing but a longer list. The title of each version still shows the exact release it was built from.

wgpathd is a small project, and it maintains exactly one version: the newest. That shapes the docs too. Old versions stay online, because someone is running them, but they are frozen at their last publish. Only the newest version's docs get fixes. Backporting doc fixes to every old minor would be a promise the project cannot keep, and a half-kept promise is worse than a clear rule: a reader of `/0.1/` knows it is a record of 0.1, not a living page.

The other half of the rule is that the docs of unreleased work are never published. `main` often describes behaviour no release has yet. Publishing it, even under a `dev` label, would put the most visible, most search-indexed pages ahead of the code people can actually install. So `main` and pull requests only build the site, strictly, to catch broken links early; they never publish it. The docs go online with the release they describe.

## Why the docs branches exist

A release tag is immutable, and so are the docs inside it. But the docs of a release will have mistakes: a typo, a wrong default, a missing step. Waiting for the next release to fix them leaves readers with the error for weeks, and cutting a release just for a doc fix spends a version number on something that is not a change to the package.

A `docs/X.Y` branch is the way out. It starts at the release tag, `vX.Y.0`, and carries doc fixes on top of it. Pushing it republishes `/X.Y/`. The branch is not a release branch and never becomes one: it exists only to let the published docs of a released version get better without a new release.

## Why the branch must stay docs-only

The danger of a branch that sits next to a release is that it slowly becomes one. A small code fix gets cherry-picked "just this once", the docs describe it, and now the published docs of 0.2 describe code that is not in any 0.2 package. Anyone reading them and running the real 0.2 sees something else. Worse, the branch now holds a version of the code that no tag names, and nobody can say which fixes it has.

The guard makes that impossible rather than discouraged. Before a docs branch publishes, it compares the branch with its release tag and refuses if anything outside the docs changed. The code in a docs branch is therefore always exactly the code of a release, and the only way to ship a code fix is a release, with a tag, a version number and a changelog entry. The refusal message says as much: "code fixes need a release".

The guard also insists that the newest release tag of the minor is an ancestor of the branch. After a patch release, the branch has to move onto the new tag before it can publish again. Otherwise a docs fix pushed to an old branch would overwrite the patch release's docs with the docs of the previous patch, silently undoing whatever the patch changed.

Tags are not guarded. A tag is the release; its docs are by definition the docs of that release.

## Why fixes go to `main` first, and why never rebase

A doc fix that only lands on the docs branch is lost at the next minor, which is cut from `main`. Landing it on `main` first and cherry-picking it onto the docs branch keeps `main` the one place every fix lives, and makes the docs branch a strict subset: its release, plus a few commits that are already on `main`.

Merging or rebasing `main` into the docs branch looks like a shortcut, but it brings along everything else on `main`, including the docs of unreleased features. The guard catches the code that comes with them, but not the docs, which it allows by design. Cherry-picking is deliberate: each commit that reaches a published version was chosen for it.

Merging a patch release's tag into the docs branch is a different thing. The tag is a release, so everything it brings has shipped. That is why moving the branch to a patch tag is a fast-forward or a merge, while `main` never goes in.

When the next minor ships, its branch takes over and the old one is frozen. Nothing stops a push to the old branch, but the one-maintained-version rule means there is no reason to.

## Why `latest` only moves forward

`latest` is what most readers see. It must always be the newest release, whatever order publishes happen in. Publishes do happen out of order: a fix to an older version, or a manual republish of one, can run after the newer minor has shipped. If every publish took `latest`, republishing `0.1` would silently point the whole site back at an old release.

So a publish takes `latest` only if its version is the newest one on `gh-pages`. The comparison is by version, not by text, because `0.10` is newer than `0.9` and a text sort says otherwise. Publishes also run one at a time, since two mike deploys racing on the same branch could each overwrite the other's work.

## Pinned links and `latest` links

A link to the docs is either about the project now or about a particular release. The README and a forum answer are about now: they should follow the project, so they link to `/latest/`. A changelog entry, a release note, or a URL inside the package is about one release, and has to keep pointing at the docs of that release after newer ones come out.

The package matters most. A router running 0.1 that shows a help URL should lead to the 0.1 docs, where the options and messages match what is installed, not to the newest docs, which may describe options it does not have. Pinning the shipped links to the package's minor gives every installed version a link to its own docs.

Pinned links rot silently: bump the version and forget one link, and the next release ships pointing at the previous minor. A check in `make lint` catches that. The changelog gets the same check per section, and `[Unreleased]` allows no pinned link at all, because the version it will be released as is not known yet.

Links between pages of the docs are always relative. A relative link resolves inside whatever version the reader is in, so each published version is self-contained without any rewriting.

## The redirect for old links

A link without a version, `/<site>/how-to/...`, is an easy one to write by hand, and any link from before the site was versioned looks like that. Nothing lives at those paths any more. Rather than breaking every such link, the site's 404 page moves a missing unversioned path under `/latest/`, keeping its query and anchor. A path that is already inside a version folder is left as a real "not found": redirecting it could loop, and a page that does not exist in 0.1 should not quietly become a page of another version.

## Why `mkdocs.yml` stays free of mike

The versioned settings live in their own file, `mkdocs.mike.yml`, which inherits `mkdocs.yml`. With the mike plugin and version provider in the main config, a plain `mkdocs serve` would show a version selector with nothing behind it, and every writer's preview would depend on mike. Keeping them apart means writing and previewing the docs needs nothing but MkDocs Material, and the versioned build is exercised on its own in CI and by `make -C docs build-mike`.

## Trade-offs

**`latest` is a copy.** mike can make an alias a symlink, a redirect page, or a copy. GitHub Pages cannot be relied on to serve symlinks, and redirect pages would make every `/latest/` URL a hop through a stub. A copy gives real pages at stable URLs. The price is that every page of the newest version exists twice; the canonical URL of each page points to its `/latest/` copy, so search engines can treat the two as one. Identical files are stored once in git, so the copy costs little on `gh-pages`.

**The 404 redirect assumes a project site.** It treats the first path segment as the site, which matches `https://<user>.github.io/<site>/`. On a custom domain or a user site, where the docs live at the root, the redirect would need changing.

**CI and local builds use different installs.** Local builds run the pinned mkdocs-material image, plus mike in a derived image. The publish job installs the same pinned mkdocs-material and mike with `pip` on the runner, which spares CI building the image, but their own dependencies are not pinned. A dependency release can therefore make CI's build differ from a local one. Both builds are strict, so the likely failure is a loud one, not a quiet difference in the published site.

**The freeze is a rule, not a lock.** Nothing technical stops a push to an old docs branch; the guard only keeps it docs-only. The project relies on the one-maintained-version rule for the rest.
