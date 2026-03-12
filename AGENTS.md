# Agent Guide — Altitude Organisation Profile

## Project Overview

This is the special `.github` repository for the `altitude-travel` GitHub
organisation. GitHub treats this repository uniquely — the file at
`profile/README.md` is rendered as the **public organisation profile** on
`github.com/altitude-travel`. This is the first thing visitors see when they
navigate to the organisation page, including developers, potential contributors,
investors, and partners.

This repository does **not** contain application code, infrastructure, or
automation. Its sole purpose is to host the organisation-level profile content
and any organisation-wide GitHub configuration that GitHub sources from the
`.github` repository (e.g. default community health files).

## Repository Structure

```
.github/
├── profile/
│   └── README.md          # Organisation profile (rendered on github.com/altitude-travel)
├── .gitignore             # Git ignore rules
├── AGENTS.md              # This document (AI agent instructions)
├── CLAUDE.md              # Immutable Claude agent configuration (managed by github-policies)
└── LICENSE                # Project licence
```

## What This Repository Is For

1. **Organisation profile** — `profile/README.md` is displayed publicly on the
   organisation's GitHub page. It communicates who Altitude is, what we build,
   and how to get involved.
2. **Default community health files** — GitHub falls back to files in this
   repository (e.g. `ISSUE_TEMPLATE.md`, `PULL_REQUEST_TEMPLATE.md`,
   `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`) when a repository in
   the organisation does not have its own. Currently, these are managed
   per-repository via the
   [github-policies](https://github.com/altitude-travel/github-policies)
   normalisation process, but this repository can serve as the fallback layer.

## What This Repository Is NOT For

- Application code, libraries, or services
- Infrastructure configuration (Terraform, Docker, etc.)
- CI/CD workflows for other repositories
- Internal documentation or architecture details
- Repository-specific templates (those belong in each repository's own
  `.github/` directory or in the `github-policies` repository)

## Content Guidelines

### Profile README (`profile/README.md`)

The profile README is the organisation's public face. It must:

- Be **professional but approachable** — matching the voice on
  [altitude.chat](https://altitude.chat)
- Be **concise and scannable** — no walls of text
- Use **British English** throughout
- Focus on **what Altitude is and does**, not internal implementation details
- Include links to the website and other public resources

The profile README must **not**:

- List individual repositories or link to internal repos
- Expose internal architecture, stack specifics, or repository names
- Include badges, shields, or developer-oriented clutter
- Use marketing fluff that does not belong on GitHub
- Include emojis unless explicitly requested

### Tone

All content in this repository should be written for a **general audience** —
not just developers. Visitors may be potential users, partners, investors, or
community members. Keep language accessible and avoid unnecessary jargon.

## Agent Strict Rules

1. **Planning**: ALWAYS create a detailed plan and obtain EXPLICIT user approval
   before making any project changes.
2. **Follow Existing Patterns**: Match the style and structure of existing
   content. Use the same tone and formatting conventions already established in
   the profile README.
3. **Documentation**: Update `AGENTS.md` to reflect any structural or workflow
   changes as they are implemented. A change is incomplete until its
   documentation is accurate and up to date.
4. **Quality**: Run formatting and linting checks after EVERY change. All checks
   MUST pass with zero errors before the work is considered complete.
5. **Pull Requests**: When asked to write a PR description, fill in the template
   at `.github/PULL_REQUEST_TEMPLATE.md` and save the result to
   `PR_DESCRIPTION.md` in the project root. Do NOT alter the template structure
   — only populate the placeholder sections. `PR_DESCRIPTION.md` is git-ignored
   and should never be committed.
6. **No Internal Details**: NEVER add repository names, internal architecture,
   stack specifics, or any implementation details to the profile README. This
   content is public-facing and should only reference what is already publicly
   known via [altitude.chat](https://altitude.chat).
7. **Git Safety**: NEVER run destructive git commands (`push --force`,
   `reset --hard`, `checkout .`, `restore .`, `clean -f`, `branch -D`) without
   explicit per-occasion permission from the user. Each use requires separate
   approval — prior approval does not carry forward. NEVER amend published
   commits. NEVER skip hooks (`--no-verify`). NEVER force push to `main`.
8. **Minimal Changes**: Only make changes that are directly requested or clearly
   necessary. Do not refactor, reorganise, or "improve" content beyond what was
   asked. Keep changes focused and minimal.
9. **British English**: All content, documentation, and commit messages MUST use
   British English (e.g. `organisation` not `organization`, `colour` not
   `color`, `behaviour` not `behavior`, `initialise` not `initialize`, `licence`
   not `license`, `centre` not `center`).

## Language

All documentation, content, commit messages, and any other text throughout the
repository MUST use **British English** (e.g. `organisation` not `organization`,
`standardised` not `standardized`, `colour` not `color`, `behaviour` not
`behavior`, `initialise` not `initialize`, `licence` not `license`, `centre` not
`center`).

## Formatting and Linting

This repository contains only Markdown files. Use Prettier for formatting:

- **Check**: `npx prettier . --prose-wrap always --check`
- **Format**: `npx prettier . --prose-wrap always --write`

The `--prose-wrap always` flag is the organisation-wide convention. Always run
the format command and verify with the check command before submitting changes.
