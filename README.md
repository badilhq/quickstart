# badil quickstart

This guide runs badil and Argo CD on a local k3d cluster, and badil deploys a preview of the pull request [`badilhq/demo-backend-1#53`](https://github.com/badilhq/demo-backend-1/pull/53). Run the steps by hand, or with `./up.sh`:

- **By hand:** follow the [walkthrough](#walkthrough). Each step explains what it changes, then gives the commands to copy.
- **With `./up.sh`:** it runs the same steps with checks, and is safe to re-run. See [Shortcut: `up.sh`](#shortcut-upsh).

## Prerequisites

- `docker` (running), `k3d`, `kubectl`, `helm`, `gh` (signed in: `gh auth status`), `curl`, `openssl` and `git`.
- Host ports 80 and 443 free. Only one such cluster (for example `badil-quickstart` or `badil-testbed`) runs at a time, because each takes ports 80 and 443.
- macOS (Docker Desktop) or Linux.

## Before you start

### Create the gitops repo

badil commits previews to a gitops repo, and Argo CD deploys what it finds there.

1. Open https://github.com/badilhq/gitops-template and click **Use this template**, then **Create a new repository**.
2. **Owner:** your account. **Repository name:** `badil-quickstart-gitops`, or any name.
3. Choose **Public**: Argo CD reads the repo without credentials.

### Create the GitHub App

badil acts on GitHub through a GitHub App that you own.

1. Open https://github.com/settings/apps/new.
2. **GitHub App name:** any unique name, for example `badil-quickstart-<your-login>`. **Homepage URL:** any URL, for example `https://badil.dev`.
3. **Webhook:** untick **Active**. No webhook URL is needed.
4. **Repository permissions:**
   - Contents: Read and write
   - Pull requests: Read and write
   - Metadata: Read-only

   No events.
5. **Where can this GitHub App be installed?** Only on this account.
6. Click **Create GitHub App** and note the **App ID**.
7. Under **Private keys**, click **Generate a private key** and save the `.pem` file outside this repository.

### Install the App on the gitops repo

1. On the App's settings page, click **Install App**, then **Install** next to your account.
2. Choose **Only select repositories** and select the gitops repo only.
3. After the install, the browser URL ends with `/settings/installations/<ID>`. Note that number: it is the installation ID.

## Walkthrough

Run every block in the same shell, from a clone of this repo: later blocks use the variables the first one sets. Each block runs the commands `up.sh` runs, with the same flags and versions, and writes the same files under `.quickstart/`, so you can stop at any step and finish with `./up.sh`.

Clone this repo, then set your values in place of the `<...>` placeholders. `BADIL_GITOPS_REPO` repeats the repo name for `up.sh`, which reads that variable. `BADIL_PRIVATE_KEY` is the full path to the `.pem` file. `CTX` is the cluster's kubectl context: every command passes it, so your current context never changes.

```bash
git clone https://github.com/badilhq/quickstart.git
cd quickstart

export GITOPS_REPO="<your-login>/badil-quickstart-gitops"
export BADIL_GITOPS_REPO="$GITOPS_REPO"
export BADIL_APP_ID="<app-id>"
export BADIL_INSTALLATION_ID="<installation-id>"
export BADIL_PRIVATE_KEY="<full-path-to-the-app-key.pem>"
export CTX=k3d-badil-quickstart
```

### 1. Fill the gitops repo

badil reads its service catalog, `badil.yaml`, from the gitops repo, and Argo CD reads the manifests in `argocd/` from it. The template has a placeholder URL in `argocd/` and an example catalog: this step commits your repo's own URL and the demo catalog to its default branch.

Clone the repo into a temporary folder and put its URL in both `argocd/` files:

```bash
GITOPS_DIR="$(mktemp -d)/gitops"
gh repo clone "$GITOPS_REPO" "$GITOPS_DIR" -- -q
for f in "$GITOPS_DIR/argocd/appproject-previews.yaml" "$GITOPS_DIR/argocd/applicationset-previews.yaml"; do
  sed "s|https://github.com/YOUR-ORG/YOUR-GITOPS-REPO.git|https://github.com/${GITOPS_REPO}.git|g" "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
done
```

Write the demo catalog in place of the template's example. It lists four services, each from its own repo:

- `backend-1` and `backend-2`: demo Go services. Each reads the Secret `postgres` that the `postgres` service creates.
- `front`: a demo Next.js front end.
- `postgres`: a demo Postgres chart.

`preview` gives each service under `expose` its own host, `<service>-<preview>.127.0.0.1.nip.io`, over plain http (`tls: false`). `postgres` is not exposed.

```bash
cat >"$GITOPS_DIR/badil.yaml" <<'EOF'
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
  domain: 127.0.0.1.nip.io
  tls: false
  expose:
    front: {}
    backend-1: {}
    backend-2: {}
EOF
```

Commit and push. The push goes through `gh`'s login, so git needs no other credentials:

```bash
git -C "$GITOPS_DIR" add -A
git -C "$GITOPS_DIR" commit -q -m "chore: configure the badil quickstart"
git -C "$GITOPS_DIR" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q
```

### 2. Create the cluster

This creates the k3d cluster `badil-quickstart`: one k3s node, with host ports 80 and 443 on its load balancer, where k3s's Traefik ingress answers. It adds the context `k3d-badil-quickstart` to your kubeconfig without switching to it. Previews answer on `*.127.0.0.1.nip.io`, a public DNS name that resolves to 127.0.0.1, so they need no `/etc/hosts` entry.

```bash
k3d cluster create badil-quickstart \
  --image rancher/k3s:v1.37.1-k3s1 \
  --servers 1 --agents 0 \
  -p "80:80@loadbalancer" -p "443:443@loadbalancer" \
  --kubeconfig-update-default --kubeconfig-switch-context=false
```

### 3. Install Argo CD and the preview wiring

This installs Argo CD in the namespace `argocd`. `--repo` points Helm at the chart's repository directly, so your Helm repo list stays as it is.

Then it applies the two manifests of your gitops repo, read through the GitHub API, which serves the latest commit:

- The AppProject `previews` lets the preview Applications use your gitops repo and badil's charts.
- The ApplicationSet `preview-environments` creates one Argo CD Application per folder that badil writes under `previews/`.

```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 10.11.6 \
  --kube-context "$CTX" -n argocd --create-namespace --wait
gh api "repos/${GITOPS_REPO}/contents/argocd/appproject-previews.yaml" -H 'Accept: application/vnd.github.raw' \
  | kubectl --context "$CTX" apply -f -
gh api "repos/${GITOPS_REPO}/contents/argocd/applicationset-previews.yaml" -H 'Accept: application/vnd.github.raw' \
  | kubectl --context "$CTX" apply -f -
```

### 4. Install badil

badil reads three keys from the Secret `badil`:

- `github-private-key`: the App's key, to act on GitHub as the App.
- `github-webhook-secret`: the chart requires it. The webhook is off in this quickstart, so a random value is enough.
- `deploy-token`: the bearer token that protects badil's `POST /v1/deploy`, which step 6 calls.

The first lines write the gitops repo's name and two random values (`openssl rand -hex 32`) to `.quickstart/`, a folder only you can read and that git ignores, without a trailing newline. Values already there are kept, so `up.sh` and these blocks share them. The Secret is created from the files, so no secret value appears on a command line.

Then Helm installs badil's chart in the namespace `badil`, with the App's IDs, the gitops repo and an ingress on `badil.127.0.0.1.nip.io`. The ingress routes badil's `/webhooks/github`, which step 5 uses to check that badil answers, and, with `ingress.api=true`, its `/v1` API, which step 6 calls.

```bash
mkdir -p .quickstart && chmod 700 .quickstart
(umask 077 && printf '%s' "$GITOPS_REPO" >.quickstart/gitops-repo)
[ -s .quickstart/deploy-token ] || (umask 077 && printf '%s' "$(openssl rand -hex 32)" >.quickstart/deploy-token)
[ -s .quickstart/webhook-secret ] || (umask 077 && printf '%s' "$(openssl rand -hex 32)" >.quickstart/webhook-secret)

kubectl --context "$CTX" create namespace badil --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -
kubectl --context "$CTX" -n badil create secret generic badil \
  --from-file=github-private-key="$BADIL_PRIVATE_KEY" \
  --from-file=github-webhook-secret=.quickstart/webhook-secret \
  --from-file=deploy-token=.quickstart/deploy-token \
  --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

helm upgrade --install badil oci://ghcr.io/badilhq/charts/badil \
  --version 0.30.0 \
  --kube-context "$CTX" -n badil \
  --set-string config.githubAppId="$BADIL_APP_ID" \
  --set-string config.githubInstallationId="$BADIL_INSTALLATION_ID" \
  --set-string config.gitopsRepoURL="https://github.com/${GITOPS_REPO}.git" \
  --set-string existingSecret=badil \
  --set ingress.enabled=true \
  --set ingress.api=true \
  --set-string ingress.className=traefik \
  --set-string ingress.host=badil.127.0.0.1.nip.io
```

badil reads the Secret when its pod starts. If the Secret changes later (a new key, for example), restart the pod with `kubectl --context "$CTX" -n badil rollout restart deploy/badil`.

### 5. Check badil answers

This prints `401` once badil answers through the ingress: badil refuses an unsigned webhook, which shows that the route and badil are up. On the first run the pod waits for its image to download: repeat the command until it prints `401`.

```bash
curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' -X POST http://badil.127.0.0.1.nip.io/webhooks/github
```

### 6. Deploy the first preview

[`badilhq/demo-backend-1#53`](https://github.com/badilhq/demo-backend-1/pull/53) is a pull request kept open for this demo: it adds `"version": "pull request"` to backend-1's `/items`. The demo depends on it staying open: if it is closed, `up.sh` stops and says so. Read its head commit, its author and the CI run that built its image:

```bash
HEAD_SHA="$(gh api repos/badilhq/demo-backend-1/pulls/53 --jq .head.sha)"
PR_AUTHOR="$(gh api repos/badilhq/demo-backend-1/pulls/53 --jq .user.login)"
RUN_URL="$(gh run list -R badilhq/demo-backend-1 --commit "$HEAD_SHA" --limit 1 --json url --jq '.[0].url')"
```

Ask badil to preview backend-1 at that commit. badil reads `badil.yaml` from your gitops repo and commits the preview's file, `previews/quickstart-demo/values.yaml`, to it: one commit. The other services run their `main` branch.

The response holds the preview's name (`preview_slug`) and the gitops commit's URL. It also holds a warning about the pull request comment, which is expected: the App is not installed on `badilhq/demo-backend-1`, so badil cannot comment there.

```bash
BODY="$(cat <<EOF
{
  "service": "backend-1",
  "head_ref": "quickstart-demo",
  "commit_sha": "${HEAD_SHA}",
  "pr_url": "https://github.com/badilhq/demo-backend-1/pull/53",
  "pr_number": "53",
  "pr_author": "${PR_AUTHOR}",
  "workflow_run_url": "${RUN_URL}"
}
EOF
)"
curl -sS --max-time 60 -X POST http://badil.127.0.0.1.nip.io/v1/deploy \
  -H @<(printf 'Authorization: Bearer %s\n' "$(cat .quickstart/deploy-token)") \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY"
echo
```

Argo CD polls Git every 3 minutes. This annotation makes the ApplicationSet read the gitops repo now, so the preview starts at once:

```bash
kubectl --context "$CTX" -n argocd annotate applicationset preview-environments \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```

### 7. Watch it deploy

The ApplicationSet creates the Application `quickstart-demo`, which creates one Application per service. Repeat this until each one shows `Synced` and `Healthy`:

```bash
kubectl --context "$CTX" -n argocd get applications
```

Then backend-1 answers with the pull request's version, `"version": "pull request"`:

```bash
curl -s --max-time 5 http://backend-1-quickstart-demo.127.0.0.1.nip.io/items
```

### 8. Preview URLs and the Argo CD UI

The preview's services:

- front: http://front-quickstart-demo.127.0.0.1.nip.io, at `main`
- backend-1: http://backend-1-quickstart-demo.127.0.0.1.nip.io/items, at pull request #53
- backend-2: http://backend-2-quickstart-demo.127.0.0.1.nip.io, at `main`

The first command prints the URL of the commit badil wrote to your gitops repo. The next two open the Argo CD UI: print the `admin` password, then forward the UI to https://localhost:8080 (stop it with Ctrl-C).

```bash
gh api "repos/${GITOPS_REPO}/commits?path=previews/quickstart-demo&per_page=1" --jq '.[0].html_url'
kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl --context "$CTX" -n argocd port-forward svc/argocd-server 8080:443
```

## Shortcut: `up.sh`

`up.sh` runs steps 1 to 8 above, plus checks: the tools are installed, ports 80 and 443 are free, the gitops repo exists and is public, pull request #53 is open and its image is published. It asks for the App ID, the installation ID and the path to the `.pem` file, or reads them from `BADIL_APP_ID`, `BADIL_INSTALLATION_ID` and `BADIL_PRIVATE_KEY`. The gitops repo defaults to `<your-login>/badil-quickstart-gitops`; pass another as `BADIL_GITOPS_REPO=owner/name`. It keeps its secrets in `.quickstart/` and is safe to re-run: it reuses the cluster, the filled gitops repo and the secrets, and never overwrites a `badil.yaml` you wrote. Run it from a clone of this repo:

```bash
./up.sh
```

## Teardown

By hand, delete the cluster, then, if you no longer need them, the gitops repo and the App. No script deletes the repo or the App. Run the commands from the clone of this repo: the repo name comes from `GITOPS_REPO`, else from `.quickstart/gitops-repo`, and the command stops when neither is set. `gh repo delete` needs the `delete_repo` scope: run `gh auth refresh -s delete_repo` first if `gh` asks for it.

```bash
k3d cluster delete badil-quickstart
repo="${GITOPS_REPO:-$(cat .quickstart/gitops-repo)}"
gh repo delete "${repo:?no gitops repo: set GITOPS_REPO=owner/name}"
```

To delete the App, open https://github.com/settings/apps, select it, click **Advanced**, then **Delete GitHub App**.

Shortcut: `down.sh` deletes the cluster, then prints the command and the link to delete the gitops repo and the App.

```bash
./down.sh
```

## Next: label-triggered previews

In a real setup, badil previews a pull request when you label it, through the App's webhook. Follow the install guide: https://badil.dev/docs/install.

## License

Apache-2.0, see [LICENSE](LICENSE).
