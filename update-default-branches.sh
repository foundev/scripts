#!/usr/bin/env bash
# Update the default branch of every git repo under your code folder.
#
#   ./update-default-branches.sh [--code-dir DIR] [--dry-run] [--no-prune] [--no-ci] [--summarize]
#
# Behaviour per repo:
#   1. Detect the default branch (origin/HEAD -> origin/main|master -> main|master -> current).
#   2. Always `git fetch` (so even dirty repos get the latest refs locally).
#   3. If the working tree is clean  -> fast-forward the default branch to origin.
#   4. If the working tree is dirty  -> fetch only, never touch the checkout.
#   5. Check whether the fetched default branch is green (GitHub CI rollup of its tip).
#
# A repo counts as "dirty" if `git status --porcelain` prints anything
# (tracked modifications AND untracked files). Untracked-only repos are
# therefore fetch-only too -- safe default for a bulk script.
#
# CI status comes from the GitHub API via `gh` (env: GH_BIN), one read-only
# query per repo: CI-GREEN / CI-RED / CI-PENDING / CI-NONE / CI-UNKNOWN. A red
# or pending default branch is reported inline and again in the closing
# roll-up, but does not change the exit code (that only tracks the git work).
# Repos with no GitHub origin, or with no `gh` available, are skipped.
#
# With --summarize, every repo whose default branch actually moved gets a
# per-repo change summary via `muse exec` (read-only), followed by one
# combined digest across all updated repos.
#
# Exit code: 0 if no failures, 1 if any repo failed.

set -u
# NOTE: no `set -e` -- one bad repo must not stop the sweep.

CODE_DIR="${CODE_DIR:-$HOME/code}"
MUSE_BIN="${MUSE_BIN:-muse}"
SUMMARY_EFFORT="${SUMMARY_EFFORT:-low}"
GH_BIN="${GH_BIN:-gh}"
DRY_RUN=0
PRUNE=1
SUMMARIZE=0
CHECK_CI=1

# Batch mode: never prompt for credentials/passphrases -- a repo whose remote
# needs interactive auth fails fast (FAIL + continue) instead of hanging the
# whole sweep waiting on stdin. Override from your environment if needed.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"
# Last-resort prompt program: if no credential helper can supply creds (e.g. a
# private repo with an expired token), fail fast instead of popping up a GUI
# askpass dialog that looks like a hang. Override to allow prompting.
export GIT_ASKPASS="${GIT_ASKPASS:-true}"
# Hard cap per fetch (seconds, 0 disables): slow/dead remotes and proxies can
# stall long past the SSH timeout above. A timeout counts as FAIL + continue.
FETCH_TIMEOUT="${FETCH_TIMEOUT:-120}"

# git fetch bounded by FETCH_TIMEOUT. Returns 124 on timeout.
git_fetch() {
  if [[ "$FETCH_TIMEOUT" != "0" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$FETCH_TIMEOUT" git fetch "$@"
  else
    git fetch "$@"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --code-dir DIR   Folder containing your repos (default: \$CODE_DIR or \$HOME/code)
  --dry-run        Print what would happen without changing anything
  --no-prune       Do not pass --prune to git fetch
  --no-ci          Do not check default-branch CI status via 'gh' (env: GH_BIN)
  --summarize      Run 'muse exec' on each updated repo for a change summary,
                   plus one combined digest (env: MUSE_BIN, SUMMARY_EFFORT)
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --code-dir) CODE_DIR="${2:?--code-dir needs a value}"; shift 2 ;;
    --code-dir=*) CODE_DIR="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-prune) PRUNE=0; shift ;;
    --no-ci) CHECK_CI=0; shift ;;
    --summarize) SUMMARIZE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -d "$CODE_DIR" ]]; then
  echo "error: code dir not found: $CODE_DIR" >&2
  exit 2
fi

# --- colours (disabled unless stderr is a tty) ---
if [[ -t 2 ]]; then
  C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_DIM=$'\e[2m'
else
  C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi
