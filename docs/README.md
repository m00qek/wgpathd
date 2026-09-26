# docs/

Source for the wgpathd documentation site.

Built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/). Structured using the [Diátaxis framework](https://diataxis.fr/): tutorials, how-to guides, reference, and explanation.

## Build and preview

Both commands run inside a Docker container, so no local Python installation is required.

```bash
make -C docs serve     # Live preview at http://localhost:8000
make -C docs build     # Build static site to bin/site/ (mkdocs build --strict)
```

## Structure

```
docs/
├── tutorials/     # Learning-oriented: developer onboarding
├── how-to/        # Goal-oriented: substrate, install, configure, steer, troubleshoot
├── reference/     # Information-oriented: UCI, ubus status, discovery API, logs, errors
├── explanation/   # Understanding-oriented: state machine, discovery, trust model, architecture
├── design.md      # Internal design record (kept as written)
└── history.md     # Substrate build log (kept as written)
```

For contribution guidelines, see [how-to/developer/documentation.md](how-to/developer/documentation.md).
