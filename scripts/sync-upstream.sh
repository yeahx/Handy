#!/usr/bin/env bash
# sync-upstream.sh — replay this fork's private patches on top of the
# latest upstream main, then trigger the Release workflow.
#
# Mirror of .github/workflows/sync-upstream.yml. Use this locally when
# you want to validate the sync logic before relying on the GH Action,
# or to recover after a sync conflict.
#
# Behavior:
#   1. Adds `upstream` remote pointing at cjpais/Handy (idempotent).
#   2. Fetches upstream/main and origin/main.
#   3. If upstream is unchanged, exits 0.
#   4. Otherwise: format-patches the fork-only commits, resets main
#      to upstream HEAD, replays the patches with `git am --3way`.
#   5. On conflict: aborts, prints the offending patch, exits 2.
#      The local working tree is left in the pre-sync state so you
#      can resolve the conflict manually.
#   6. On success: force-with-lease pushes to origin/main, then
#      dispatches the Release workflow via `gh`.
#
# Requirements:
#   - Run from a clean working tree on `main` (no staged/unstaged changes).
#   - `gh` authenticated as someone who can push to this fork.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-cjpais/Handy}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
FORK_REMOTE="${FORK_REMOTE:-origin}"
LOCAL_BRANCH="${LOCAL_BRANCH:-main}"
PATCH_DIR="$(mktemp -d -t fork-patches.XXXXXX)"
trap 'rm -rf "${PATCH_DIR}"' EXIT

cd "$(git rev-parse --show-toplevel)"

# --- preflight ---------------------------------------------------------

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes; commit or stash first." >&2
  exit 1
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$LOCAL_BRANCH" ]; then
  echo "error: must be on '$LOCAL_BRANCH' branch (currently on '$CURRENT')." >&2
  exit 1
fi

# --- remotes ----------------------------------------------------------

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "Adding 'upstream' remote: https://github.com/${UPSTREAM_REPO}.git"
  git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"
fi

git fetch upstream "$UPSTREAM_BRANCH"
git fetch "$FORK_REMOTE" "$LOCAL_BRANCH"

BASE=$(git merge-base "${FORK_REMOTE}/${LOCAL_BRANCH}" "upstream/${UPSTREAM_BRANCH}")
UPSTREAM_HEAD=$(git rev-parse "upstream/${UPSTREAM_BRANCH}")
FORK_HEAD=$(git rev-parse "${FORK_REMOTE}/${LOCAL_BRANCH}")

echo "fork HEAD     = ${FORK_HEAD}"
echo "upstream HEAD = ${UPSTREAM_HEAD}"
echo "merge-base    = ${BASE}"

if [ "$BASE" = "$UPSTREAM_HEAD" ]; then
  echo "✓ Fork is already up to date with upstream/${UPSTREAM_BRANCH}. Nothing to do."
  exit 0
fi

# --- capture private patches -----------------------------------------

git checkout "$LOCAL_BRANCH"
git reset --hard "${FORK_REMOTE}/${LOCAL_BRANCH}"

git format-patch "$BASE"..HEAD -o "$PATCH_DIR" >/dev/null
PATCH_COUNT=$(find "$PATCH_DIR" -name '*.patch' | wc -l | tr -d ' ')
echo "Captured ${PATCH_COUNT} fork patch(es)."

# --- replay ----------------------------------------------------------

ORIG_HEAD=$(git rev-parse HEAD)
git reset --hard "upstream/${UPSTREAM_BRANCH}"

if [ "$PATCH_COUNT" -gt 0 ]; then
  if ! git am --3way "$PATCH_DIR"/*.patch; then
    echo >&2
    echo "✗ Conflict: a fork patch no longer applies on upstream/${UPSTREAM_BRANCH}." >&2
    echo "  Aborting git am and restoring previous fork state." >&2
    git am --abort || true
    git reset --hard "$ORIG_HEAD"
    echo >&2
    echo "  To resolve: rebase main onto upstream/${UPSTREAM_BRANCH} manually, then re-run." >&2
    exit 2
  fi
fi

# --- push -------------------------------------------------------------

git push --force-with-lease "$FORK_REMOTE" "$LOCAL_BRANCH"
echo "✓ Pushed rebased main to ${FORK_REMOTE}/${LOCAL_BRANCH}."

# --- trigger Release ---------------------------------------------------

if command -v gh >/dev/null 2>&1; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  VERSION=$(grep -o '"version": "[^"]*"' src-tauri/tauri.conf.json | cut -d'"' -f4)

  # Delete same-version draft release if any (avoids create-release tag clash).
  if gh release view "v${VERSION}" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null | grep -q true; then
    echo "Deleting existing draft v${VERSION}..."
    gh release delete "v${VERSION}" --repo "$REPO" --yes
  fi

  gh workflow run release.yml --repo "$REPO" --ref "$LOCAL_BRANCH"
  echo "✓ Release workflow dispatched."
else
  echo "(gh CLI not installed; skipping Release trigger.)"
fi