ok()   { printf '%sOK%s %s\n'   "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn() { printf '%sSKIP%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%sFAIL%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
info() { printf '%s%s%s\n'      "$C_DIM"    "$*"        "$C_RESET" >&2; }

# Detect the default branch name (e.g. "main"), empty string if unknown.
default_branch() {
  local ref
  # 1. origin/HEAD symbolic ref (set by `git remote set-head`, usually present after clone)
  if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  # 2. Prefer whichever remote-tracking branch exists locally
  if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    printf 'main\n'; return 0
  fi
  if git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
    printf 'master\n'; return 0
  fi
  # 3. Fall back to a local main/master branch
  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    printf 'main\n'; return 0
  fi
  if git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    printf 'master\n'; return 0
  fi
  return 1
}

# Repos whose default branch actually moved: "name<TAB>dir<TAB>branch<TAB>before<TAB>after".
UPDATED_LIST=$(mktemp)
# Default branches that are not green: "tag<TAB>name<TAB>branch<TAB>detail".
CI_BAD_LIST=$(mktemp)
trap 'rm -f "$UPDATED_LIST" "$CI_BAD_LIST"' EXIT

# Print "owner/repo" for a GitHub origin remote, nothing if it isn't GitHub.
github_slug() {
  local url
  url=$(git config --get remote.origin.url 2>/dev/null) || return 1
  case "$url" in
    git@github.com:*)       url="${url#git@github.com:}" ;;
    ssh://git@github.com:*) url="${url#ssh://git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    https://*@github.com/*) url="${url#*@github.com/}" ;;
    https://github.com/*)   url="${url#https://github.com/}" ;;
    http://github.com/*)    url="${url#http://github.com/}" ;;
    git://github.com/*)     url="${url#git://github.com/}" ;;
    github.com:*)           url="${url#github.com:}" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${url%.git}"
}

# One GraphQL round trip for the CI rollup of a commit: state plus the names of
# failing and still-running checks. Prints "<state>\t<failing>\t<pending>".
CI_QUERY='query($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){object(oid:$oid){... on Commit{statusCheckRollup{state contexts(first:100){nodes{__typename ... on CheckRun{name status conclusion} ... on StatusContext{context state}}}}}}}}'
CI_JQ='
.data as $d
| if $d.repository == null or $d.repository.object == null then "UNKNOWN\t\t"
  else $d.repository.object.statusCheckRollup as $r
  | if $r == null then "NONE\t\t"
    else ($r.state + "\t"
      + ([ $r.contexts.nodes[]
           | if .__typename == "CheckRun"
             then select(.status == "COMPLETED" and (.conclusion as $c | (["SUCCESS","NEUTRAL","SKIPPED",""] | index($c) | not)))
             else select(.state == "FAILURE" or .state == "ERROR") end
           | (if .__typename == "CheckRun" then .name else .context end) ] | join(", "))
      + "\t"
      + ([ $r.contexts.nodes[]
           | if .__typename == "CheckRun" then select(.status != "COMPLETED")
             else select(.state == "PENDING") end
           | (if .__typename == "CheckRun" then .name else .context end) ] | join(", ")))
    end
  end'

ci_line() { printf '%s%s%s %s\n' "$1" "$2" "$C_RESET" "${*:3}" >&2; }

