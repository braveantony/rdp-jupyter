# rdp-jupyter 設計文件

> **以 spec 為準。** 這份文件是給人閱讀的整理版，把設計決策用好讀的方式排出來。唯一依據是設計規格 [`docs/superpowers/specs/2026-11-03-rdp-jupyter-design.md`](../superpowers/specs/2026-11-03-rdp-jupyter-design.md)；兩邊不一致時以 spec 為準，並回頭修正這裡。

## 這是什麼

使用者用 **RDP**（Windows 遠端桌面）連進 Kubernetes 裡的一個 Pod，畫面就是全螢幕的 **JupyterLab Desktop**。notebook 的 kernel 在 Pod 裡執行，用 `<service>.<namespace>` 直接連叢集內的資料庫、物件儲存等服務做資料分析。

一句話目標：**打開遠端桌面、登入，就能開始用 Jupyter 分析叢集裡的資料，不必安裝或設定任何東西。**

### 為什麼不用 JupyterHub

多人共用 Jupyter 在 Kubernetes 上的標準做法是 JupyterHub + KubeSpawner（一人一個 Pod，資源和隔離都比較完整）。本專案的取捨：

| | rdp-jupyter | JupyterHub + KubeSpawner |
|---|---|---|
| 對外開放 | 一個 NodePort（RDP），不必開 HTTP、Ingress、TLS | 要開 Web 入口，通常還要 Ingress、TLS、認證 |
| 用戶端 | Windows 內建的 `mstsc` | 瀏覽器 |
| 叢集上的元件 | 一個 Deployment | Hub、Proxy、每人一個 Pod，加上 Hub 的資料庫 |
| 帳號隔離 | 同一個 Pod 裡用 UID 隔離（見[威脅模型](../architecture.md#威脅模型)） | 每人一個 Pod |
| 資源隔離 | 每個 kernel 有記憶體上限，但整個 Pod 共用 limits | 每人各自的 requests 和 limits |

**適合**：小團隊（同時 3～5 人）、實驗或教學叢集、不想對外開 Web 服務。**不適合**：大量使用者、需要強隔離或每人各自的配額、每人需要 GPU——這些請用 JupyterHub。

## 設計決策（D1～D12）

編號對應 spec 第 2 節。替代方案和更細的理由在 spec 裡；這裡整理成好讀的版本。

### 產品與定位

#### D8 名稱與授權
- GitHub repo：`braveantony/rdp-jupyter`
- 映像檔：`ghcr.io/braveantony/rdp-jupyter`，namespace `rdp-jupyter`，NodePort `30391`
- 授權：**Apache-2.0**（跟 JupyterLab Desktop、xrdp 相容，附帶專利授權）
- 跟同系列的 rdp-vscode、rdp-firefox 一致

#### D10 語系：預設繁中，可切換英文
`JUPYTER_LOCALE=zh-tw`（預設）或 `en`，語言包預裝。這只是預設值，使用者在選單裡改過語言時以自己的設定為準。中文輸入在本機打好、透過 RDP 剪貼簿貼上，不在 Pod 裡裝輸入法。

### 映像檔與應用程式

#### D1 應用程式：JupyterLab Desktop（固定版本）
用 Jupyter 官方的桌面版 JupyterLab Desktop（目前固定 4.6.3-1）。使用者要的是「獨立應用程式」的外觀，spike 也證實可行。升級流程見[建置手冊](../build-image.md#升級-jupyterlab-desktop每月例行)。

#### D11 基底映像檔：`debian:trixie-slim`，從頭建置
不以 rdp-vscode 為基底，從頭建置以控制大小；trixie（Debian 13 的代號）跟 tk8s 節點的 OS 一致。

#### D12 Python：Debian 的 python3（3.13）建 venv
不用 JupyterLab Desktop 內建的 conda 環境（1.0 GB），改用精簡的 venv（實測約 234 MB）。venv 用 `--system-site-packages` 建立，這樣才允許使用者 `%pip install --user`。

#### D2 大小上限 ≤ 1.2 GB（解壓縮後），由測試強制檢查
使用者的要求（spike 原樣是 2.1 GB）。為了達標，final 階段用 `--force-depends` 移除了用不到的 Mesa／LLVM 套件，代價是**映像檔的 apt 依賴是壞的，不能在上面 `apt-get install`，要改系統套件得重建**（見[建置手冊](../build-image.md#step-2建置)）。

### 套件安裝

#### D3 只預裝 pandas、matplotlib，額外套件兩個來源
- **管理者**：透過 Kustomize ConfigMap 提供 `requirements.txt`，由 postStart 安裝到 `/opt/jupyter/extra`，所有人共用。
- **使用者**：自己 `%pip install --user` 裝到 `~/.local`，只影響自己。

#### D4 預設從 pypi.org，可改內部鏡像
用 `PIP_INDEX_URL` 把 postStart 的安裝來源改成內部鏡像站。

### 安全

#### D5 token 防護：建置時改 `app.asar`，token 改用環境變數傳
JupyterLab Desktop 原本把 server token 放命令列，同 Pod 的其他帳號能從 `/proc/*/cmdline` 讀到。建置時用 patch 拿掉命令列參數、改用 `JUPYTER_TOKEN` 環境變數傳。這樣其他帳號就無法從 `/proc/*/cmdline` 讀到 token；保護範圍與前提（以 UID 為界的隔離）見[架構文件的威脅模型](../architecture.md#威脅模型)。patch 失效會在建置階段就被擋下。詳見[架構文件](../architecture.md#token-patchd5)。

#### D9 資料只透過叢集服務進出，不開 RDP 檔案傳輸
RDP 傳檔需要 FUSE（`/dev/fuse` + `SYS_ADMIN`），會打破 UID 隔離、違反 Pod Security baseline。所以關掉 drive redirection 和 FUSE，資料改走資料庫、物件儲存或 Git。範例見[資料存取指南](../data-access.md)。

### 桌面行為與資源

#### D6 斷線後接回原本的桌面
sesman 用 `Policy=Default`：同一帳號斷線後重新連線會接回原本的桌面，斷線的桌面預設 8 小時（`DISCONNECTED_TIMEOUT`）後清掉。資料分析最怕運算結果不見，所以選擇可接回；代價是同一帳號不能同時開兩個桌面。`MAX_SESSIONS` 的計算包含斷線中的桌面。

#### D7 每個 kernel 有記憶體硬上限
在 venv 的 `activate` 設 `RLIMIT_DATA`（`KERNEL_MEMORY_LIMIT`，預設 2Gi），由 server 和 kernel 繼承、使用者不能調高。避免一個人觸發 OOM（記憶體用盡時系統強制終止程式）連帶殺掉整個 Pod。超過上限的配置通常會跳 `MemoryError`、kernel 多半能存活，但不保證每種情況都如此。

## 威脅模型與風險

- **威脅模型**（帳號之間的隔離、token patch、Electron sandbox、不開檔案傳輸的理由）整理在[架構文件](../architecture.md#威脅模型)，對應 spec 第 6 節，由 `test/image/isolation.test.sh` 驗證。
- **已接受的安全風險**（目前是 JupyterLab 剪貼簿 XSS CVE-2026-102831，等上游 JupyterLab Desktop 出修補版）記在 [docs/ops/2026-11-04-accepted-risks.md](../ops/2026-11-04-accepted-risks.md)。
- **主要風險與對策**（上游改程式害 token patch 失效、一個人開很多 kernel 害整個 Pod OOM、斷線桌面占名額、JupyterLab Desktop 更新慢等）見 spec 第 13 節。

## 驗收標準

spec 第 12 節列出 A1～A11：unit 測試、映像檔大小、不開畫面跑 notebook、帳號隔離、token patch 有效、桌面行為、tk8s 端到端、manifest 檢查（kubeconform／kube-linter／Pod Security baseline）、供應鏈（SBOM／trivy）、獨立模型審查、真實使用者試用。自動化的部分在 `test/` 底下，對應指令見[建置手冊](../build-image.md#step-3測試)。

## 名詞

| 名詞 | 說明 |
|---|---|
| **rdp-jupyter Pod** | 本專案的 Pod，裡面跑 xrdp 和 JupyterLab Desktop，namespace 是 `rdp-jupyter` |
| **JupyterLab Desktop** | Jupyter 官方的 Electron 桌面版 |
| **kernel** | 跑 notebook 程式碼的 Python process，受記憶體上限和執行緒數限制 |
| **stateless / stateful** | 兩種部署方式：Pod 重建後 home 和額外套件會重置／會保留 |
| **tk8s** | 目前開發用的叢集（1 個 control-plane 加 2 個 worker） |
