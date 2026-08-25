#!/usr/bin/env bash
# Merges pull requests labeled `merge-me` — the label is standing intent ("merge when
# green"), not a command. Each evaluation checks the label, the PR's checks and its
# mergeability, then either merges, arms GitHub's server-side auto-merge, or holds
# (red stays labeled; the next event re-evaluates). Nothing here runs on a timer —
# every evaluation is triggered by a real event: the label, a push, a reopen, the ci
# workflow completing, or a manual dispatch (the scheduled sweep this design started
# with was removed in review; see code.examples.net.quotes#7 for the investigation,
# the rejected alternatives — the classic merge API and marketplace automerge actions
# both break on stacked PRs — and the tradeoffs).
#
# This script is repository-agnostic (it derives everything from gh + the runner
# environment) and is consumed through merge-me/action.yml; a consuming repository's
# thin .github/workflows/merge-me.yml keeps only its triggers and wiring.
#
#   merge-me.sh <pr-number> [--wait-minutes N] [--dry-run]
#       Evaluate one PR. Wait mode (default 15 min): pending checks are polled, so a
#       green outcome within the window merges in the same run. Used by the workflow's
#       pull_request trigger (labeled / synchronize / reopened) and, with a
#       zero-minute wait, by its ci-completion trigger (checks already finished).
#
#   merge-me.sh <pr-number> --disarm
#       The label was removed: disarm any armed server-side auto-merge
#       (code.examples.net.quotes#10 — an armed auto-merge survived unlabeling and
#       merged by surprise). Used by the workflow's unlabeled trigger.
#
#   merge-me.sh --all [--dry-run]
#       Instant evaluation of every open labeled PR — no waiting: green PRs merge,
#       pending ordinary PRs get auto-merge armed, everything else is left for the
#       event path. The manual escape hatch behind the workflow's workflow_dispatch
#       trigger (blank pr input), for replaying an evaluation lost to a transient
#       run failure.
#
# Exit 0 = merged, held (red/pending/conflict — re-evaluated later) or nothing to do;
# exit 1 = a merge was attempted and failed. Requires gh with GH_TOKEN (or a logged-in
# user) and read+write repository access.
set -euo pipefail

DRY_RUN=false
WAIT_MINUTES=15
ALL=false
DISARM=false
PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)          ALL=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --disarm)       DISARM=true; shift ;;
    --wait-minutes) WAIT_MINUTES="${2:?--wait-minutes needs a value}"; shift 2 ;;
    [0-9]*)         PR="$1"; shift ;;
    *) echo "usage: $0 <pr-number> [--wait-minutes N] [--dry-run] | <pr-number> --disarm | --all [--dry-run]" >&2; exit 2 ;;
  esac
done
if [[ "${ALL}" == false && -z "${PR}" ]]; then
  echo "usage: $0 <pr-number> [--wait-minutes N] [--dry-run] | <pr-number> --disarm | --all [--dry-run]" >&2
  exit 2
fi

if [[ "${DISARM}" == true ]]; then
  if [[ -z "${PR}" ]]; then
    echo "--disarm needs a pr number" >&2
    exit 2
  fi
  if gh pr merge "${PR}" --disable-auto >/dev/null 2>&1; then
    printf '#%s: merge-me label removed — armed auto-merge disarmed\n' "${PR}"
  else
    printf '#%s: merge-me label removed — no armed auto-merge to disarm\n' "${PR}"
  fi
  exit 0
fi

# No git repository exists in the action's workspace (and gh's git discovery
# fails there even with GH_REPO set), so the repository comes from the runner's
# GITHUB_REPOSITORY and everything else goes through explicit API calls.
REPO="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY=owner/repo (Actions sets it; export it to run locally)}"
DEFAULT_BRANCH="$(gh api "repos/${REPO}" --jq .default_branch)"

# checks_state PR -> green | red | pending | none
checks_state() {
  local buckets
  # This workflow's own runs are checks on the PR too: the evaluation in flight is
  # always "pending" from its own point of view, which would deadlock every wait.
  # The gate's job is the product's checks (ci), not merge-me observing itself.
  # The consuming workflow must keep the name "merge-me" for this exclusion to hold.
  buckets="$(gh pr checks "$1" --json workflow,bucket \
    --jq '[.[] | select(.workflow != "merge-me") | .bucket]' 2>/dev/null || true)"
  if [[ -z "${buckets}" || "${buckets}" == "[]" ]]; then
    printf none
  elif jq -e 'any(. == "fail")' <<<"${buckets}" >/dev/null; then
    printf red
  elif jq -e 'any(. == "pending") or any(. == "cancel")' <<<"${buckets}" >/dev/null; then
    # cancel is pending, not green: ci's concurrency cancels superseded runs (every
    # label now retriggers it), and the replacement run's checks may not exist yet —
    # merging on the cancelled run's stale checks is never the verdict to act on.
    printf pending
  else
    printf green
  fi
}

