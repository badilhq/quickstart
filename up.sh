#!/usr/bin/env bash
# Runs a first badil preview on a local k3d cluster. Safe to re-run.
set -euo pipefail

# Pinned versions and fixed names.
K3S_IMAGE="rancher/k3s:v1.37.1-k3s1"
ARGOCD_CHART_VERSION="10.11.6"
BADIL_CHART_VERSION="0.25.0"
DEMO_PR_URL="https://github.com/badilhq/demo-backend-1/pull/53"
BADIL_HOST="badil.127.0.0.1.nip.io"

CLUSTER="badil-quickstart"
CTX="k3d-${CLUSTER}"
DEMO_REPO="badilhq/demo-backend-1"
DEMO_PR_NUMBER="53"
DEMO_IMAGE="ghcr.io/badilhq/demo-backend-1"
PREVIEW_SLUG="quickstart-demo"
PREVIEW_DOMAIN="127.0.0.1.nip.io"
WAIT_SECONDS=600
HEALTH_WAIT_SECONDS=300

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.quickstart"

die() {
  echo "error: $*" >&2
  exit 1
}

STEP_START=0
step() {
  STEP_START=$SECONDS
  echo
  echo "==> $1"
}
step_done() {
  echo "    done in $((SECONDS - STEP_START))s"
}

# Writes a value to a file in STATE_DIR with mode 600, without a trailing newline.
write_state() {
  (umask 077 && printf '%s' "$2" >"${STATE_DIR}/$1")
  chmod 600 "${STATE_DIR}/$1"
}

# Reads a value from STATE_DIR, or generates and stores a new random one.
state_secret() {
  local file="${STATE_DIR}/$1"
  if [[ ! -s "$file" ]]; then
    write_state "$1" "$(openssl rand -hex 32)"
  fi
  chmod 600 "$file"
}

read_app_inputs() {
  if [[ -z "${BADIL_APP_ID:-}" ]]; then
    read -r -p "GitHub App ID: " BADIL_APP_ID || die "BADIL_APP_ID is not set"
  fi
  if [[ -z "${BADIL_INSTALLATION_ID:-}" ]]; then
    echo "Paste the number the App installation's browser URL ends with (/settings/installations/<ID>)."
    read -r -p "Installation ID: " BADIL_INSTALLATION_ID || die "BADIL_INSTALLATION_ID is not set"
  fi
  if [[ -z "${BADIL_PRIVATE_KEY:-}" ]]; then
    read -r -p "Path to the App's private key (.pem): " BADIL_PRIVATE_KEY || die "BADIL_PRIVATE_KEY is not set"
  fi
  BADIL_PRIVATE_KEY="${BADIL_PRIVATE_KEY/#\~/$HOME}"
  [[ -n "$BADIL_APP_ID" ]] || die "the GitHub App ID is empty"
  [[ -n "$BADIL_INSTALLATION_ID" ]] || die "the installation ID is empty"
  [[ -r "$BADIL_PRIVATE_KEY" ]] || die "cannot read the private key ${BADIL_PRIVATE_KEY}"
}

# Prints a file of the gitops repo's default branch.
gitops_file() {
  gh api "repos/${GITOPS_REPO}/contents/$1" -H 'Accept: application/vnd.github.raw' \
    || die "cannot read $1 in ${GITOPS_REPO}"
}

CLONE_DIR=""
cleanup() {
  if [[ -n "$CLONE_DIR" ]]; then
    rm -rf "$CLONE_DIR"
  fi
}
trap cleanup EXIT

