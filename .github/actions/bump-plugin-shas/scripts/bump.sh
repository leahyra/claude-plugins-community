#!/usr/bin/env bash
# Discover stale external SHAs, validate at new HEAD, open PR(s) with passing
# bumps. Two operating modes:
#
#   batch (default):    single PR (pr-branch, force-reset nightly) containing
#                       all passing bumps. Failures are reverted by the
#                       downstream revert-failed-bumps workflow.
#
#   per-entry:          one PR per bumped plugin on branch bump/<sanitized>.
#                       Failures stay open in their own PR for triage. Used
#                       by anthropics/claude-plugins-official to enable
#                       per-PR isolation and downstream `/triage-bump-prs
#                       --repo official` (see action.yml for details).
#
# See action.yml for input/output documentation.

source "$VALIDATE_LIB"

: "${MARKETPLACE_PATH:?}"
: "${MAX_BUMPS:?}"
[[ "$MAX_BUMPS" =~ ^[0-9]+$ ]] || die "max-bumps must be a non-negative integer (got: $MAX_BUMPS)"
: "${ALLOWED_HOSTS:?}"
: "${PR_BRANCH:?}"
: "${BASE_BRANCH:?}"
: "${GH_TOKEN:?}"

# Space-padded for whole-word matching (same convention as validate-plugins).
# Listed names are deliberately unpinned: without this skip, an empty
# old_sha never equals upstream HEAD, so the entry looks permanently stale
# and the nightly run would re-pin it — silently undoing the exemption.
SHA_EXEMPT=" ${SHA_EXEMPT:-} "

PR_MODE="${PR_MODE:-batch}"
case "$PR_MODE" in
  batch|per-entry) ;;
  *) die "pr-mode must be 'batch' or 'per-entry' (got: $PR_MODE)" ;;
esac

[[ -f "$MARKETPLACE_PATH" ]] || die "marketplace not found at $MARKETPLACE_PATH"

workroot="$(mktemp -d)"
trap 'rm -rf "$workroot"' EXIT

# Capture base marketplace content BEFORE the discovery loop accumulates
# bumps into MARKETPLACE_PATH. Per-entry mode uses this to build each
# commit's file content from base (so per-entry commits are independent,
# not stacked).
base_marketplace_content="$(cat -- "$MARKETPLACE_PATH")"

bumped='[]'
skipped='[]'
checked=0
applied=0

skip() {
  local name="$1" reason="$2"
  warn "$name: skipped ($reason)"
  skipped="$(jq -c --arg n "$name" --arg r "$reason" '. + [{name:$n, reason:$r}]' <<<"$skipped")"
}

# Sanitize a plugin name into a git-safe branch suffix (per-entry mode).
# GitHub branch rules: allow [A-Za-z0-9._/-]; replace anything else with `-`,
# then strip leading dashes so `@scope/plugin` → `bump/scope-plugin` rather
# than `bump/-scope-plugin`. Trailing dots/dashes are also stripped to avoid
# `.lock`-suffix collisions and visual awkwardness.
branch_for() {
  local name="$1"
  local sanitized
  sanitized="$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9_.-]/-/g; s/^[-.]+//; s/[-.]+$//')"
  [[ -n "$sanitized" ]] || die "could not derive branch suffix for plugin name: $name"
  echo "bump/$sanitized"
}

group_start "Discover stale SHAs and validate at new HEAD"

