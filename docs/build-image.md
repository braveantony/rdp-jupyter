# rdp-jupyter 映像檔建置手冊

本文件從原始碼做出 `ghcr.io/braveantony/rdp-jupyter:0.1`，跑過測試，載入 tk8s 的節點並部署，最後推到 ghcr.io。**由上到下依序複製每個指令區塊貼到終端機執行。** 需要在 repo 目錄執行的區塊，開頭都會 `cd ~/rdp-jupyter`，中途換終端機也能接著貼。

## 這個映像檔做什麼

| 功能 | 做法 |
|---|---|
| RDP 伺服器 | xrdp 0.10.1 + xorgxrdp：sesman 替每個新桌面啟動一個獨立的 Xorg（斷線後重新連線是接回原桌面，不會再啟動），解析度跟著用戶端視窗；`Policy=Default`，斷線後接回原本的桌面 |
| 應用程式 | JupyterLab Desktop 4.6.3-1（固定版本）的 Electron 應用程式，由 openbox 撐滿整個畫面、沒有邊框；關掉就登出 |
| Python 環境 | Debian python3（3.13）建的 venv，預裝 jupyterlab、ipykernel、pandas、matplotlib、繁中語言包、jupyter-resource-usage |
| 中文介面 | 預裝繁體中文語言包，`JUPYTER_LOCALE` 切換 `zh-tw` 或 `en` |
| 連叢集服務 | kernel 在 Pod 裡，用 `<service>.<namespace>` 直接連；額外套件由管理者的 `requirements.txt`（postStart 安裝）或使用者 `%pip install --user` 提供 |
| token 防護 | 建置時修改 `app.asar`，server token 改用 `JUPYTER_TOKEN` 環境變數傳，不放在命令列（見[token patch](#token-patchd5)） |
| 安全 | 帳密在啟動時由 Secret 設定，不寫進映像檔；每個 Pod 自己產生 TLS 憑證和 RSA 金鑰 |

## 前置需求

| 項目 | 需求 |
|---|---|
| 建置工具 | podman |
| 網路 | 建置時要能連到 `docker.io`（Debian 基底映像檔）、`deb.debian.org`（系統套件）、`github.com`（JupyterLab Desktop 的 `.deb`）、`ghcr.io`（uv 映像檔）、PyPI（venv 的套件） |
| 磁碟 | 至少 5 GB 可用空間供建置（映像檔解壓縮後約 1.1 GB，建置過程還需要暫存空間） |
| CPU 架構 | x86_64 |
| 測試 | `bash`、`podman`、`python3`（含 PyYAML）、`kubectl`；供應鏈與 lint 測試會自己拉固定版本的工具映像檔；載入 tk8s 節點需要 `sudo` 和 `skopeo` |

```bash
podman --version
skopeo --version
df -h ~
```

> **注意**：如果建置的這台主機同時跑著 K8s 節點（例如 tk8s 的節點 container 共用主機磁碟），磁碟使用率超過 85% 時，kubelet 會開始刪除節點上沒在用的映像檔。建置前請確認建置後仍低於 85%。

## Step 1：取得原始碼

```bash
git clone https://github.com/braveantony/rdp-jupyter.git ~/rdp-jupyter
cd ~/rdp-jupyter
ls
```

主要檔案：

```text
rdp-jupyter/
├── VERSION                          # 目前版本（0.1）；test/build.sh 會把它當 build arg 傳進去
├── install.sh                       # 快速開始的 curl | bash 安裝腳本
├── images/rdp-jupyter/
│   ├── Dockerfile                   # 版本號在開頭的 ARG
│   ├── requirements.in / .lock      # venv 的套件（.lock 含 hash）
│   ├── patches/token-env.sh         # token patch（見下文）
│   └── rootfs/                      # 整個目錄 COPY 到映像檔的 /
│       ├── etc/xrdp/startwm.sh      # 每個桌面的啟動和清理
│       ├── etc/rdp-jupyter/openbox-rc.xml  # kiosk 視窗規則
│       └── opt/rdp-jupyter/         # entrypoint、帳號、session/server 環境、額外套件安裝
├── manifests/                       # Kustomize：base、stateless、stateful、example
├── docs/                            # 本文件、架構、使用手冊、資料存取、設計文件
└── test/                            # unit、image、deploy、e2e 測試
```

## Step 2：建置

```bash
cd ~/rdp-jupyter
bash test/build.sh ghcr.io/braveantony/rdp-jupyter:0.1
podman image ls ghcr.io/braveantony/rdp-jupyter
```

`test/build.sh` 會把 repo 的 `VERSION` 內容當成 `RDP_JUPYTER_VERSION` build arg 傳進去（這個檔案在建置 context 之外，Dockerfile 會把它寫進 `/opt/rdp-jupyter/VERSION`；沒有這個 arg 建置會失敗）。不指定 tag 時預設建成 `localhost/rdp-jupyter:dev`，測試也用這個預設。

建置分成 builder 和 final 兩階段：builder 下載 JupyterLab Desktop 的 `.deb` 並驗證 SHA-256、解開、套用 token patch，再用 `uv` 依 `requirements.lock`（含 hash）建 venv；final 從 `debian:trixie-slim` 裝 xrdp 等系統套件，再把 builder 的成果複製過來。

> **重要：映像檔的 apt 依賴是刻意弄壞的，不要在它上面 `apt-get install`。**
>
> 為了壓到 1.2 GB 的大小上限，final 階段用 `--force-depends` 移除了 Mesa／LLVM 相關套件（`mesa-libgallium`、`libllvm19`、`libz3-4`、`libegl-mesa0`、`libglx-mesa0` 等，約 196 MB）。這個 Pod 沒有 GPU（`/dev/dri` 不存在），xorgxrdp 用軟體繪圖，Electron 以 `--disable-gpu` 執行，所以這些套件用不到；還引用它們的模組（libgbm 的 dri 後端、Xorg 的 glamor 和 glx）只是 dlopen 它們、找不到就退回軟體。代價是 **apt 會看到壞掉的依賴**。要改動作業系統層的套件，請**改 Dockerfile 重新建置整個映像檔**，絕對不要在跑起來的container裡 `apt-get install`——那會因為壞掉的依賴失敗，或把映像檔弄到無法重現的狀態。Python 套件不受影響，照常用 `requirements.txt`（管理者）或 `%pip install --user`（使用者）。

## Step 3：測試

不需要叢集的測試：

```bash
cd ~/rdp-jupyter
IMG=ghcr.io/braveantony/rdp-jupyter:0.1
bash test/unit/accounts.test.sh
bash test/unit/session-env.test.sh
bash test/unit/server-env.test.sh
bash test/unit/sesman-config.test.sh
bash test/unit/desktop-settings.test.sh
bash test/unit/lab-overrides.test.sh
bash test/unit/install-extra.test.sh
bash test/unit/notify-extra.test.sh
bash test/unit/startwm.test.sh
bash test/unit/install.test.sh
bash test/unit/token-env.test.sh
bash test/image/smoke.test.sh "$IMG"
bash test/image/notebook.test.sh "$IMG"
bash test/image/isolation.test.sh "$IMG"
bash test/image/session.test.sh "$IMG"
```

每個測試最後一行都應該是 `N passed, 0 failed`。重點項目：

- `smoke.test.sh`：映像檔解壓縮後 ≤ 1.2 GB、venv 能 import jupyterlab、pandas、matplotlib。
- `notebook.test.sh`：不開畫面用 nbclient 跑 `smoke.ipynb`，確認 pandas／matplotlib 正常，而且超過記憶體上限只會跳 `MemoryError`、kernel 還活著。
- `isolation.test.sh`：以 alice 的身分驗證[威脅模型](architecture.md#威脅模型)每一項（讀不到 bob 的 token、environ、檔案、kernel，也 ptrace 不了 bob 的 process）。
- `session.test.sh`：用 FreeRDP 實際登入，檢查 kiosk、token 不在命令列、記憶體上限、斷線後接回同一個桌面、額外套件失敗通知、關掉視窗登出、斷線逾時清理。截圖存在 `test/e2e/out/`。

需要連到叢集的測試（lint 做 server 端 dry run，不建立任何資源）：

```bash
cd ~/rdp-jupyter
bash test/deploy/render.test.sh
bash test/deploy/lint.test.sh
```

`lint.test.sh` 用固定版本的 kubeconform 和 kube-linter，並對套用了 Pod Security `baseline` profile 的暫時 namespace 做 dry run。

## Step 4：供應鏈檢查（SBOM 與漏洞掃描）

```bash
cd ~/rdp-jupyter
bash test/image/supply-chain.test.sh ghcr.io/braveantony/rdp-jupyter:0.1
```

用固定版本的 syft 產生 SBOM、trivy 掃描漏洞，結果寫到 `test/e2e/out/`（`sbom.spdx.json`、`trivy.txt`）。High／Critical 漏洞要不就修掉，要不就在 [docs/ops/2026-11-04-accepted-risks.md](ops/2026-11-04-accepted-risks.md) 說明理由，並在 `.trivyignore` 列出。目前已接受的風險是 JupyterLab 剪貼簿 XSS（CVE-2026-102831）：上游的 JupyterLab Desktop 還沒有修好的發行版，而弱點程式打包在 Electron bundle 裡，單升 pip 套件修不了實際 UI；等 JupyterLab Desktop 出 `4.6.4-1` 以後要重新評估。

## Step 5：載入 tk8s 的節點並部署

tk8s 的節點是 podman container，映像檔要直接載入節點的 container 儲存區（`imagePullPolicy` 是 `IfNotPresent`，節點上已有這個 tag 就不會去 ghcr.io 拉）。用 `skopeo` 而不是 `podman load`，因為 `podman load --root` 指到節點儲存區時會寫入 podman 的狀態資料庫，和別的工具用過的 `--runroot` 衝突時會報 `database configuration mismatch`；`skopeo` 只寫映像檔。

```bash
cd ~/rdp-jupyter
podman save -o /tmp/rdp-jupyter.tar ghcr.io/braveantony/rdp-jupyter:0.1
for n in tk8s-control-plane-1 tk8s-worker-1 tk8s-worker-2; do
  st=/var/lib/containers/storage/volumes/$n-var/_data/lib/containers/storage
  sudo test -d "$st/overlay-images" || { echo "找不到 $n 的儲存區，用 sudo podman ps 確認節點名稱"; break; }
  sudo skopeo copy docker-archive:/tmp/rdp-jupyter.tar \
    "containers-storage:[overlay@$st+/run/rdp-jupyter-load-$n]ghcr.io/braveantony/rdp-jupyter:0.1"
done
rm -f /tmp/rdp-jupyter.tar
```

接著部署並從區網連線（tk8s 的節點在主機內部網段，區網的 Windows 連不到 NodePort，所以用 socat 把主機的 3391 轉到任一節點的 30391）。下面的 `172.22.0.2` 是範例裡 tk8s-worker-1 的 IP，**請換成你自己叢集的節點位址**（`kubectl get nodes -o wide` 的 INTERNAL-IP 欄裡任一個）：

```bash
cd ~/rdp-jupyter
kubectl apply -k manifests/stateless
kubectl -n rdp-jupyter rollout status deploy/rdp-jupyter
podman run -d --name rdp-jupyter-forward --restart=always --network host \
  docker.io/alpine/socat:1.8.0.3 TCP-LISTEN:3391,fork,reuseaddr TCP:172.22.0.2:30391
```

Windows「遠端桌面連線」填 `<主機 IP>:3391`（例如 `192.168.11.64:3391`），接下來的操作見[使用手冊](user-guide.md)。原理和開機後自動啟動的設定見[安裝手冊的「從區網連線」](install.md#從區網連線節點在內部網段時)。

## Step 6：推到 ghcr.io

需要一個有 `write:packages` 權限的 GitHub Personal Access Token（PAT）。

```bash
podman login ghcr.io -u braveantony      # 密碼貼上 PAT
podman push ghcr.io/braveantony/rdp-jupyter:0.1
```

Dockerfile 裡的 `org.opencontainers.image.source` label 會讓 ghcr.io 自動把 package 連到 repo。第一次推送後，到 GitHub 的 **Packages → rdp-jupyter → Package settings → Change visibility**，設為 Public，別人才拉得到。

## 完整驗收（e2e，選用）

在真實的 tk8s 上跑完整的端到端驗收（spec A7）：

```bash
cd ~/rdp-jupyter
bash test/e2e/run.sh all
```

它會自己用 `skopeo` 把映像檔載入節點、部署 Kustomize、用 e2e client 以 RDP 登入，跑 stateless、額外套件、stateful、PyPI 連不到、kernel 記憶體上限、OOM 等情境（`oom` 只記錄不當成 PASS，結果手動寫進 `docs/ops/`）。只能用眼睛確認的項目列在 [test/e2e/manual-checklist.md](../test/e2e/manual-checklist.md)。執行前注意：它會**重新部署並在結束時清掉** namespace `rdp-jupyter`，不要在正式使用中的叢集上跑。

## 升級 JupyterLab Desktop（每月例行）

Electron／Chromium 的安全更新是跟著 JupyterLab Desktop 的發行版走的，所以**每個月**檢查一次上游有沒有新版本。版本號和雜湊都在 `images/rdp-jupyter/Dockerfile` 開頭：

```dockerfile
ARG JLD_VERSION=4.6.3-1
ARG JLD_SHA256=447210fe8128ab4fa2d792aec31fbb8e080c4abdacd74f87666146fd4131378a
```

升級步驟：

1. 到 [JupyterLab Desktop releases](https://github.com/jupyterlab/jupyterlab-desktop/releases) 看有沒有新版本。有的話，下載對應的 `JupyterLab-Setup-Debian-x64.deb`，算出 SHA-256（`sha256sum`），更新 Dockerfile 的 `JLD_VERSION` 和 `JLD_SHA256`。
2. 確認 venv 的 `jupyterlab` pin 跟新版 Desktop 打包的 `jupyterlab` 版本一致（看新版 `.deb` 裡 `resources/env_installer/jlab_server.tar.gz` 的 `conda-meta/jupyterlab-*`），需要時更新 `requirements.in` 並重新編譯 `requirements.lock`（指令在 `requirements.in` 的註解裡）。兩者刻意保持一致。
3. **重跑 token patch**：直接重新建置就會跑（builder 階段執行 `patches/token-env.sh`）。它會檢查 `settings.js` 和 `server.js` 的原文是否剛好各出現一次，上游改了程式會讓建置失敗——這是刻意的保護，不要繞過，而是看新版的程式改成什麼、更新 patch 的比對字串。也務必跑 `test/unit/token-env.test.sh`。
4. **逐條重新確認 spec 的上游行為 F1～F12**（見 [docs/superpowers/specs/2026-11-03-rdp-jupyter-design.md](superpowers/specs/2026-11-03-rdp-jupyter-design.md) 第 4 節）：server 啟動方式、`JUPYTER_TOKEN`／`JUPYTER_TOKEN_FILE` 的讀取、`userData` 路徑與 single-instance 鎖、`settings.json` 的欄位、kernel culling 參數、xrdp `Policy=Default` 的接回行為等。這些是設計的前提，上游改掉任何一條都要相應調整。
5. **跑完全部測試**（Step 3）和完整驗收（`test/e2e/run.sh all`）。
6. 升級供應鏈：重跑 Step 4 的掃描，處理新出現的 High／Critical，並視情況更新 `.trivyignore` 和 [accepted-risks 紀錄](ops/2026-11-04-accepted-risks.md)。
7. 發佈新版本：改 `VERSION` 和 `manifests/base/deployment.yaml` 的 `image:` tag，把本文件 Step 2～6 指令裡的 `:0.1` 換成新版本號，重建、載入、推送。

## token patch（D5）

JupyterLab Desktop 原本把 Jupyter server 的 token 放在命令列（`--ServerApp.token=...`），同一個 Pod 裡的其他帳號能從 `/proc/*/cmdline` 讀到，拿去連別人的 server。`images/rdp-jupyter/patches/token-env.sh` 在建置時解開 `app.asar`，改兩處再打包回去：

1. `build/out/main/config/settings.js`：拿掉 `--ServerApp.token="{token}"` 這個參數。
2. `build/out/main/server.js`：在啟動 server 的環境裡加上 `JUPYTER_TOKEN`（Jupyter Server 2.20 會讀這個環境變數）。

每處修改都先確認原文剛好出現一次，否則讓建置失敗；兩個檔案都先改暫存副本，全部成功才搬回原位。這個 patch 之後可以送回上游。詳細理由見[架構文件的 token patch 一節](architecture.md#token-patchd5)。

## 附錄：已知行為與建置時踩過的坑

| 現象 | 原因與處理 |
|---|---|
| 登入後畫面一片空白、JupyterLab 沒出現 | `/dev/shm` 太小。Chromium／kernel 會把中文字型或大陣列放進共用記憶體，預設 64 MiB 不夠。K8s 部署已掛 1 GiB 的記憶體 `emptyDir`；用 podman 直接執行時要加 `--shm-size=1g` |
| 在container裡 `apt-get install` 失敗 | Mesa／LLVM 被 `--force-depends` 移除，apt 看到壞掉的依賴。要改系統套件請改 Dockerfile 重建，不要在container裡裝 |
| Electron 在 tk8s 上起不來、`No usable sandbox!` | RuntimeDefault seccomp 擋掉 Chromium 的 namespace sandbox。`startwm.sh` 以 `--no-sandbox` 啟動；理由見[架構文件](architecture.md#威脅模型) |
| `JUPYTER_LOCALE=zh-tw` 但介面是英文 | 使用者可能在選單裡改過語言，以使用者的設定為準；或 `overrides.json` 沒產生，確認 entrypoint 有寫出 `/opt/jupyter/venv/share/jupyter/lab/settings/overrides.json` |
| container的環境變數在桌面裡讀不到 | sesman 用乾淨的環境啟動桌面。entrypoint 用 `session-env.sh` 把設定寫到 `/run/rdp-jupyter/session.env`，由 `startwm.sh` 和 `server-env.sh` 讀取 |
| 建置時 token patch 失敗 | 上游改了 `settings.js` 或 `server.js`。看新版程式更新 patch 的比對字串，再重建 |
