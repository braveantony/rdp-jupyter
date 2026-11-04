# rdp-jupyter

Use Windows Remote Desktop to connect to your Kubernetes cluster and you get a full-screen JupyterLab Desktop (Jupyter's official desktop app). Notebook kernels run in a Pod inside the cluster, so you reach in-cluster databases, object storage and other services directly by `<service>.<namespace>` — your data never has to leave the cluster.

Several people can use it at once, and each account gets its own desktop. The default limit is 3 desktops at a time, and you can change it.

## Overview

- After you log in, JupyterLab Desktop fills the screen. Open a notebook and write Python right away; pandas and matplotlib are preinstalled and the kernel runs inside the Pod.
- Use `<service>.<namespace>` (for example `postgres.default`) in a notebook to reach in-cluster PostgreSQL, MinIO and other services. See [data-access.md](docs/data-access.md) (Traditional Chinese) for how and which packages to add.
- Only one NodePort (a fixed port Kubernetes opens on every node; here 30391) is exposed; no HTTP, Ingress or TLS.
- The Remote Desktop client built into Windows is enough. You don't need to install Jupyter or Python on your own computer.
- Several different accounts can be logged in at the same time, each with its own desktop, and they cannot see each other's home directories or notebooks in this Pod. Logging in with the *same* account from a second machine reattaches to its existing desktop and drops the first connection (see [Reconnecting](#4-reconnecting-after-a-disconnect)); it does not open a second desktop.
- The UI is Traditional Chinese by default and switches to English with `JUPYTER_LOCALE`.
- To keep your notebooks and self-installed packages, use stateful mode: `/home` lives on a PVC (persistent storage requested from the cluster), so your work survives when the Pod is recreated.

**A good fit for**: small teams (3–5 concurrent users), lab or teaching clusters, environments that must not expose a web service, and setups already running rdp-firefox or rdp-vscode.

**Not a fit for**: many users, strong isolation or per-user resource quotas, or a GPU per user. For those, use JupyterHub + KubeSpawner (one Pod per user, with fuller resource and isolation guarantees). See the [architecture doc](docs/architecture.md) (Traditional Chinese) for the full trade-off.

## Architecture

For details, see [docs/architecture.md](docs/architecture.md) (Traditional Chinese).

## Prerequisites

### Kubernetes cluster

- kubectl, curl, bash (and git to install with Kustomize). kubectl already includes Kustomize, a tool for assembling YAML manifests; `kubectl apply -k` uses it
- A kubeconfig (usually `~/.kube/config`) with enough permission for `install.sh`: create and update Namespaces, Deployments, Services and Secrets (Kubernetes objects that hold passwords and other sensitive data; plus PVCs for stateful mode), read Deployments and Services, list Nodes, and list and delete old `rdp-jupyter-users-*` Secrets in namespace `rdp-jupyter`
- Nodes that can pull from `ghcr.io` (the image is about 1.1 GB unpacked)
- Resources: the Pod requests 1 CPU / 2 GiB and is limited to 4 CPU / 8 GiB (sized for 3 concurrent users). **All desktops live in this one Pod and share that limit**; see the [security warning](#security-warning)
- NodePort `30391` free, and clients able to reach TCP 30391 on the nodes (open it in the firewall if needed)

### Remote Desktop client

- **Windows**: the built-in Remote Desktop Connection (`mstsc`)
- **macOS**: Windows App from the Mac App Store; set Credentials to **Ask when required** when adding the PC so the xrdp login screen shows (not tested)

## Quick start

On a machine with kubectl, curl and bash that can reach the cluster:

```bash
curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-jupyter/main/install.sh | bash
```

The script deploys to namespace `rdp-jupyter` and prints the address of every node. Connect Remote Desktop to `<node IP>:30391` and log in as `bigred` / `bigred`.

This quick install has one account and keeps no notebooks or packages. Several accounts, your own passwords or a persistent home (all three need the Kustomize deployment), single-host podman when there is no Kubernetes, LAN access when the nodes sit on an internal network, and uninstalling are all in the [install guide](docs/install.md) (Traditional Chinese).

## How to use

### 1. Log in

Press `Win+R`, type `mstsc` and connect to the address above. Accept the certificate warning. Each Pod generates its own certificate at startup, so the warning appears again after the Pod is recreated. On the xrdp login screen, keep Session set to `Xorg`, enter the account and password, and press OK.

### 2. Open a notebook

JupyterLab Desktop opens full screen. From the Launcher, click **Python 3 (ipykernel)** under "Notebook" to open a new notebook and start writing Python. pandas and matplotlib are preinstalled, so `import pandas as pd` just works.

![Full-screen JupyterLab Desktop](docs/images/01-jupyterlab-desktop.png)

The file browser on the left shows your home directory in the Pod (`/home/<account>`), where notebooks are saved by default. In stateless mode this is wiped when the Pod is recreated; use stateful mode to keep it (see the [install guide](docs/install.md), Traditional Chinese).

### 3. Reach in-cluster services

The kernel runs in the Pod, so a notebook can reach in-cluster services directly by `<service>.<namespace>`. For example, query a PostgreSQL in namespace `default` with pandas (this example first needs `sqlalchemy` and `psycopg2-binary`, and you must replace the connection details with real values; see the [data access guide](docs/data-access.md) (Traditional Chinese) for how to install and where to keep the password):

```python
import pandas as pd
from sqlalchemy import create_engine

engine = create_engine("postgresql+psycopg2://user:pass@postgres.default:5432/mydb")
df = pd.read_sql("SELECT * FROM sales LIMIT 100", engine)
df.head()
```

Reading and writing MinIO/S3, bringing notebooks in with Git, and which packages each example needs are in the [data access guide](docs/data-access.md) (Traditional Chinese).

> This desktop **cannot exchange files with your own computer** (both Remote Desktop drive redirection and clipboard file transfer are disabled, in and out; see the [data access guide](docs/data-access.md) for why). Data moves in and out through cluster services or Git. The text clipboard is unaffected, so you can still copy and paste text such as code.

### 4. Reconnecting after a disconnect

You **reattach to the same desktop after a disconnect** (as long as that desktop has not timed out and the Pod has not been recreated): if the network drops or you close the Remote Desktop window by accident, log in again with the same account and you are back on the original desktop, with running kernels and results intact. A disconnected desktop is kept for 8 hours by default (`DISCONNECTED_TIMEOUT`) before it is cleaned up; once the Pod is recreated, all desktops are gone and a login starts a fresh one.

The trade-off is that one account cannot have two desktops at once: while the desktop still exists, a second login reattaches to it and ends the first connection.

To end a desktop on purpose, close the JupyterLab Desktop window (the close button at the top right) and you are logged out.

The [user guide](docs/user-guide.md) (Traditional Chinese) has the full instructions and troubleshooting.

## Image

The image is `ghcr.io/braveantony/rdp-jupyter:0.1`, about 1.1 GB unpacked, with JupyterLab Desktop 4.6.3-1, a Python 3.13 venv (jupyterlab 4.6.3, ipykernel, pandas, matplotlib, the Traditional Chinese language pack and jupyter-resource-usage), and the Noto CJK and DejaVu fonts. See [build-image.md](docs/build-image.md) (Traditional Chinese) to build from source and upgrade.

## Documentation (Traditional Chinese)

- [install.md](docs/install.md): installation (quick install, Kustomize with several accounts and a persistent home, single-host podman, LAN access, uninstall)
- [architecture.md](docs/architecture.md): how it works (connection flow, what each process in the Pod does, security boundary and threat model)
- [user-guide.md](docs/user-guide.md): user guide (logging in, opening notebooks, installing packages, reconnecting, concurrent use, troubleshooting)
- [data-access.md](docs/data-access.md): data access (PostgreSQL, MinIO/S3 and Git examples, and why you cannot drag files from your own machine)
- [build-image.md](docs/build-image.md): build guide (build the image from source, test it, and upgrade JupyterLab Desktop)
- [design/](docs/design/README.md): design decisions, threat model, acceptance criteria and risks

## Environment variables

First clone this repo as described in the [install guide](docs/install.md#kustomize多個帳號與保留-home), edit `env` in `manifests/base/deployment.yaml`, and run `kubectl apply -k manifests/stateless` (or `manifests/stateful`, whichever you use) again. An invalid value falls back to the default and the Pod log shows a warning.

| Variable | Default | Meaning |
|---|---|---|
| `USERS_FILE` | `/etc/rdp-jupyter/users` | Account file, one `user:password` per line; on Kubernetes it is always mounted from Secret `rdp-jupyter-users-*` |
| `RDP_USER` | `bigred` | Login account when there is no account file (UID 1000); on Kubernetes the file always exists, so it is not used |
| `RDP_PASSWORD` | — | Its password, required in that case; not used on Kubernetes |
| `MAX_SESSIONS` | `3` | Maximum concurrent desktops, all accounts together, disconnected ones included (note 1) |
| `DISCONNECTED_TIMEOUT` | `28800` | How long a disconnected desktop is kept (8 hours by default) before cleanup, which discards its kernels and unsaved content. Minimum 60 seconds (note 2) |
| `KERNEL_MEMORY_LIMIT` | `2Gi` | Per-kernel memory hard limit (`RLIMIT_DATA`); accepts `Mi` and `Gi`, minimum `1Gi` (note 3) |
| `KERNEL_THREADS` | `2` | Per-kernel numeric-compute thread count (BLAS/OpenMP, the libraries numpy and pandas use under the hood), so one kernel does not take every CPU |
| `KERNEL_CULL_IDLE_TIMEOUT` | `3600` | Seconds before an idle kernel is culled to free memory; `0` disables culling, and a busy kernel is never culled |
| `JUPYTER_LOCALE` | `zh-tw` | UI language: `zh-tw` or `en` (only the default; a language a user picks in the menu wins) |
| `PIP_INDEX_URL` | (pip default) | pip index URL used by the postStart extra-package install; point it at an internal mirror if needed |
| `INSTALL_TIMEOUT` | `900` | Time limit in seconds for the postStart extra-package install (note 4) |

- **Note 1 (`MAX_SESSIONS`)**: a disconnected desktop that has not been cleaned up still holds a slot until `DISCONNECTED_TIMEOUT` expires.
- **Note 2 (`DISCONNECTED_TIMEOUT`)**: xorgxrdp does the cleanup and treats any value from 1 to 59 as 60, so a smaller value is raised to 60 with a warning in the log; `0` or a non-numeric value is rejected and falls back to the default `28800`.
- **Note 3 (`KERNEL_MEMORY_LIMIT`)**: the limit is applied per process; an oversized allocation usually raises `MemoryError` in that cell and the kernel keeps going, but this is not guaranteed in every case, so save often. A value below `1Gi` is raised to `1Gi` (OpenBLAS and friends fail to load under a smaller cap) with a warning.
- **Note 4 (`INSTALL_TIMEOUT`)**: the container is not Ready until the install finishes, so connections over the normal Service path wait until the Pod is Ready; on timeout the install is abandoned and a notice pops up on the desktop, but it does not fail Pod startup.

Extra packages — whether admin-provided through a `requirements.txt` ConfigMap or installed by a user with `%pip install --user` — are covered in the [user guide](docs/user-guide.md) (Traditional Chinese) and `manifests/example/requirements`.

## Security warning

**The default account `bigred` / `bigred` is for isolated lab clusters only.** Anyone who can reach NodePort 30391 can use it to get into the cluster network and, from a notebook, reach any in-cluster service as this account. Before you deploy anywhere else, switch to [several accounts](docs/install.md#kustomize多個帳號與保留-home) (Traditional Chinese) with your own passwords.

**All desktops share one Pod's memory.** Each kernel has its own hard memory limit (`KERNEL_MEMORY_LIMIT`), but the Pod's `limits.memory` is shared by every desktop and every kernel. When one person opens many kernels, or many people run large jobs at once, and the total exceeds the Pod limit, **the whole Pod is OOM-killed and restarted, and everyone's desktops and unsaved content are lost**. Size `MAX_SESSIONS` and the Pod's `limits.memory` together; a rule of thumb is `limits.memory ≈ MAX_SESSIONS × (0.5Gi + KERNEL_MEMORY_LIMIT)`. Idle culling (`KERNEL_CULL_IDLE_TIMEOUT`) lowers the risk. For strong isolation or per-user quotas, use JupyterHub.

## License

[Apache-2.0](LICENSE)