while IFS= read -r entry; do
  (( applied >= MAX_BUMPS )) && { log "Reached max-bumps=$MAX_BUMPS; stopping discovery."; break; }
  checked=$((checked+1))

  name="$(jq -r '.name' <<<"$entry")"

  # Deliberately-unpinned entries: nothing to bump. Plain log, not skip() —
  # this is steady-state policy, not a per-run anomaly worth a ::warning.
  if [[ "$name" =~ ^[a-z0-9][a-z0-9-]{1,63}$ && "$SHA_EXEMPT" == *" $name "* ]]; then
    log "$name: unpinned by policy (sha-exempt); not bumping"
    skipped="$(jq -c --arg n "$name" --arg r "unpinned by policy (sha-exempt)" '. + [{name:$n, reason:$r}]' <<<"$skipped")"
    continue
  fi

  url="$(jq -r '.source.url // .source.repo // empty' <<<"$entry")"
  old_sha="$(jq -r '.source.sha // empty' <<<"$entry")"
  subdir="$(jq -r '.source.path // ""' <<<"$entry")"

  [[ -n "$url" ]] || { skip "$name" "no url/repo on source"; continue; }

  if [[ "$url" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    full_url="https://github.com/$url"
  else
    full_url="$url"
  fi
  if has_unsafe_chars "$full_url" || [[ ! "$full_url" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then
    skip "$name" "unsafe url"; continue
  fi
  host="${full_url#https://}"; host="${host%%/*}"
  ok=""
  for h in $ALLOWED_HOSTS; do
    [[ "$host" == "$h" || "$host" == *".$h" ]] && { ok=1; break; }
  done
  [[ -n "$ok" ]] || { skip "$name" "host '$host' not in allowlist"; continue; }
  [[ -z "$subdir" ]] || { has_unsafe_chars "$subdir" && { skip "$name" "unsafe subdir"; continue; }; }

  # || true masks SIGPIPE from head -1; the regex below catches partial reads.
  new_sha="$(git ls-remote -- "$full_url" HEAD 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ ! "$new_sha" =~ ^[0-9a-f]{40}$ ]]; then
    skip "$name" "ls-remote failed or returned no HEAD"; continue
  fi
  if [[ "$new_sha" == "$old_sha" ]]; then
    continue
  fi

  # Per-entry early-skip: if there's already an open bump PR for this slug,
  # skip clone+validate to avoid wasting budget on plugins waiting on
  # developer/triage response. Batch mode doesn't need this (single PR).
  if [[ "$PR_MODE" == "per-entry" ]]; then
    entry_branch="$(branch_for "$name")"
    if existing_pr="$(gh pr list --head "$entry_branch" --base "$BASE_BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)" \
       && [[ -n "$existing_pr" ]]; then
      skip "$name" "open bump PR already exists at $entry_branch ($existing_pr)"; continue
    fi
  fi

  log "---- $name: $old_sha -> $new_sha ----"

  dest="$workroot/ext-$checked"
  mkdir -p -- "$dest"
  if ! timeout 120 git clone --quiet --depth 1 -- "$full_url" "$dest" 2>&1; then
    skip "$name" "clone failed"; rm -rf -- "$dest"; continue
  fi
  if ! git -C "$dest" fetch --quiet --depth 1 origin -- "$new_sha" 2>&1; then
    skip "$name" "fetch of new sha failed"; rm -rf -- "$dest"; continue
  fi
  if ! git -C "$dest" -c advice.detachedHead=false checkout --quiet "$new_sha" -- 2>&1; then
    skip "$name" "checkout of new sha failed"; rm -rf -- "$dest"; continue
  fi

  target="$dest${subdir:+/$subdir}"
  manifest="$target/.claude-plugin/plugin.json"
  [[ -f "$manifest" ]] || manifest="$target/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    skip "$name" "no plugin manifest at $full_url@${new_sha:0:8}"; rm -rf -- "$dest"; continue
  fi
  if ! out="$(timeout 120 claude plugin validate "$manifest" 2>&1)"; then
    detail="$(grep -E '❯|Error:' <<<"$out" | head -1 | sed -E 's/^[[:space:]]+//')"
    skip "$name" "validation failed at $full_url@${new_sha:0:8}: ${detail:-$(head -1 <<<"$out")}"
    rm -rf -- "$dest"; continue
  fi
  rm -rf -- "$dest"

  # Accumulate into MARKETPLACE_PATH so the step summary and (in batch mode)
  # the createCommitOnBranch payload reflect all bumps. Per-entry mode uses
  # base_marketplace_content (captured above) for individual commits, so
  # this accumulation is informational there — not consumed by the commit.
  jq --arg n "$name" --arg s "$new_sha" \
    '(.plugins[] | select(.name==$n) | .source.sha) = $s' \
    -- "$MARKETPLACE_PATH" > "$MARKETPLACE_PATH.tmp"
  mv -- "$MARKETPLACE_PATH.tmp" "$MARKETPLACE_PATH"

  bumped="$(jq -c --arg n "$name" --arg o "$old_sha" --arg s "$new_sha" \
    '. + [{name:$n, old_sha:$o, new_sha:$s}]' <<<"$bumped")"
  applied=$((applied+1))
  log "  ✓ $name validated and bumped"
done < <(jq -c '.plugins[] | select(.source | type=="object")' -- "$MARKETPLACE_PATH")

group_end

{
  echo "bumped=$bumped"
  echo "skipped=$skipped"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

{
  echo "## Bump Plugin SHAs (mode: $PR_MODE)"
  echo
  echo "Checked $checked external entries. Bumped $applied, skipped $(jq 'length' <<<"$skipped")."
  echo
  if (( applied > 0 )); then
    echo "| Plugin | Old SHA | New SHA |"
    echo "|---|---|---|"
    jq -r '.[] | "| \(.name) | `\(.old_sha[0:12] // "(none)")` | `\(.new_sha[0:12])` |"' <<<"$bumped"
  fi
  if [[ "$(jq 'length' <<<"$skipped")" -gt 0 ]]; then
    echo
    echo "<details><summary>Skipped</summary>"
    echo
    jq -r '.[] | "- **\(.name)** — \(.reason)"' <<<"$skipped"
    echo
    echo "</details>"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if (( applied == 0 )); then
  log "Nothing to bump."
  echo "pr-url=" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo "pr-urls=[]" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
fi

# ============================================================================
# Commit + PR phase: signed via GraphQL createCommitOnBranch (see below).
# ============================================================================

# Commit via GitHub's GraphQL `createCommitOnBranch` mutation rather than a
# local `git commit` + push. Commits created server-side are signed by GitHub's
# web-flow GPG key and show as "Verified" — required when the base branch
# enforces `required_signatures` (e.g. via an org-level ruleset). A local
# commit in CI has no signing key and would be unmergeable.
#
# This also avoids importing any signing key material onto the runner: there
# is nothing to leak, rotate, or revoke. The token already in scope is the
# only credential involved, and `expectedHeadOid` gives compare-and-swap
# semantics so a concurrent push fails loudly instead of being clobbered.

base_sha="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/heads/${BASE_BRANCH}" --jq '.object.sha')"
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve $BASE_BRANCH HEAD"

# create_or_reset_branch BRANCH BASE_SHA
# Point BRANCH at BASE_SHA: create if absent, force-reset if present. Force-
# reset is intentional — each run produces a fresh commit on top of base,
# replacing a stale unmerged bump rather than stacking on it (matches the
# previous `git checkout -B` + force-push semantics).
create_or_reset_branch() {
  local branch="$1" base="$2"
  if ! gh api -X POST "repos/${GITHUB_REPOSITORY}/git/refs" \
         -f ref="refs/heads/${branch}" -f sha="$base" >/dev/null 2>&1; then
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/git/refs/heads/${branch}" \
      -f sha="$base" -F force=true >/dev/null \
      || die "could not create or reset $branch"
  fi
}

# create_signed_commit BRANCH BASE_SHA MSG CONTENT_FILE
# Calls createCommitOnBranch with the marketplace.json content from
# CONTENT_FILE (path; --rawfile handles bytes via the per-arg size limit).
# Echoes the new commit OID on success.
create_signed_commit() {
  local branch="$1" base="$2" msg="$3" content_file="$4"
  jq -n \
    --rawfile content "$content_file" \
    --arg repo   "$GITHUB_REPOSITORY" \
    --arg branch "$branch" \
    --arg oid    "$base" \
    --arg msg    "$msg" \
    --arg path   "$MARKETPLACE_PATH" \
    '{
      query: "mutation($repo:String!,$branch:String!,$oid:GitObjectID!,$msg:String!,$path:String!,$contents:Base64String!){createCommitOnBranch(input:{branch:{repositoryNameWithOwner:$repo,branchName:$branch},message:{headline:$msg},fileChanges:{additions:[{path:$path,contents:$contents}]},expectedHeadOid:$oid}){commit{oid}}}",
      variables: {
        repo: $repo, branch: $branch, oid: $oid, msg: $msg,
        path: $path, contents: ($content | @base64)
      }
    }' \
  | gh api graphql --input - --jq '.data.createCommitOnBranch.commit.oid'
}

if [[ "$PR_MODE" == "per-entry" ]]; then
  # ──────────────────────────────────────────────────────────────────────────
  # Per-entry mode: one branch + one commit + one PR per bumped plugin.
  # Each commit applies ONLY that plugin's bump to base_marketplace_content,
  # so PRs are independent (no stacking). Failing PRs stay open for triage.
  # ──────────────────────────────────────────────────────────────────────────
  group_start "Open per-entry bump PRs"

  pr_urls='[]'
  printf '%s\n' "$bumped" | jq -c '.[]' | while IFS= read -r b; do
    name="$(jq -r '.name'    <<<"$b")"
    old_sha="$(jq -r '.old_sha' <<<"$b")"
    new_sha="$(jq -r '.new_sha' <<<"$b")"
    branch="$(branch_for "$name")"

    # Build per-entry marketplace content: base + only this entry's bump.
    # Independent of any other bumps applied this run.
    entry_file="$workroot/marketplace-${checked}-${RANDOM}.json"
    jq --arg n "$name" --arg s "$new_sha" \
      '(.plugins[] | select(.name==$n) | .source.sha) = $s' \
      <<<"$base_marketplace_content" > "$entry_file"

    create_or_reset_branch "$branch" "$base_sha"

    commit_msg="bump($name): ${old_sha:0:8} → ${new_sha:0:8}"
    new_oid="$(create_signed_commit "$branch" "$base_sha" "$commit_msg" "$entry_file")" \
      || die "createCommitOnBranch failed for $name"
    [[ "$new_oid" =~ ^[0-9a-f]{40}$ ]] || die "createCommitOnBranch did not return an OID for $name (got: $new_oid)"
    log "Created signed commit $new_oid on $branch ($name)"

    body_file="$workroot/pr-body-$name.md"
    {
      echo "Automated SHA bump for **\`$name\`**. The new SHA was validated via \`claude plugin validate\` in [this workflow run]($RUN_URL) before this PR was opened."
      echo
      echo "| Old SHA | New SHA |"
      echo "|---|---|"
      echo "| \`${old_sha:0:12}\` | \`${new_sha:0:12}\` |"
      echo
      echo "Review the scan job below before merging — bump PRs are not auto-merged by default."
    } > "$body_file"

    if existing="$(gh pr list --head "$branch" --base "$BASE_BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)" \
       && [[ -n "$existing" ]]; then
      gh pr edit "$existing" --body-file "$body_file" >/dev/null
      pr_url="$existing"
      log "Updated existing PR: $pr_url"
    else
      pr_url="$(gh pr create --base "$BASE_BRANCH" --head "$branch" \
        --title "$commit_msg" --body-file "$body_file")"
      log "Opened PR: $pr_url"
    fi

    # Per-entry rolling output (jq's first-write rebuilds; using a tempfile
    # avoids losing entries to subshell scope when piped through `while`).
    jq -c --arg n "$name" --arg o "$old_sha" --arg s "$new_sha" \
      --arg br "$branch" --arg u "$pr_url" \
      '. + [{name:$n, old_sha:$o, new_sha:$s, branch:$br, pr_url:$u}]' \
      <<<"$pr_urls" > "$workroot/pr_urls.tmp" && pr_urls="$(cat "$workroot/pr_urls.tmp")"
  done

  # The `while` loop ran in a subshell (piped from jq), so pr_urls
  # accumulated there is lost. Reconstruct from the temp file the loop
  # wrote on its final iteration.
  if [[ -s "$workroot/pr_urls.tmp" ]]; then
    pr_urls="$(cat "$workroot/pr_urls.tmp")"
  fi

  echo "pr-url=" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo "pr-urls=$pr_urls" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  log "Opened/updated $(jq 'length' <<<"$pr_urls") per-entry bump PR(s)"
  group_end

else
  # ──────────────────────────────────────────────────────────────────────────
  # Batch mode: single commit on PR_BRANCH, single PR with all bumps.
  # Preserves the pre-per-entry behavior exactly.
  # ──────────────────────────────────────────────────────────────────────────
  group_start "Open batch bump PR"

  create_or_reset_branch "$PR_BRANCH" "$base_sha"

  commit_msg="Bump $applied plugin SHA pin(s) to upstream HEAD"
  new_oid="$(create_signed_commit "$PR_BRANCH" "$base_sha" "$commit_msg" "$MARKETPLACE_PATH")" \
    || die "createCommitOnBranch failed"
  [[ "$new_oid" =~ ^[0-9a-f]{40}$ ]] || die "createCommitOnBranch did not return a commit OID (got: $new_oid)"
  log "Created signed commit $new_oid on $PR_BRANCH"

  body="$workroot/pr-body.md"
  {
    echo "Automated SHA bump. Each entry below was cloned at the new SHA and passed \`claude plugin validate\` in [this workflow run]($RUN_URL) before being included."
    echo
    echo "| Plugin | Old SHA | New SHA |"
    echo "|---|---|---|"
    jq -r '.[] | "| \(.name) | `\(.old_sha[0:12] // "(none)")` | `\(.new_sha[0:12])` |"' <<<"$bumped"
    if [[ "$(jq 'length' <<<"$skipped")" -gt 0 ]]; then
      echo
      echo "Skipped (not bumped — see run for details): $(jq -r 'map(.name) | join(", ")' <<<"$skipped")"
    fi
  } > "$body"

  if existing="$(gh pr list --head "$PR_BRANCH" --base "$BASE_BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)" && [[ -n "$existing" ]]; then
    gh pr edit "$existing" --body-file "$body"
    pr_url="$existing"
  else
    pr_url="$(gh pr create --base "$BASE_BRANCH" --head "$PR_BRANCH" \
      --title "Bump $applied plugin SHA pin(s)" --body-file "$body")"
  fi

  echo "pr-url=$pr_url" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo "pr-urls=[]" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  log "PR: $pr_url"
  group_end
fi
