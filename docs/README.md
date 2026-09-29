# docs/

Source for the wgpathd documentation site.

Built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/). Structured using the [Diátaxis framework](https://diataxis.fr/): tutorials, how-to guides, reference, and explanation.

## Build and preview

All of these run inside Docker, so no local Python installation is required.

```bash
make -C docs serve       # Live preview at http://localhost:8000 (DOCS_PORT=<n> to change)
make -C docs build       # Build static site to bin/site/ (mkdocs build --strict)
make -C docs build-mike  # Same, with the versioned config mkdocs.mike.yml
make -C docs test        # Test the publishing scripts
```

## Publishing

The site is published per minor release with mike (`/X.Y/`, `/latest/`), from release tags and `docs/X.Y` branches, never from `main`. See [reference/docs-publishing.md](reference/docs-publishing.md) for the machinery and the how-to guides in `how-to/developer/` for releasing and fixing the docs.

## Structure

```
docs/
├── tutorials/     # Learning-oriented: developer onboarding
├── how-to/        # Goal-oriented: substrate, install, configure, steer, troubleshoot
├── reference/     # Information-oriented: UCI, ubus status, discovery API, logs, errors
├── explanation/   # Understanding-oriented: state machine, discovery, trust model, architecture
├── overrides/     # Theme override for the versioned site (outdated-version banner)
├── design.md      # Internal design record (kept as written)
└── history.md     # Substrate build log (kept as written)
```

For contribution guidelines, see [how-to/developer/documentation.md](how-to/developer/documentation.md).