# wait_for_checks PR MINUTES -> 0 green, 1 red, 2 still pending at the deadline
wait_for_checks() {
  local deadline=$((SECONDS + $2 * 60)) state announced=false
  while :; do
    state="$(checks_state "$1")"
    case "${state}" in
      green) return 0 ;;
      red)   return 1 ;;
      none)
        if [[ "${announced}" == false ]]; then
          printf '… no checks reported yet, waiting\n'
          announced=true
        fi
        ;;
    esac
    if ((SECONDS >= deadline)); then return 2; fi
    sleep 20
  done
}

# arm_auto_merge PR -> 0 armed, 1 unavailable (setting off, stacked PR, already armed)
arm_auto_merge() {
  # Arming changes repository state — never in a dry-run, which must stay inert.
  if [[ "${DRY_RUN}" == true ]]; then return 1; fi
  gh pr merge "$1" --squash --auto >/dev/null 2>&1
}

# merge PR via the asynchronous endpoint — the only merge path that works for
# stacked PRs (it lands every stack member up to this one atomically).
merge() {
  local resp uuid status tries
  if [[ "${DRY_RUN}" == true ]]; then
    printf 'dry-run: would merge #%s (squash, merge-async)\n' "$1"
    return 0
  fi
  resp="$(gh api -X PUT "repos/${REPO}/pulls/${1}/merge-async" \
    -f merge_method=squash -f merge_action=default)"
  status="$(jq -r .status <<<"${resp}")"
  if [[ "${status}" == "merged" ]]; then printf '#%s merged\n' "$1"; return 0; fi
  uuid="$(jq -r '.details.uuid // empty' <<<"${resp}")"
  if [[ -z "${uuid}" ]]; then
    printf '#%s: merge request not accepted: %s\n' "$1" "${resp}" >&2
    return 1
  fi
  for ((tries = 0; tries < 60; tries++)); do
    sleep 5
    resp="$(gh api "repos/${REPO}/pulls/${1}/merge-async/${uuid}")"
    status="$(jq -r .status <<<"${resp}")"
    case "${status}" in
      merged) printf '#%s merged\n' "$1"; return 0 ;;
      # The poll response carries the failure's actual reason; swallowing it is how
      # "#N: merge failed" became a mystery on an early review stack
      # (code.examples.net.quotes#10).
      failed) printf '#%s: merge failed — %s\n' "$1" "$(jq -c . <<<"${resp}")" >&2; return 1 ;;
    esac
  done
  printf '#%s: merge still pending after polling window (uuid %s)\n' "$1" "${uuid}" >&2
  return 1
}

# The squash-merge stack wedge (code.examples.net.quotes#10): when the bottom PR of a
# stack squash-merges, the layers above still carry it as a real commit while the base
# carries the same diff as the squash, so GitHub reports them CONFLICTING and every
# atomic merge fails. This recipe — replaying only a branch's own commits onto the
# new base, bottom-up — is the one sanctioned exception to "never force-push
# mid-stack branches".
wedge_recipe() {
  cat <<'RECIPE'
  repair (bottom-up, one layer at a time):
    git fetch origin
    git rebase --onto origin/<base> <old-base-tip> <branch>
    git push --force-with-lease origin <branch>
  then the next event re-evaluates and merge-me lands the layer.
  See the consuming repository's README — "Merging: the merge-me label", the
  squash-merge stack wedge section.
RECIPE
}

