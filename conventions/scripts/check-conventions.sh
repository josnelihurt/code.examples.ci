#!/usr/bin/env bash
# Validates the repositories' branch-naming and commit-message rules — the one
# canonical implementation (consumed through conventions/action.yml by every
# code.examples repository's CI conventions job, and by the opt-in local hooks
# via the thin per-repository shim).
#
#   check-conventions.sh --branch <name> [--branch-exempt ERE]  # pushed-branch naming rule
#   check-conventions.sh --range <a>..<b>    # every commit subject in the range
#   check-conventions.sh --title <text>      # a PR title (it becomes the squash commit)
#   check-conventions.sh --subjects-file <f> # one subject per line (CI's PR mode)
#
# Modes combine (--branch x --range a..b checks both). Append --allow-pr-number
# to tolerate one trailing " (#N)": squash-merge results pushed to main carry it,
# PR titles and in-stack commits must not. --skip-pr-numbers instead skips such
# commits entirely (no pass, no fail): GitHub's server-side stack rebase
# materializes already-merged lower layers on upper branches exactly like that.
# Exit 0 = clean, 1 = violations (all reported), 2 = usage error.
set -euo pipefail

# Every pushed branch: one of the six prefixes, then a kebab-case name.
# Branches authored by automation, not humans (e.g. dependabot/…, passed via
# --branch-exempt), are exempt — their names are not ours to choose; their
# commits still follow the subject rule.
BRANCH_REGEX='^(feature|hotfix|chore|docs|ci|fix)/[a-z0-9][a-z0-9-]*[a-z0-9]$'
BRANCH_EXEMPT_REGEX=''

# Every commit subject and PR title: conventional type, optional scope, optional
# breaking marker, colon, space, summary. Group 4 captures the summary.
TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
SUBJECT_REGEX="^(${TYPES})(\([a-z0-9/._-]+\))?(!)?: (.+)$"
MAX_SUBJECT=72

ALLOW_PR_NUMBER=0
SKIP_PR_NUMBERS=0
failures=0

usage() {
  cat >&2 <<'USAGE'
Usage: check-conventions.sh [--branch NAME [--branch-exempt ERE]] [--range A..B]
                            [--title TEXT] [--subjects-file PATH]
                            [--allow-pr-number] [--skip-pr-numbers]
At least one check mode is required. The rules: github.com/josnelihurt/code.examples.ci
USAGE
}

check_branch() {
  local branch="$1"
  if [[ -n "${BRANCH_EXEMPT_REGEX}" && "${branch}" =~ ${BRANCH_EXEMPT_REGEX} ]]; then
    return 0
  fi
  if [[ ! "${branch}" =~ ${BRANCH_REGEX} ]]; then
    echo "branch '${branch}' breaks the naming rule"
    echo "  expected ${BRANCH_REGEX}"
    echo "  (prefix feature/ hotfix/ chore/ docs/ ci/ fix/, then a kebab-case name;"
    echo "   local-only backup/ branches are exempt because they are never pushed)"
    failures=$((failures + 1))
  fi
}

check_subject() {
  local label="$1" subject="$2" why=""
  if [[ "${ALLOW_PR_NUMBER}" == "1" && "${subject}" =~ ^(.*)\ \(#[0-9]+\)$ ]]; then
    subject="${BASH_REMATCH[1]}"
  fi
  if [[ "${ALLOW_PR_NUMBER}" == "0" && "${SKIP_PR_NUMBERS}" == "1" && "${subject}" =~ \ \(#[0-9]+\)$ ]]; then
    echo "skipped (base-branch merge artifact): ${subject}"
    return 0
  fi
  if [[ "${ALLOW_PR_NUMBER}" == "0" && "${subject}" =~ \ \(#[0-9]+\)$ ]]; then
    why="${why}  - trailing ' (#N)' only belongs on squash-merged commits on main\n"
  fi
  if [[ "${#subject}" -gt "${MAX_SUBJECT}" ]]; then
    why="${why}  - longer than ${MAX_SUBJECT} characters (${#subject})\n"
  fi
  if [[ ! "${subject}" =~ ${SUBJECT_REGEX} ]]; then
    why="${why}  - must be 'type(scope)!: summary' with type in {${TYPES}}\n"
  else
    local summary="${BASH_REMATCH[4]}"
    if [[ "${summary}" == *. ]]; then
      why="${why}  - summary ends with a period\n"
    fi
    if [[ ! "${summary}" =~ ^[a-z0-9] ]]; then
      why="${why}  - summary must start with a lowercase letter or digit\n"
    fi
  fi
  if [[ "${subject}" == " "* || "${subject}" == *" " ]]; then
    why="${why}  - leading or trailing whitespace\n"
  fi
  if [[ -n "${why}" ]]; then
    echo "${label}: ${subject}"
    printf '%b' "${why}"
    failures=$((failures + 1))
  fi
}

check_range() {
  local range="$1" subject
  while IFS= read -r subject; do
    check_subject "commit in ${range}" "${subject}"
  done < <(git log --no-merges --format='%s' "${range}")
}

check_subjects_file() {
  local file="$1" subject
  while IFS= read -r subject; do
    [[ -n "${subject}" ]] || continue
    check_subject "commit" "${subject}"
  done < "${file}"
}

checked=0
do_branch=""
do_range=""
do_title=""
do_subjects_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      do_branch="$2"
      checked=1
      shift 2
      ;;
    --branch-exempt)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      BRANCH_EXEMPT_REGEX="$2"
      shift 2
      ;;
    --range)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      do_range="$2"
      checked=1
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      do_title="$2"
      checked=1
      shift 2
      ;;
    --subjects-file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      do_subjects_file="$2"
      checked=1
      shift 2
      ;;
    --allow-pr-number)
      ALLOW_PR_NUMBER=1
      shift
      ;;
    --skip-pr-numbers)
      SKIP_PR_NUMBERS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

# Checks run only after the whole command line is parsed, so modifier flags
# (--allow-pr-number, --skip-pr-numbers, --branch-exempt) take effect
# regardless of position.
if [[ -n "${do_branch}" ]]; then
  check_branch "${do_branch}"
fi
if [[ -n "${do_range}" ]]; then
  check_range "${do_range}"
fi
if [[ -n "${do_subjects_file}" ]]; then
  check_subjects_file "${do_subjects_file}"
fi
if [[ -n "${do_title}" ]]; then
  check_subject "title" "${do_title}"
fi

if [[ "${checked}" -eq 0 ]]; then
  usage
  exit 2
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} violation(s) — the rules: github.com/josnelihurt/code.examples.ci"
  exit 1
fi
exit 0
