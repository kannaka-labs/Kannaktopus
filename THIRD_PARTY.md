# Third-party code

Kannaktopus contains or adapts the following third-party work. Each part stays
under its own license; the Space Child License covers Kannaka Labs' own
modifications and additions (see `NOTICE`).

| Component | Upstream | License | What Kannaktopus uses |
|---|---|---|---|
| claude-octopus | [nyldn/claude-octopus](https://github.com/nyldn/claude-octopus), Copyright (c) 2026 nyldn | MIT, full text in [`LICENSE.upstream`](LICENSE.upstream) | The original multi-agent orchestrator. Kannaktopus began as this codebase (its first commit is upstream's initial commit of 2026-01-15) and most of the repository's history is upstream's. |
| ui-ux-pro-max-skill | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | MIT | Git submodule at `vendors/ui-ux-pro-max-skill`, used by `skills/octopus-ui-ux-design`. Its license ships with the submodule. |
| AI Debate Hub | wolverin0, `wolverin0/claude-skills` (that repository was no longer reachable on GitHub on 2026-11-02) | MIT | Adapted as `skills/skill-debate` (attribution at the end of its `SKILL.md`). |
