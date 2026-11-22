# bendevcat — Claude Code plugins

My Claude Code plugins in one catalog. Each plugin lives in its own repository; this
repository only lists them, each pinned to a release tag and the commit behind it.

## Install

```
/plugin marketplace add bendevcat/claude-skills
/plugin install <plugin>@bendevcat
```

Updates: `/plugin marketplace update bendevcat`, then `/plugin update <plugin>@bendevcat`.

## Release a plugin

From this repository:

```bash
scripts/release.sh --dry-run ../svg-craft 0.2.0   # see what would happen
scripts/release.sh ../svg-craft 0.2.0
```

The script bumps `plugin.json` in the plugin repository, commits, tags `v0.2.0` and pushes;
then it pins that tag and its commit here, bumps the catalog version, adds a line to
`CHANGELOG.md`, commits, tags and pushes this repository. An existing tag is pinned as is.

Requirements: `jq`, the plugin on `main` (or `--allow-branch`), no uncommitted changes to
tracked files, an `origin` remote on the plugin repository.

Versioning: a plugin's version is the `version` in its `plugin.json`, and its git tag
`vX.Y.Z`. The catalog has its own version (`metadata.version`, tag `vX.Y.Z` here): minor
when a plugin is added or changes major version, patch otherwise.
