#!/usr/bin/env bash
set -euo pipefail

readonly script_name="$(basename "$0")"
readonly source_root="$(git rev-parse --show-toplevel)"

usage() {
  cat <<EOF
Usage: bash scripts/${script_name} [--apply]

Without --apply, list changed files grouped into independently publishable work
items. --apply copies each eligible group into an isolated worktree, creates an
agent/<work-item> branch from the remote default branch, commits it, pushes it,
and opens a Draft pull request.

Generated files and paths that cannot be classified safely are reported as
manual-review and are never staged or published by this script.
EOF
}

if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && [[ "$1" != "--apply" && "$1" != "--help" ]]; }; then
  usage >&2
  exit 2
fi

if [[ $# -eq 1 && "$1" == "--help" ]]; then
  usage
  exit 0
fi

apply=false
if [[ $# -eq 1 && "$1" == "--apply" ]]; then
  apply=true
fi

workspace="$(mktemp -d "${TMPDIR:-/tmp}/baro-work-items.XXXXXX")"
cleanup() {
  rm -rf "$workspace"
  git -C "$source_root" worktree prune
}
trap cleanup EXIT

paths_file="$workspace/changed-paths"
{
  git -C "$source_root" diff --name-only HEAD
  git -C "$source_root" ls-files --others --exclude-standard
} | sed '/^$/d' | LC_ALL=C sort -u > "$paths_file"

if [[ ! -s "$paths_file" ]]; then
  echo "No tracked or untracked changes found."
  exit 0
fi

contains_k6_telemetry_change() {
  local path="$1"
  git -C "$source_root" diff HEAD -- "$path" | grep -Eq 'K6_|k6-load-test|enableRemoteWriteReceiver|prometheus-rw'
}

classify_path() {
  local path="$1"

  case "$path" in
    .playwright-mcp/*|.venv/*|*/.venv/*|node_modules/*|*/node_modules/*|__pycache__/*|*/__pycache__/*|chaos/reports/*|*.pyc|*.so|*.log|*.png|*.jpg|*.jpeg|*.gif|console-service-fixes.txt)
      echo "manual-review"
      return
      ;;
    README.md|docs/*|*.md)
      echo "documentation"
      return
      ;;
    load/*|dashboards/k6-*)
      echo "load-testing"
      return
      ;;
    monitoring/*)
      if contains_k6_telemetry_change "$path"; then
        echo "load-testing"
      else
        echo "observability"
      fi
      return
      ;;
    Makefile)
      if contains_k6_telemetry_change "$path"; then
        echo "load-testing"
      else
        echo "tooling"
      fi
      return
      ;;
    dashboards/*|alerts/*)
      echo "observability"
      return
      ;;
    chaos/*)
      echo "chaos-recovery"
      return
      ;;
    cmd/*|internal/*|k8s/*|Dockerfile|go.mod|go.sum)
      echo "application"
      return
      ;;
    scripts/*)
      echo "tooling"
      return
      ;;
    *)
      echo "manual-review"
      return
      ;;
  esac
}

while IFS= read -r path; do
  group="$(classify_path "$path")"
  printf '%s\n' "$path" >> "$workspace/$group.paths"
done < "$paths_file"

label_for() {
  case "$1" in
    application) echo "application changes" ;;
    chaos-recovery) echo "chaos recovery workflow" ;;
    documentation) echo "documentation" ;;
    load-testing) echo "k6 load-test telemetry" ;;
    observability) echo "observability changes" ;;
    tooling) echo "repository tooling" ;;
    *) echo "$1" ;;
  esac
}

commit_subject_for() {
  case "$1" in
    application) echo "Add application changes" ;;
    chaos-recovery) echo "Add chaos recovery workflow" ;;
    documentation) echo "Document Baro target architecture" ;;
    load-testing) echo "Add k6 load-test telemetry" ;;
    observability) echo "Add observability changes" ;;
    tooling) echo "Add repository publishing tooling" ;;
    *) echo "Add $1 changes" ;;
  esac
}

print_plan() {
  local group path count
  echo "Work-item plan from $source_root"
  for group in application chaos-recovery documentation load-testing observability tooling manual-review; do
    [[ -f "$workspace/$group.paths" ]] || continue
    echo
    if [[ "$group" == "manual-review" ]]; then
      echo "manual-review (not publishable automatically)"
    else
      echo "$group -> agent/$group"
    fi
    if [[ "$group" == "manual-review" ]]; then
      count="$(wc -l < "$workspace/$group.paths" | tr -d ' ')"
      sed -n '1,20s/^/  - /p' "$workspace/$group.paths"
      if [[ "$count" -gt 20 ]]; then
        printf '  - ... %s more files\n' "$((count - 20))"
      fi
    else
      while IFS= read -r path; do
        printf '  - %s\n' "$path"
      done < "$workspace/$group.paths"
    fi
  done
}

print_plan

if [[ "$apply" != true ]]; then
  echo
  echo "Preview only. Re-run with --apply to publish eligible groups as Draft PRs."
  exit 0
fi

if [[ -f "$workspace/manual-review.paths" ]]; then
  echo
  echo "Manual-review files will remain untouched and will not be included in any PR:" >&2
  sed -n '1,20s/^/  - /p' "$workspace/manual-review.paths" >&2
fi

if ! git -C "$source_root" diff --check HEAD; then
  echo "Refusing to publish while the source diff has whitespace errors." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Install it, run gh auth login, then retry." >&2
  exit 1
fi

gh auth status

if ! git -C "$source_root" remote get-url origin >/dev/null 2>&1; then
  echo "An origin remote is required to push branches and create pull requests." >&2
  exit 1
fi

default_ref="$(git -C "$source_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
if [[ -n "$default_ref" ]]; then
  base_branch="${default_ref#origin/}"
elif git -C "$source_root" rev-parse --verify --quiet origin/main >/dev/null; then
  base_branch="main"
elif git -C "$source_root" rev-parse --verify --quiet origin/master >/dev/null; then
  base_branch="master"
else
  echo "Could not determine origin's default branch. Configure origin/HEAD or add origin/main." >&2
  exit 1
fi

base_ref="origin/$base_branch"
repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"

publish_group() {
  local group="$1"
  local branch="agent/$group"
  local subject
  local worktree
  local body_file="$workspace/$group-pr.md"
  local path destination_dir

  [[ -f "$workspace/$group.paths" ]] || return 0

  if git -C "$source_root" show-ref --verify --quiet "refs/heads/$branch" || \
    git -C "$source_root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "Refusing to overwrite existing branch $branch." >&2
    return 1
  fi

  subject="$(commit_subject_for "$group")"
  worktree="$(mktemp -d "$workspace/$group.XXXXXX")"
  git -C "$source_root" worktree add --detach "$worktree" "$base_ref"
  git -C "$worktree" switch -c "$branch"

  while IFS= read -r path; do
    if git -C "$source_root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      git -C "$source_root" diff --binary HEAD -- "$path" | git -C "$worktree" apply --3way --index
    else
      destination_dir="$worktree/$(dirname "$path")"
      mkdir -p "$destination_dir"
      cp -p "$source_root/$path" "$worktree/$path"
      git -C "$worktree" add -- "$path"
    fi
  done < "$workspace/$group.paths"

  git -C "$worktree" diff --cached --check
  git -C "$worktree" diff --cached --quiet && {
    echo "No staged change was produced for $group." >&2
    return 1
  }
  git -C "$worktree" commit -m "$subject"
  git -C "$worktree" push -u origin "$branch"

  cat > "$body_file" <<EOF
## What

- $(label_for "$group")

## Why

Split this independent work item into a focused, reversible review unit.

## Validation

- \`git diff --check\`
EOF
  gh pr create --repo "$repository" --draft --base "$base_branch" --head "$branch" --title "$subject" --body-file "$body_file"
  git -C "$source_root" worktree remove "$worktree"
}

for group in application chaos-recovery documentation load-testing observability tooling; do
  publish_group "$group"
done

echo "Published eligible work items. Manual-review files, if any, remain in the original worktree."