# lower_layer_conflicts PR -> 0 (printed and holding) | 1 (nothing conflicting below).
# The atomic merge lands every stack member below the labeled PR, so a CONFLICTING
# lower layer fails the whole attempt — detecting it first turns "#N: merge failed"
# into an instruction (code.examples.net.quotes#10). Walks the open-PR chain: the PR
# whose head branch is this one's base, then that PR's base, down toward the trunk.
lower_layer_conflicts() {
  local pr="$1" base lower_pr lower_mergeable
  base="$(gh pr view "${pr}" --json baseRefName --jq .baseRefName)"
  while [[ -n "${base}" && "${base}" != "${DEFAULT_BRANCH}" ]]; do
    lower_pr="$(gh pr list --head "${base}" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    if [[ -z "${lower_pr}" ]]; then return 1; fi
    lower_mergeable="$(gh pr view "${lower_pr}" --json mergeable --jq .mergeable)"
    if [[ "${lower_mergeable}" == "CONFLICTING" ]]; then
      printf '#%s: lower layer #%s (%s) is CONFLICTING — holding instead of attempting the merge\n' \
        "${pr}" "${lower_pr}" "${base}"
      wedge_recipe
      return 0
    fi
    base="$(gh pr view "${lower_pr}" --json baseRefName --jq .baseRefName)"
  done
  return 1
}

# evaluate PR WAIT_MINUTES — the per-PR decision table. Never merges anything that is
# not green; on red it exits 0 holding the label for the next re-evaluation.
evaluate() {
  local pr="$1" wait_minutes="$2" view state base mergeable
  view="$(gh pr view "${pr}" --json state,isDraft,baseRefName,mergeable,labels \
    --jq '{state: .state, draft: .isDraft, base: .baseRefName, mergeable: .mergeable, labeled: ([.labels[].name] | index("merge-me") != null)}')"
  state="$(jq -r .state <<<"${view}")"
  if [[ "${state}" != "OPEN" ]]; then printf '#%s is %s — nothing to do\n' "${pr}" "${state}"; return 0; fi
  if [[ "$(jq -r .draft <<<"${view}")" == "true" ]]; then printf '#%s is a draft — holding\n' "${pr}"; return 0; fi
  if [[ "$(jq -r .labeled <<<"${view}")" != "true" ]]; then printf '#%s has no merge-me label — nothing to do\n' "${pr}"; return 0; fi
  base="$(jq -r .base <<<"${view}")"
  mergeable="$(jq -r .mergeable <<<"${view}")"
  if [[ "${mergeable}" == "CONFLICTING" ]]; then
    printf '#%s has conflicts with its base — a human needs to rebase the stack\n' "${pr}"
    wedge_recipe
    return 0
  fi
  if lower_layer_conflicts "${pr}"; then return 0; fi

  local checks
  checks="$(checks_state "${pr}")"
  if [[ "${checks}" == "red" ]]; then
    printf '#%s has failing checks — holding the label for the next event\n' "${pr}"
    return 0
  fi

  if [[ "${checks}" == "green" ]]; then
    if [[ "${base}" != "${DEFAULT_BRANCH}" ]]; then
      printf '#%s is green (stack layer on %s) — merging lands every member below it\n' "${pr}" "${base}"
    fi
    if merge "${pr}"; then return 0; else return 1; fi
  fi

  # Pending (or not yet reported): ordinary PRs let GitHub wait server-side; stack
  # layers fall straight to the bounded wait (auto-merge does not take them).
  if [[ "${base}" == "${DEFAULT_BRANCH}" ]] && arm_auto_merge "${pr}"; then
    printf '#%s pending — auto-merge armed, GitHub merges when green\n' "${pr}"
    return 0
  fi
  if [[ "${base}" == "${DEFAULT_BRANCH}" ]]; then
    printf '#%s pending — auto-merge unavailable, falling back to a bounded wait\n' "${pr}"
  fi

  local rc=0
  wait_for_checks "${pr}" "${wait_minutes}" || rc=$?
  case "${rc}" in
    0) if merge "${pr}"; then return 0; else return 1; fi ;;
    1) printf '#%s went red while waiting — holding the label for the next event\n' "${pr}"; return 0 ;;
    2) printf '#%s still pending — the next event (push, ci completion, manual dispatch) re-evaluates\n' "${pr}"; return 0 ;;
  esac
}

if [[ "${ALL}" == true ]]; then
  prs="$(gh pr list --label merge-me --state open --json number --jq '.[].number' | sort -n)"
  if [[ -z "${prs}" ]]; then
    printf 'no open PRs labeled merge-me\n'
    exit 0
  fi
  failed=0
  while IFS= read -r pr; do
    [[ -z "${pr}" ]] && continue
    evaluate "${pr}" 0 || failed=1
  done <<<"${prs}"
  exit "${failed}"
else
  evaluate "${PR}" "${WAIT_MINUTES}"
fi