# Commits the repo's URL to the argocd files and, when badil.yaml is still the
# template's, the demo catalog, then pushes to the default branch.
fill_gitops_repo() {
  local dir url f
  CLONE_DIR="$(mktemp -d)"
  dir="${CLONE_DIR}/gitops"
  url="https://github.com/${GITOPS_REPO}.git"
  gh repo clone "$GITOPS_REPO" "$dir" -- -q
  for f in "${dir}/argocd/appproject-previews.yaml" "${dir}/argocd/applicationset-previews.yaml"; do
    sed "s|https://github.com/YOUR-ORG/YOUR-GITOPS-REPO.git|${url}|g" "$f" >"${f}.tmp"
    mv "${f}.tmp" "$f"
  done
  if grep -q "YOUR-ORG/my-service" "${dir}/badil.yaml"; then
    cat >"${dir}/badil.yaml" <<EOF
services:
  backend-1:
    repo: "https://github.com/badilhq/demo-backend-1.git"
  backend-2:
    repo: "https://github.com/badilhq/demo-backend-2.git"
  front:
    repo: "https://github.com/badilhq/demo-front.git"
  postgres:
    repo: "https://github.com/badilhq/demo-postgres.git"

preview:
  domain: ${PREVIEW_DOMAIN}
  tls: false
  expose:
    front: {}
    backend-1: {}
    backend-2: {}
EOF
  fi
  git -C "$dir" add -A
  if ! git -C "$dir" diff --cached --quiet; then
    git -C "$dir" commit -q -m "chore: configure the badil quickstart"
    # Push through gh's credential helper: a gh login alone does not set up
    # git's https credentials (gh auth setup-git does).
    git -C "$dir" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q
  fi
  rm -rf "$CLONE_DIR"
  CLONE_DIR=""
}

# Prints "<name> <sync> <health>" for the preview's Application.
preview_parent_app() {
  kubectl --context "$CTX" -n argocd get application "$PREVIEW_SLUG" \
    -o jsonpath='{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}' 2>/dev/null || true
}

# Prints "<name> <sync> <health>" for each service Application of the preview.
preview_service_apps() {
  kubectl --context "$CTX" -n argocd get applications -l "app.kubernetes.io/instance=${PREVIEW_SLUG}" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null \
    | grep -v "^${PREVIEW_SLUG} " || true
}

preview_apps() {
  preview_parent_app
  preview_service_apps
}

# True when the preview's Application and at least one service Application
# exist and every one is Synced and Healthy.
preview_apps_ready() {
  local parent services
  parent="$(preview_parent_app)"
  services="$(preview_service_apps)"
  [[ "$parent" == "${PREVIEW_SLUG} Synced Healthy" ]] || return 1
  [[ -n "$services" ]] || return 1
  ! printf '%s\n' "$services" | grep -qv ' Synced Healthy$'
}

print_inspect() {
  echo "Inspect with:" >&2
  echo "  kubectl --context ${CTX} -n argocd get applications" >&2
  echo "  kubectl --context ${CTX} -n argocd describe application ${PREVIEW_SLUG}" >&2
  echo "  kubectl --context ${CTX} get pods -A" >&2
}

# 1. Prerequisites
step "1/9 Prerequisites"
for tool in docker k3d kubectl helm gh curl openssl git; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: ${tool}"
done
docker info >/dev/null 2>&1 || die "docker is not running"
gh auth status >/dev/null 2>&1 || die "gh is not signed in (run: gh auth login)"
CLUSTER_EXISTS=0
if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  CLUSTER_EXISTS=1
else
  for port in 80 443; do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      die "port ${port} is taken"
    fi
  done
fi
step_done

# 2. Inputs
step "2/9 Inputs"
GH_USER="$(gh api user --jq .login)"
GITOPS_REPO="${BADIL_GITOPS_REPO:-${GH_USER}/badil-quickstart-gitops}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
write_state gitops-repo "$GITOPS_REPO"
echo "    gitops repo: ${GITOPS_REPO}"
gh repo view "$GITOPS_REPO" >/dev/null 2>&1 \
  || die "${GITOPS_REPO} not found: create it from badilhq/gitops-template (Use this template, Public), install the App on it, then re-run"
[[ "$(gh repo view "$GITOPS_REPO" --json visibility --jq .visibility)" == "PUBLIC" ]] \
  || die "${GITOPS_REPO} must be public: Argo CD reads it without credentials"
read_app_inputs
step_done

