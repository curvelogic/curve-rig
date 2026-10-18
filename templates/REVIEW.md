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

<!-- Paths or kinds of change that need more than one review. For each,
     say which: "second independent review" or "the owner merges". -->

| Area | Rule |
|---|---|
| <path or kind of change> | second independent review |
| <path or kind of change> | the owner merges |

<!-- Optional: a routine class of change to CI that gates merging, which
     rig-review may merge after review. Without a row like this, every such
     change is the owner's. Even with it, rig-review merges only a PR that
     fits the class entirely and drops or weakens no check, and changes no
     trigger, `permissions:`, use of secrets or the workflow token, and no
     job or job name. To adopt it, move the row into the table above.

| Routine CI change: only bumps the pinned version of actions the workflows already use (e.g. Dependabot's `github-actions` updates) | agent-merged after review |
-->

## Merging

<!-- Merge method (squash or merge commit), and any check after merging:
     e.g. "watch the deploy job on the merge commit and report its result". -->

Method: squash.

## Worth flagging, not blocking

<!-- Things the reviewer should mention in its comment so the owner sees
     them after the fact: spec changes, new dependencies, … -->
