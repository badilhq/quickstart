# badil quickstart

Try badil on your machine in about 5 minutes, once the images are downloaded: one script starts a local k3d cluster, installs Argo CD and badil, and deploys a preview of a real pull request.

## Prerequisites

- `docker` (running), `k3d`, `kubectl`, `helm`, `gh` (signed in: `gh auth status`), `curl`, `openssl` and `git`.
- Host ports 80 and 443 free. Only one such cluster (for example `badil-quickstart` or `badil-testbed`) runs at a time, because each takes ports 80 and 443.
- macOS (Docker Desktop) or Linux.

## Before you run

### 1. Create the gitops repo

badil commits previews to a gitops repo that Argo CD reads.

1. Open https://github.com/badilhq/gitops-template and click **Use this template**, then **Create a new repository**.
2. **Owner:** your account. **Repository name:** `badil-quickstart-gitops`, or any name you then pass as `BADIL_GITOPS_REPO=owner/name`.
3. Choose **Public**: Argo CD reads the repo without credentials.

### 2. Create the GitHub App

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

### 3. Install the App on the gitops repo

1. On the App's settings page, click **Install App**, then **Install** next to your account.
2. Choose **Only select repositories** and select the gitops repo only.
3. After the install, the browser URL ends with `/settings/installations/<ID>`. Note that number: it is the installation ID.

## Run

```bash
git clone https://github.com/badilhq/quickstart.git
cd quickstart
./up.sh
```

`up.sh` asks for the App ID, the installation ID and the path to the `.pem` file, or reads them from `BADIL_APP_ID`, `BADIL_INSTALLATION_ID` and `BADIL_PRIVATE_KEY`.

On its first run, `up.sh` commits the demo service catalog (`badil.yaml`) and the repo's own URL (in `argocd/`) to your gitops repo's default branch. A `badil.yaml` you already wrote is kept.

`up.sh` is safe to re-run: it reuses the cluster, the filled gitops repo and the tokens in `.quickstart/`.

## What you see

At the end, `up.sh` prints three preview URLs:

- `http://backend-1-quickstart-demo.127.0.0.1.nip.io/items` serves backend-1 at the pull request's version: the JSON has `"version": "pull request"`.
- `front` and `backend-2` run at `main`.

It also prints the gitops commit badil made, and how to open the Argo CD UI.

The demo depends on [`badilhq/demo-backend-1#53`](https://github.com/badilhq/demo-backend-1/pull/53) staying open. If it is closed, `up.sh` stops and says so.

## How it works

1. `up.sh` asks badil, through its `POST /v1/deploy` API, to preview backend-1 at the head of pull request #53.
2. badil reads the service catalog (`badil.yaml`) in your gitops repo and commits the preview's file under `previews/quickstart-demo/`.
3. Argo CD's ApplicationSet sees the new directory and creates the preview's Applications, one per service.
4. Argo CD deploys backend-1 at the pull request's commit and the other services at `main`, each on its own `*.127.0.0.1.nip.io` host.

## Teardown

```bash
./down.sh
```

It deletes the k3d cluster. It keeps your gitops repo and the GitHub App, and prints the command and the link to delete them.

## Next: the label-a-pull-request loop

In a real setup, badil previews a pull request when you label it, through the App's webhook. Follow the install guide: https://badil.dev/docs/install.

## License

Apache-2.0, see [LICENSE](LICENSE).
