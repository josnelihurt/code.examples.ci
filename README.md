# code.examples.ci

The shared CI toolkit for the `code.examples.*` repositories. It exists because the
automation that every repository needs identically — today, the `merge-me` label flow —
would otherwise drift between copies (it already had: the frontend copy was missing the
disarm-on-unlabel path and the stack-conflict pre-checks when this repository was
extracted).

The design history, the rejected alternatives (classic merge API, marketplace automerge
actions — both break on stacked PRs) and the tradeoffs are recorded in
[code.examples.net.quotes#7](https://github.com/josnelihurt/code.examples.net.quotes/issues/7)
and
[#10](https://github.com/josnelihurt/code.examples.net.quotes/issues/10).

## What lives here

| Path | What it is |
| --- | --- |
| `merge-me/` | The `merge-me` composite action: `action.yml` + the canonical evaluation script |
| `conventions/` | The branch-naming and commit-message composite action behind every consuming repository's conventions job |
| `secrets-hygiene/` | The credential-literal allowlist gate (pattern + exclusions as inputs) |
| `.github/workflows/merge-me.yml` | This repository's own trigger wrapper — the self-hosting proof |

## Consuming the conventions action

The consuming repository's conventions job checks out with `fetch-depth: 0` and
delegates everything to the action; repositories that host automation branches
pass the exemption those branches need:

```yaml
  conventions:
    name: conventions (branch names + commit messages)
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    steps:
      - uses: actions/checkout@<commit-sha> # v4
        with:
          fetch-depth: 0
      - uses: josnelihurt/code.examples.ci/conventions@<commit-sha> # v1
        with:
          branch-exempt-regex: '^dependabot/'
```

The opt-in local hooks keep working the same way: canonical `commit-msg` and
`pre-push` hook scripts live beside the checker
(`conventions/scripts/commit-msg`, `conventions/scripts/pre-push`). A
consuming repository surfaces them on disk — as this repository's git
submodule (a two-line exec in its `.githooks/`, the preferred shape) or as a
fetch-shim at the `v1` tag via `gh` — one implementation, no copies to drift.
The canonical hooks resolve their sibling checker relative to themselves, so
they run offline in either shape.

One known edge: a `GITHUB_TOKEN` cannot merge a pull request that updates
workflow files unless its app authored them (dependabot's action-pin bumps).
`workflows` is not a grantable workflow-permission scope — attempting it makes
GitHub refuse to parse the workflow entirely. Such PRs land by arming
GitHub's server-side auto-merge with a human token: `gh pr merge <n> --squash --auto`.

## Consuming the merge-me action

A consuming repository keeps a thin trigger-only workflow (`.github/workflows/merge-me.yml`)
whose name **must stay `merge-me`** (the script excludes its own workflow from check
verdicts by that name) and pins this repository by SHA with the tag in a trailing comment:

```yaml
name: merge-me
on:
  pull_request:
    types: [labeled, synchronize, reopened, unlabeled]
  workflow_run:
    workflows: [ci]
    types: [completed]
  workflow_dispatch:
    inputs:
      pr:
        description: "PR number to evaluate (blank = every open labeled PR)"
        required: false
permissions:
  contents: write
  pull-requests: write
concurrency:
  group: merge-me-${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_branch || github.event.pull_request.number || github.event.inputs.pr || 'manual' }}
  cancel-in-progress: true
jobs:
  merge:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    timeout-minutes: 25
    steps:
      - uses: josnelihurt/code.examples.ci/merge-me@<commit-sha> # v1
        with:
          pr: ${{ github.event.pull_request.number }}
          disarm: ${{ github.event.action == 'unlabeled' }}
  # …the ci-completion and manual-dispatch arms follow the same pattern; see this
  # repository's own wrapper for the reference wiring.
```

No `actions/checkout` is needed — the action is self-contained. The `disarm` input
covers the `unlabeled` trigger; `wait-minutes: '0'` evaluates instantly (used by the
ci-completion arm, whose checks have already finished); `dry-run: 'true'` evaluates
and reports without merging, arming, or disarming anything — the smoke test for
onboarding a new consumer with zero merge risk.

## Consuming the secrets-hygiene action

The pattern and the allowlist are the repository's own knowledge; the mechanics
live here. The consuming job checks out (any depth) and states its rule once:

```yaml
  secrets-hygiene:
    name: secrets hygiene (credential literals stay in the allowlist)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<commit-sha> # v4
      - uses: josnelihurt/code.examples.ci/secrets-hygiene@<commit-sha> # v1
        with:
          pattern: 'supersecret|readsecret'
          exclude: |
            **/*.test.ts
            e2e/**
            src/mocks/**
          hint: 'These literals belong to the seed; here they live only in tests and fixtures.'
```

## The decision table

Every evaluation is triggered by a real event — the label, a push, a reopen, the ci
workflow completing, or a manual dispatch. Nothing runs on a timer.

| PR state | Action |
| --- | --- |
| Green, labeled | Merged via the asynchronous merge endpoint — the only merge path that also lands stacked PRs atomically (every member below the labeled PR) |
| Pending, base = default branch | GitHub's server-side auto-merge armed (it survives any number of fix pushes) |
| Pending, stacked layer | Bounded 15-minute wait inside the evaluation, re-armed by the next event |
| Red or conflicting | Held — the label stays; approval of *intent* is separate from merge *state* |
| Lower stack layer conflicting | Held with the repair recipe printed instead of a bare "merge failed" |
| Label removed | Any armed auto-merge is disarmed — the intent does not outlive the label |

## Working agreements

See [AGENTS.md](AGENTS.md): stacked PRs with every level green, one commit per branch,
`merge-me` labeled on the top layer only, and tag-based versioning (`v1`, `v2`, …) with
consumers pinning the tag's SHA.

## Consumers

| Repository | Pin | Notes |
| --- | --- | --- |
| [code.examples.net.quotes](https://github.com/josnelihurt/code.examples.net.quotes) | `merge-me@fab8efc # v1` | migrated in #17 → #18 (stack) + #20 (repin after the race documented below) |
| [code.examples.frontend.quotes](https://github.com/josnelihurt/code.examples.frontend.quotes) | `merge-me@fab8efc # v1` | migrated in #9 → #10 (stack); gained disarm-on-unlabel + conflict pre-checks |

Migration note worth keeping: when a stack is relabeled or force-pushed around a
pending merge, the default-branch workflow's `workflow_run` arm may merge the stack
from branch heads it captured before the update — the net repository's first
migration landed with a stale pin that way and needed a one-PR repin (#20 there).
Land consumer pin changes before labeling, or expect the repin follow-up.

## Onboarding a new consumer

1. Copy this repository's own `.github/workflows/merge-me.yml` and delete the
   `actions/checkout` steps plus the local-path comment — the consumer version
   pins `josnelihurt/code.examples.ci/merge-me@<sha> # vN` and needs no checkout.
2. Keep the workflow `name: merge-me` and the `ci` workflow_run target exactly —
   the script's self-exclusion and re-evaluation key on them.
3. Create the `merge-me` label (`0e8a16`) if the repository does not have it.
4. Verify with a two-level docs stack: label the top layer only and watch both
   squash-merge atomically.