# Check the CI rollup of a ref and report it. Never fails the script.
# Tag comes from the rollup state: GREEN / RED / PENDING / NONE / UNKNOWN.
check_ci() {
  local name="$1" slug="$2" sha="$3" branch="$4" line state failing pending tag color note
  if [[ -z "$slug" ]]; then
    ci_line "$C_DIM" "CI-?" "$name: not a GitHub origin, skipping CI check"
    return 0
  fi
  if ! line=$("$GH_BIN" api graphql -f query="$CI_QUERY" \
        -f owner="${slug%%/*}" -f name="${slug##*/}" -f oid="$sha" \
        --jq "$CI_JQ" 2>&1); then
    note=${line%%$'\n'*}
    ci_line "$C_DIM" "CI-?" "$name: could not query CI for origin/$branch (${note:0:120})"
    printf 'UNKNOWN\t%s\t%s\t%s\n' "$name" "$branch" "query failed: ${note:0:120}" >>"$CI_BAD_LIST"
    ci_unknown=$((ci_unknown+1))
    return 0
  fi
  IFS=$'\t' read -r state failing pending <<<"$line"
  case "$state" in
    SUCCESS)  tag="CI-GREEN";  color="$C_GREEN";  ci_green=$((ci_green+1)) ;;
    FAILURE|ERROR)
              tag="CI-RED";    color="$C_RED"
              ci_red=$((ci_red+1))
              printf 'RED\t%s\t%s\t%s\n' "$name" "$branch" "failing: ${failing:-unknown}" >>"$CI_BAD_LIST" ;;
    PENDING|EXPECTED)
              tag="CI-PENDING"; color="$C_YELLOW"
              ci_pending=$((ci_pending+1))
              printf 'PENDING\t%s\t%s\t%s\n' "$name" "$branch" "running: ${pending:-unknown}" >>"$CI_BAD_LIST" ;;
    NONE)     tag="CI-NONE";   color="$C_DIM"
              ci_none=$((ci_none+1)) ;;
    *)        tag="CI-?";      color="$C_DIM"
              ci_unknown=$((ci_unknown+1))
              printf 'UNKNOWN\t%s\t%s\t%s\n' "$name" "$branch" "unexpected state: ${state:-empty response}" >>"$CI_BAD_LIST" ;;
  esac
  case "$state" in
    SUCCESS) ci_line "$color" "$tag" "$name: default branch origin/$branch is green" ;;
    NONE)    ci_line "$color" "$tag" "$name: no CI checks reported for origin/$branch" ;;
    FAILURE|ERROR)
             ci_line "$color" "$tag" "$name: default branch origin/$branch is RED (${failing:-see GitHub})" ;;
    *)       ci_line "$color" "$tag" "$name: default branch origin/$branch is not green yet (${pending:-see GitHub})" ;;
  esac
}

