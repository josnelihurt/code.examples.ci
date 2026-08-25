# AGENTS.md

Working agreements for coding agents in this repository. Humans reviewing the results are
the audience that matters — every rule below exists to keep what lands reviewable.

This repository is the shared CI toolkit for the `code.examples.*` repositories. Today it
holds one thing: the `merge-me` composite action and its canonical script. Consumers keep
thin trigger-only workflows and pin this repository by SHA with the tag in a trailing
comment. Changes here are load-bearing in every consumer at once — treat a change to
`merge-me/` like a change to every consuming repository's CI, and say so in the PR body.

## Big changes land as stacked pull requests

Never open one large PR. Decompose the change into an ordered chain in which **every
level compiles, passes lint, and passes every CI gate independently**. If an
intermediate level would be red, the split is wrong — redo the split.

The recipe (proven across the `code.examples` repositories):

1. **Build and verify the end state first** — all suites green, lint clean. Then snapshot
   uncommitted work to a local backup branch (`git checkout -b backup/… && git add -A && git
   commit`) before splitting, and reset the working branch clean. Never push the backup branch.
2. **Choose the split by decision**, bottom to top: foundations first; adapters beside the
   old implementation; no-op plumbing as layers that a later PR makes load-bearing; then
   the behavior switch; then pure deletion of the old path; docs last.
3. **Cut branches in order**, each from the previous one's head; author intermediate
   states explicitly instead of hoping the final files compile mid-stack.
4. **Verify at the load-bearing levels, not only the tip** — run the checks each level
   could break at that level before moving on.
5. **One commit per branch**, message as `type: lowercase imperative`
   (feat / fix / ci / docs / test / refactor / build).
6. **PR body** = **What** (one paragraph) · **Stack** (part N of M, prev + next links) ·
   **Review pointers** · **Evidence** (which checks ran green *at this level*).
7. **Label the top layer `merge-me` only**: the merge lands every stack member below it
   atomically. Labeling several layers starts concurrent merges that race.

## Versioning

`merge-me/` is consumed through tags: `v1`, then `v2`, … Consumers pin the tag's commit
SHA (`uses: josnelihurt/code.examples.ci/merge-me@<sha> # v1`). Move a tag only by
deleting and recreating it before anyone consumes the intermediate state, and never
after the tag has consumers — cut the next tag instead. Additive changes take a patch of
the same tag; breaking input/behavior changes take the next major tag and a migration
note in the PR that bumps it.

## What matters most

Every intermediate level green, per-level evidence in the PR bodies, and a tip that
matches the independently verified end state.
