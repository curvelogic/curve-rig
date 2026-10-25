# REVIEW.md — <project>

<!-- rig template. The rig-review agent reads this file for every PR.
     Delete these comments when filled in. -->

Criteria applied to every PR, on top of green CI.

## Blocking

<!-- Concrete, checkable rules. Examples:
     - Panics are P1: any new panic path needs a regression test.
     - Regression tests are proved by breaking the code and seeing them fail.
     - No lint suppressions. -->

## Sensitive areas

<!-- Paths or kinds of change with a rule of their own. For each, say
     which: "second independent review", "the owner merges", or
     "agent-merged after review" (a routine class). -->

| Area | Rule |
|---|---|
| <path or kind of change> | second independent review |
| <path or kind of change> | the owner merges |
| `.github/`, `.beads/` configuration, `.claude/`, `.rig/` | the owner merges |
| A PR from outside (from a fork, or opened by any account or bot other than the one agents act as and the repository's Dependabot) | the owner merges |
<!-- Optional: a routine class for dependency bumps, which rig-review may
     merge after review. Without a row like this, every Dependabot PR is
     the owner's. The row carries its own limits, so keep it whole. A
     tool that CI or the check runs (a linter, test runner or GitHub
     Action) is CI that gates merging, and stays the owner's unless the
     class below covers it. rig-review never runs a Dependabot PR's code,
     so it merges on CI's result: adopt the class only where CI runs
     everything the check command runs, on Dependabot's PRs too. Before
     adopting it, set Dependabot's `cooldown` so a release waits some days
     before it is proposed. To adopt it, move the row into the table
     above; give major-version bumps a row of their own if you want them
     reviewed twice (say, "second independent review").

| A Dependabot PR that bumps one existing dependency to a patch or minor release, and changes nothing but that dependency's version and the lockfile entries the bump brings: no package added to the lockfile, none moved across a major version, and no tool CI or the check runs. On a 0.x version, a change to the first non-zero part (0.3 to 0.4, 0.0.3 to 0.0.4) is a major bump. | agent-merged after review |
-->

<!-- Optional: a routine class of change to CI that gates merging, which
     rig-review may merge after review. Without a row like this, every such
     change is the owner's. Even with it, rig-review merges only a PR that
     fits the class entirely and meets every condition in its definition:
     no check dropped or weakened; no step or action added; no trigger,
     `permissions:`, secret or token use, job, job name or matrix changed;
     each bumped action moved to the full SHA of an upstream release in
     the same major version, with its release notes read. Reusable
     workflows and actions that are themselves the check stay the
     owner's, and so does any workflow holding write access or a secret
     (one with no `permissions:` counts as write): the class reaches only
     workflows that declare read-only `permissions:` and use no secrets.
     To adopt it, move the row into the table above; if another row also
     covers workflows (`.github/`, say), add "this class wins
     over it" to this row, or the stricter row applies.

| Only external actions' `uses:` refs change | agent-merged after review |
-->

## Merging

<!-- Merge method (squash or merge commit), and any check after merging:
     e.g. "watch the deploy job on the merge commit and report its result". -->

Method: squash.

## Worth flagging, not blocking

<!-- Things the reviewer should mention in its comment so the owner sees
     them after the fact: spec changes, new dependencies, … -->