# Run `muse exec` over every repo recorded in $UPDATED_LIST and print
# per-repo summaries plus one combined digest. Read-only (--disable-write),
# bounded (timeout + low effort), and never fails the script on its own.
summarize_updated() {
  local muse_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    muse_cmd=(timeout 300 "$MUSE_BIN" exec)
  else
    muse_cmd=("$MUSE_BIN" exec)
  fi

  local digest_file
  digest_file=$(mktemp)
  local summary_failures=0

  echo
  echo "=== Change summaries ==="

  while IFS=$'\t' read -r name dir branch before after; do
    [[ -n "$name" ]] || continue
    local short_before=${before:0:7} short_after=${after:0:7}
    local log stat prompt summary
    log=$(git -C "$dir" log --oneline --no-decorate "${before}..${after}" -- 2>/dev/null | head -n 50)
    stat=$(git -C "$dir" diff --stat "${before}" "${after}" -- 2>/dev/null | head -n 60)
    prompt="You are summarizing new commits that just landed on branch '$branch' of the '$name' repository (updated ${short_before}..${short_after}). Using ONLY the commit list and diffstat below, write a concise summary: a one-line overview plus short bullets grouped by theme, mentioning notable files. Keep it under 15 lines. Do not browse or change anything.

Commits:
${log:-'(no commit list available)'}

Diffstat:
${stat:-'(no diffstat available)'}"
    printf '## %s (%s %s..%s)\n' "$name" "$branch" "$short_before" "$short_after"
    if summary=$("${muse_cmd[@]}" --workspace "$dir" --reasoning-effort "$SUMMARY_EFFORT" --disable-write "$prompt" 2>/dev/null); then
      printf '%s\n\n' "$summary"
      printf '### %s\n%s\n\n' "$name" "$summary" >>"$digest_file"
    else
      printf '(summary failed for %s)\n\n' "$name"
      summary_failures=$((summary_failures+1))
    fi
  done <"$UPDATED_LIST"

  # Combined digest across all updated repos (no workspace: prompt carries everything).
  if [[ -s "$digest_file" ]]; then
    echo "=== Overall digest ==="
    if digest=$("${muse_cmd[@]}" --reasoning-effort "$SUMMARY_EFFORT" --disable-write "Below are per-repository change summaries from a bulk update of many git repos. Write a short overall digest: what changed across the fleet, grouped by theme, under 20 lines. Then list the repos covered. Base it ONLY on the summaries below.

$(cat "$digest_file")" 2>/dev/null); then
      printf '%s\n' "$digest"
    else
      warn "Overall digest failed; per-repo summaries above still stand."
      summary_failures=$((summary_failures+1))
    fi
  fi
  rm -f "$digest_file"

  [[ "$summary_failures" -eq 0 ]] || warn "$summary_failures summarizer call(s) failed."
}

updated=0; uptodate=0; fetched=0; failed=0; skipped=0
# CI rollup counters (only used when --no-ci is absent).
ci_green=0; ci_red=0; ci_pending=0; ci_none=0; ci_unknown=0; ci_checked=0

if [[ "$CHECK_CI" == 1 ]]; then
  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    warn "'$GH_BIN' not found on PATH -- skipping default-branch CI checks"
    CHECK_CI=0
  fi
fi

for dir in "$CODE_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  name=$(basename "$dir")

  if [[ ! -d "$dir/.git" && ! -f "$dir/.git" ]]; then
    # Not a repo (covers dirs; bare/worktree-linked repos use a .git file too).
    continue
  fi

  (
    cd "$dir" || exit 1

    # No remote -> nothing to update from.
    if ! git remote get-url origin >/dev/null 2>&1; then
      warn "$name: no 'origin' remote, skipping"
      exit 10
    fi

    branch=$(default_branch) || branch=""
    if [[ -z "$branch" ]]; then
      warn "$name: could not determine default branch, skipping"
      exit 10
    fi

    # Progress marker: if the sweep ever stalls, the last line names the repo.
    info "→ $name ($branch): fetching origin..."

    # Always fetch first so dirty repos still get fresh refs.
    fetch_args=()
    [[ "$PRUNE" == 1 ]] && fetch_args+=(--prune)
    fetch_args+=(origin)
    if [[ "$DRY_RUN" == 1 ]]; then
      info "$name: [dry-run] would run: git fetch ${fetch_args[*]}"
    else
      git_fetch "${fetch_args[@]}" >/dev/null 2>&1
      fetch_rc=$?
      if [[ "$fetch_rc" -ne 0 ]]; then
        if [[ "$fetch_rc" -eq 124 ]]; then
          fail "$name: git fetch timed out after ${FETCH_TIMEOUT}s"
        else
          fail "$name: git fetch failed"
        fi
        exit 1
      fi
    fi

    # Remote default branch must exist after fetching.
    if ! git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
      warn "$name: origin/$branch does not exist, skipping"
      exit 10
    fi

    # Dirty? `git status --porcelain` covers staged, unstaged AND untracked.
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      ok "$name: dirty -> fetched only ($branch left untouched)"
      exit 20
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
      info "$name: [dry-run] would fast-forward '$branch' to 'origin/$branch'"
      exit 30
    fi

    current=$(git branch --show-current 2>/dev/null || true)

    if [[ "$current" == "$branch" ]]; then
      # On the default branch: merge the fetched remote (ff-only, never creates a merge commit).
      before=$(git rev-parse HEAD)
      if git merge --ff-only "origin/$branch" >/dev/null 2>&1; then
        after=$(git rev-parse HEAD)
        if [[ "$before" == "$after" ]]; then
          info "$name: already up to date ($branch)"
          exit 30
        else
          ok "$name: updated $branch ($before -> $after)"
          printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(pwd)" "$branch" "$before" "$after" >>"$UPDATED_LIST"
          exit 0
        fi
      else
        fail "$name: $branch cannot fast-forward (diverged?), left untouched"
        exit 1
      fi
    else
      # On another branch (or detached): move the local default branch ref
      # forward without checking it out. `git fetch origin <src>:<dst>`
      # only succeeds on a fast-forward, so it never force-clobbers work.
      if [[ -z "$current" ]]; then where="detached HEAD"; else where="on '$current'"; fi
      before=$(git rev-parse "$branch")
      git_fetch origin "$branch:$branch" >/dev/null 2>&1
      fetch_rc=$?
      if [[ "$fetch_rc" -eq 124 ]]; then
        fail "$name: git fetch timed out after ${FETCH_TIMEOUT}s, left untouched ($where)"
        exit 1
      elif [[ "$fetch_rc" -eq 0 ]]; then
        after=$(git rev-parse "$branch")
        if [[ "$before" == "$after" ]]; then
          info "$name: already up to date ($branch, $where)"
          exit 30
        else
          ok "$name: updated $branch ($before -> $after; $where, checkout untouched)"
          printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(pwd)" "$branch" "$before" "$after" >>"$UPDATED_LIST"
          exit 0
        fi
      else
        # Fetch of <src>:<dst> is a no-op success when already equal, so
        # reaching here means non-fast-forward (local ahead/diverged).
        if git merge-base --is-ancestor "$branch" "origin/$branch" 2>/dev/null; then
          info "$name: already up to date ($branch, $where)"
          exit 30
        else
          fail "$name: $branch diverged from origin/$branch, left untouched ($where)"
          exit 1
        fi
      fi
    fi
  )
  rc=$?
  case $rc in
    0) updated=$((updated+1)) ;;
    20) fetched=$((fetched+1)) ;;
    30) uptodate=$((uptodate+1)) ;;
    10) skipped=$((skipped+1)) ;;
    *) failed=$((failed+1)) ;;
  esac

  # Is the (freshly fetched) default branch of this repo green? Skipped for
  # repos we can't identify a remote branch for, and in dry-run (no fetch ran).
  if [[ "$CHECK_CI" == 1 && "$DRY_RUN" == 0 && $rc != 10 && $rc != 1 ]]; then
    ci_branch=$(cd "$dir" && default_branch) || ci_branch=""
    if [[ -n "$ci_branch" ]] && git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$ci_branch" 2>/dev/null; then
      ci_sha=$(git -C "$dir" rev-parse "refs/remotes/origin/$ci_branch" 2>/dev/null) || ci_sha=""
      if [[ -n "$ci_sha" ]]; then
        ci_slug=$(cd "$dir" && github_slug) || ci_slug=""
        ci_checked=$((ci_checked+1))
        check_ci "$name" "$ci_slug" "$ci_sha" "$ci_branch"
      fi
    fi
  fi
