#!/usr/bin/env bash
#
# patch-agent.sh - thin launcher installed to /opt/os-patch/bin (outside the git checkout).
# Pulls the latest scripts from GitHub, then runs patch.sh with the same arguments.
# If GitHub is unreachable it falls back to the last cached copy and says so in the report.
#
set -uo pipefail

BASE="${OS_PATCH_BASE:-/opt/os-patch}"
CONF="${OS_PATCH_CONF:-/etc/os-patch/patch.conf}"
REPO_DIR="$BASE/repo"
REPO_REF="main"       # branch or tag to run (pin a tag for stricter change control)
GITHUB_TOKEN=""       # fine-grained PAT with read-only "Contents" access (private repo, https)
DEPLOY_KEY=""         # alternative: path to an SSH deploy key (if origin is an ssh:// URL)
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

git_remote() {
  local opts=()
  if [ -n "$GITHUB_TOKEN" ]; then
    opts+=(-c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')")
  fi
  if [ -n "$DEPLOY_KEY" ]; then
    export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  fi
  GIT_TERMINAL_PROMPT=0 timeout 120 git ${opts[@]+"${opts[@]}"} "$@"
}

export PATCH_REPO_SYNC="skipped (post-reboot uses cached copy)"
if [ "${1:-}" != "--post-reboot" ]; then
  if [ -d "$REPO_DIR/.git" ] \
     && git_remote -C "$REPO_DIR" fetch --quiet --depth 1 origin "$REPO_REF" \
     && git -C "$REPO_DIR" reset --quiet --hard FETCH_HEAD; then
    PATCH_REPO_SYNC="ok (origin/$REPO_REF)"
  else
    PATCH_REPO_SYNC="FAILED - ran cached copy"
  fi
fi

[ -f "$REPO_DIR/patch.sh" ] || { echo "patch.sh not found in $REPO_DIR" >&2; exit 1; }
exec bash "$REPO_DIR/patch.sh" "$@"