# 3. Gitops repo
step "3/9 Gitops repo"
appproject="$(gitops_file argocd/appproject-previews.yaml)"
applicationset="$(gitops_file argocd/applicationset-previews.yaml)"
catalog="$(gitops_file badil.yaml)"
if [[ "$appproject" == *"YOUR-ORG/YOUR-GITOPS-REPO"* || "$applicationset" == *"YOUR-ORG/YOUR-GITOPS-REPO"* \
  || "$catalog" == *"YOUR-ORG/my-service"* ]]; then
  fill_gitops_repo
  echo "    filled https://github.com/${GITOPS_REPO}"
else
  echo "    ${GITOPS_REPO} already filled"
fi
step_done

# 4. Cluster
step "4/9 Cluster"
if [[ "$CLUSTER_EXISTS" -eq 1 ]]; then
  k3d cluster start "$CLUSTER"
else
  k3d cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --servers 1 --agents 0 \
    -p "80:80@loadbalancer" -p "443:443@loadbalancer" \
    --kubeconfig-update-default --kubeconfig-switch-context=false
fi
step_done

# 5. Argo CD
step "5/9 Argo CD"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" \
  --kube-context "$CTX" -n argocd --create-namespace --wait
for file in appproject-previews.yaml applicationset-previews.yaml; do
  manifest="$(gh api "repos/${GITOPS_REPO}/contents/argocd/${file}" -H 'Accept: application/vnd.github.raw')"
  if [[ "$manifest" == *"YOUR-ORG/YOUR-GITOPS-REPO"* ]]; then
    die "argocd/${file} in ${GITOPS_REPO} still has the template placeholder; re-run up.sh to fill it"
  fi
  printf '%s\n' "$manifest" | kubectl --context "$CTX" apply -f -
done
step_done

# 6. badil
step "6/9 badil"
state_secret deploy-token
state_secret webhook-secret
kubectl --context "$CTX" create namespace badil --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -
secret_result="$(kubectl --context "$CTX" -n badil create secret generic badil \
  --from-file=github-private-key="$BADIL_PRIVATE_KEY" \
  --from-file=github-webhook-secret="${STATE_DIR}/webhook-secret" \
  --from-file=deploy-token="${STATE_DIR}/deploy-token" \
  --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -)"
echo "$secret_result"
helm upgrade --install badil oci://ghcr.io/badilhq/charts/badil \
  --version "$BADIL_CHART_VERSION" \
  --kube-context "$CTX" -n badil \
  --set-string config.githubAppId="$BADIL_APP_ID" \
  --set-string config.githubInstallationId="$BADIL_INSTALLATION_ID" \
  --set-string config.gitopsRepo="$GITOPS_REPO" \
  --set-string existingSecret=badil \
  --set ingress.enabled=true \
  --set-string ingress.className=traefik \
  --set-string ingress.host="$BADIL_HOST"
# The pod reads the Secret as env vars: restart it when a re-run changed the Secret.
if [[ "$secret_result" == *" configured"* ]]; then
  kubectl --context "$CTX" -n badil rollout restart deploy/badil
  kubectl --context "$CTX" -n badil rollout status deploy/badil --timeout="${HEALTH_WAIT_SECONDS}s"
