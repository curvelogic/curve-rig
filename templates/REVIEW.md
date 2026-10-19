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
| A PR from outside (from a fork, opened by another account, or with commits GitHub links to one) | the owner merges |

<!-- Optional: a routine class of change to CI that gates merging, which
     rig-review may merge after review. Without a row like this, every such
     change is the owner's. Even with it, rig-review merges only a PR that
     fits the class entirely and meets every condition in its definition:
     no check dropped or weakened; no step or action added; no trigger,
     `permissions:`, secret or token use, job, job name or matrix changed;
     each bumped action moved to the full SHA of an upstream release in
     the same major version, with its release notes read. Reusable
     workflows and actions that are themselves the check stay the
     owner's. To adopt it, move the row into the table above; if another
     row also covers workflows (`.github/`, say), add "this class wins
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
