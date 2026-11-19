#!/usr/bin/env bash
# Deletes the quickstart's k3d cluster. Keeps the gitops repo and the GitHub App.
set -euo pipefail

CLUSTER="badil-quickstart"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_FILE="${SCRIPT_DIR}/.quickstart/gitops-repo"

if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  k3d cluster delete "$CLUSTER"
else
  echo "No k3d cluster ${CLUSTER}, nothing to delete."
fi

if [[ -s "$REPO_FILE" ]]; then
  repo="$(cat "$REPO_FILE")"
elif [[ -n "${BADIL_GITOPS_REPO:-}" ]]; then
  repo="$BADIL_GITOPS_REPO"
else
  repo="<owner>/<repo>"
fi

echo
echo "The gitops repo and the GitHub App are kept. To delete them:"
echo "  gitops repo: gh repo delete ${repo}"
echo "  GitHub App:  https://github.com/settings/apps"