done

update_failed=0
[[ "$failed" -eq 0 ]] || update_failed=1

echo "---" >&2
echo "updated=${updated} up-to-date=${uptodate} fetched-only(dirty)=${fetched} skipped=${skipped} failed=${failed}" >&2

if [[ "$CHECK_CI" == 1 && "$DRY_RUN" == 0 && "$ci_checked" -gt 0 ]]; then
  echo "ci: green=${ci_green} red=${ci_red} pending=${ci_pending} none=${ci_none} unknown=${ci_unknown}" >&2
  if [[ -s "$CI_BAD_LIST" ]]; then
    echo "--- default branches not green ---" >&2
    while IFS=$'\t' read -r tag name branch detail; do
      [[ -n "$name" ]] || continue
      case "$tag" in
        RED)     color="$C_RED" ;;
        PENDING) color="$C_YELLOW" ;;
        *)       color="$C_DIM" ;;
      esac
      ci_line "$color" "$tag" "$name ($branch): $detail"
    done <"$CI_BAD_LIST"
  fi
fi

if [[ "$SUMMARIZE" == 1 ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    info "[dry-run] would run '$MUSE_BIN exec' on each updated repo for change summaries"
  elif [[ ! -s "$UPDATED_LIST" ]]; then
    info "No repos updated -- nothing to summarize."
  elif ! command -v "$MUSE_BIN" >/dev/null 2>&1; then
    warn "'$MUSE_BIN' not found on PATH -- skipping change summaries"
  else
    summarize_updated
  fi
fi

exit "$update_failed"
