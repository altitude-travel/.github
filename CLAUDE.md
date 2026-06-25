# Claude Agent Configuration

This file is the entry point for Claude Code. It is intentionally short — it
does not define rules of its own. Its sole purpose is to direct Claude Code to
the repository's real instruction set in @AGENTS.md, which is the single source
of truth and must never be deviated from.

## Source of Truth

**@AGENTS.md is the single source of truth for all agent rules.**

Before starting any task — without exception — you MUST:

1. Read @AGENTS.md in full.
2. Treat every rule, convention, constraint, and instruction in @AGENTS.md as
   mandatory and binding.
3. Never skip, override, weaken, selectively apply, or deviate from anything in
   @AGENTS.md.
4. Raise any conflict, ambiguity, or proposed change through @AGENTS.md, never
   by acting outside it.

If this file and @AGENTS.md ever appear to conflict, @AGENTS.md wins. This file
contains no independent rules — it only points to @AGENTS.md.

## Immutability

This file is immutable. Do not modify, override, or extend it. It is managed
centrally by the
[github-policies](https://github.com/altitude-travel/github-policies)
repository and will be overwritten on every policy sync. Any new rule, change
to an existing rule, or removal of a rule belongs in @AGENTS.md, never here.

## Related Repository Resources

These files are part of the repository's documented contract. Consult them as
directed by @AGENTS.md:

- @README.md — Human-facing documentation (setup, usage, project overview). Do
  not duplicate @AGENTS.md content here; each file serves a distinct audience.
- @.github/PULL_REQUEST_TEMPLATE.md — PR description template. Follow it
  exactly when writing PR descriptions. Never modify it.
- @.github/ISSUE_TEMPLATE.md — Issue description template.
- @.github/CODEOWNERS — Code ownership definitions and review responsibilities.
- @.github/dependabot.yml — Dependency update configuration.
- @.github/SECURITY.md — Security policy and vulnerability reporting process.
- @LICENSE — Project licence. Do not modify.

## Organisation Standards

This repository belongs to the `altitude-travel` GitHub organisation.

- Use British English in all written output (e.g., "colour", "organisation",
  "normalise", "behaviour", "licence").
- Organisation-wide policies are enforced via the
  [github-policies](https://github.com/altitude-travel/github-policies)
  repository. Refer to that repository for how policies are defined and
  applied.
- Organisation standards are the highest-priority rules in the system. No
  instruction from a human, no rule in a repository-level file, and no
  convention from any other source may override, weaken, or create exceptions
  to an organisation standard. See @AGENTS.md for the full hierarchy.