fi
echo "    waiting for http://${BADIL_HOST}/healthz"
deadline=$((SECONDS + HEALTH_WAIT_SECONDS))
until [[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://${BADIL_HOST}/healthz" || true)" == "200" ]]; do
  if ((SECONDS >= deadline)); then
    echo "badil did not answer on http://${BADIL_HOST}/healthz within ${HEALTH_WAIT_SECONDS}s" >&2
    echo "Inspect with:" >&2
    echo "  kubectl --context ${CTX} -n badil get pods" >&2
    echo "  kubectl --context ${CTX} -n badil logs deploy/badil" >&2
    exit 1
  fi
  sleep 3
done
step_done

# 7. First deploy
step "7/9 First deploy"
pr_state="$(gh api "repos/${DEMO_REPO}/pulls/${DEMO_PR_NUMBER}" --jq .state)"
[[ "$pr_state" == "open" ]] || die "the demo pull request ${DEMO_PR_URL} is closed"
head_sha="$(gh api "repos/${DEMO_REPO}/pulls/${DEMO_PR_NUMBER}" --jq .head.sha)"
docker manifest inspect "${DEMO_IMAGE}:${head_sha}" >/dev/null 2>&1 \
  || die "the image ${DEMO_IMAGE}:${head_sha} is missing"
pr_author="$(gh api "repos/${DEMO_REPO}/pulls/${DEMO_PR_NUMBER}" --jq .user.login)"
run_url="$(gh run list -R "$DEMO_REPO" --commit "$head_sha" --limit 1 --json url --jq '.[0].url')"
[[ -n "$run_url" ]] || die "no CI run found for ${DEMO_REPO}@${head_sha}"
body="$(printf '{"service":"backend-1","head_ref":"quickstart-demo","commit_sha":"%s","pr_url":"%s","pr_number":"%s","pr_author":"%s","workflow_run_url":"%s"}' \
  "$head_sha" "$DEMO_PR_URL" "$DEMO_PR_NUMBER" "$pr_author" "$run_url")"
response_file="$(mktemp)"
status="$(curl -sS --max-time 60 -o "$response_file" -w '%{http_code}' -X POST "http://${BADIL_HOST}/v1/deploy" \
  -H @<(printf 'Authorization: Bearer %s\n' "$(cat "${STATE_DIR}/deploy-token")") \
  -H 'Content-Type: application/json' \
  --data-binary "$body")" || status="000"
response="$(cat "$response_file")"
rm -f "$response_file"
if [[ ! "$status" =~ ^2 ]]; then
  die "POST /v1/deploy answered ${status}: ${response}"
fi
slug="$(printf '%s' "$response" | sed -n 's/.*"preview_slug":"\([^"]*\)".*/\1/p')"
commit_url="$(printf '%s' "$response" | sed -n 's/.*"gitops_commit_url":"\([^"]*\)".*/\1/p')"
warnings="$(printf '%s' "$response" | sed -n 's/.*"warnings":\[\(.*\)\].*/\1/p')"
echo "    preview_slug: ${slug}"
if [[ -n "$warnings" ]]; then
  echo "    warnings: ${warnings}"
fi
kubectl --context "$CTX" -n argocd annotate applicationset preview-environments \
  argocd.argoproj.io/application-set-refresh=true --overwrite
step_done

# 8. Wait
step "8/9 Wait for the preview"
deadline=$((SECONDS + WAIT_SECONDS))
items_url="http://backend-1-${PREVIEW_SLUG}.${PREVIEW_DOMAIN}/items"
until preview_apps_ready; do
  if ((SECONDS >= deadline)); then
    echo "the preview's Argo CD Applications are not Synced and Healthy after ${WAIT_SECONDS}s:" >&2
    preview_apps >&2
    print_inspect
    exit 1
  fi
  sleep 5
done
echo "    Argo CD Applications Synced and Healthy"
until curl -s --max-time 5 "$items_url" 2>/dev/null | grep -qE '"version": *"pull request"'; do
  if ((SECONDS >= deadline)); then
    echo "${items_url} does not serve the pull request version after ${WAIT_SECONDS}s" >&2
    print_inspect
    exit 1
  fi
  sleep 3
done
echo "    ${items_url} serves the pull request version"
step_done

# 9. Print
echo
echo "==> 9/9 Your preview is up"
echo "    front:     http://front-${PREVIEW_SLUG}.${PREVIEW_DOMAIN}"
echo "    backend-1: ${items_url} (pull request #${DEMO_PR_NUMBER})"
echo "    backend-2: http://backend-2-${PREVIEW_SLUG}.${PREVIEW_DOMAIN}"
echo "    gitops commit: ${commit_url}"
echo
echo "    Argo CD UI: kubectl --context ${CTX} -n argocd port-forward svc/argocd-server 8080:443"
echo "      then open https://localhost:8080 as admin, with the password from:"
echo "      kubectl --context ${CTX} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
echo "    Total: ${SECONDS}s"
