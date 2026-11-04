# rdp-jupyter 設計

- 日期：2026-11-03
- 狀態：待審
- 範本：`~/rdp-vscode`（主要）、`~/rdp-firefox` v3
- Spike 紀錄：本文第 3 節（spike 用的映像檔和腳本只當參考，不進 repo）

## 1. 目標與定位

用 Windows 內建的遠端桌面連進 Kubernetes 叢集，登入後就是全螢幕的 JupyterLab Desktop。kernel 在 Pod 裡執行，用 `<service>.<namespace>` 直接連叢集內的資料庫、物件儲存等服務做資料分析。

### 為什麼不用 JupyterHub

多人共用 Jupyter，在 Kubernetes 上的標準做法是 JupyterHub + KubeSpawner：一人一個 Pod，資源和隔離都比較完整。本專案的取捨是：

| | rdp-jupyter | JupyterHub + KubeSpawner |
|---|---|---|
| 對外開放 | 一個 NodePort（RDP），不必開 HTTP、Ingress、TLS | 要開 Web 入口，通常還要 Ingress、TLS、認證 |
| 用戶端 | Windows 內建的 `mstsc` | 瀏覽器 |
| 叢集上的元件 | 一個 Deployment | Hub、Proxy、每人一個 Pod，加上 Hub 的資料庫 |
| 帳號隔離 | 同一個 Pod 裡用 UID 隔離（見第 6 節） | 每人一個 Pod |
| 資源隔離 | 每個 kernel 有記憶體上限，但整個 Pod 共用 limits（見第 7 節） | 每人各自的 requests 和 limits |

**適合**：小團隊（同時 3～5 人）、實驗或教學叢集、不想對外開 Web 服務、已經在用 rdp-firefox 或 rdp-vscode 的環境。
**不適合**：大量使用者、需要強隔離或每人各自的資源配額、每人需要 GPU。這些情況請用 JupyterHub。

### 非目標

- SSH 或 tkadm 相關功能
- 在 Pod 裡提供 Web 版 Jupyter 給瀏覽器連
- RDP 檔案傳輸或磁碟轉送（決策 D9）
- 分享桌面
- CI；沿用 rdp-vscode 的做法：手動用 podman 建置、手動 push

## 2. 決策

| 編號 | 決策 | 理由 |
|---|---|---|
| D1 | 應用程式用 JupyterLab Desktop（固定版本，目前是 4.6.3-1） | 使用者要「獨立應用程式」的外觀；spike 證實可行 |
| D2 | 映像檔解壓縮後 ≤ 1.2 GB，用 image 測試強制檢查 | 使用者的要求；spike 原樣是 2.1 GB |
| D3 | 映像檔只預裝 pandas、matplotlib；其他套件有兩個來源：管理者透過 Kustomize ConfigMap 提供 `requirements.txt`，由 postStart 安裝；使用者自己用 `%pip install --user` 裝到 `~/.local` | 使用者的要求 |
| D4 | 預設從 pypi.org 下載，可以用 `PIP_INDEX_URL` 改成內部鏡像站 | 使用者的要求 |
| D5 | token 防護：建置時修改 `app.asar`，token 改用環境變數傳，不放在命令列 | 唯一能完全消除外洩的做法（第 6 節） |
| D6 | sesman 用 `Policy=Default`：斷線後重新連線會接回原本的桌面；斷線的桌面預設 8 小時後清掉 | 資料分析最怕運算結果不見；代價是同一帳號不能同時開兩個桌面 |
| D7 | 每個 kernel 有記憶體硬上限（`RLIMIT_DATA`），預設 2Gi | 避免一個人觸發 OOM，連帶殺掉整個 Pod（第 7 節） |
| D8 | 名稱：repo `braveantony/rdp-jupyter`、Apache-2.0、namespace `rdp-jupyter`、NodePort `30391`、映像檔 `ghcr.io/braveantony/rdp-jupyter`（2026-11-03 已確認都沒有被占用） | 跟同系列專案一致 |
| D9 | 資料只透過叢集服務（MinIO/S3、資料庫、Git）進出，文件提供範例；不開 RDP 檔案傳輸 | RDP 傳檔需要 FUSE，Pod 要有 `/dev/fuse` 和 `SYS_ADMIN` |
| D10 | 介面預設繁中，`JUPYTER_LOCALE=en` 切換成英文 | 跟 rdp-vscode 一致 |
| D11 | 基底用 `debian:trixie-slim`，從頭建置，不以 rdp-vscode 為基底 | 控制大小；trixie 跟 tk8s 節點的 OS 一致 |
| D12 | Python 用 Debian 的 python3（3.13）建 venv，不用上游內建的 conda 環境 | 內建環境 1.0 GB，精簡 venv 實測約 234 MB |

## 3. Spike 結果（2026-11-03，本機 podman）

| 項目 | 結果 |
|---|---|
| 透過 xrdp 顯示 | 本機 podman 正常；但在 tk8s（CRI-O、RuntimeDefault seccomp）上 Electron sandbox 起不來（`unshare` 回 ENOSYS，「No usable sandbox!」），見第 6 節「Electron sandbox」 |
| 執行 notebook | pandas、matplotlib、對外連線都正常 |
| 只用 `--python-path` 指定環境 | 不夠，會出現「No default environment found」；要寫 `settings.json` 的 `pythonPath` |
| 上游內建的 conda 環境 | 解壓縮後要用環境自己的 python 執行 `conda-unpack`，不然 kernel 路徑錯誤 |
| 同一帳號登入第二次 | 新的程式會把請求交給第一個桌面的程式後結束，連線馬上斷掉；每個桌面各自一個 `XDG_CONFIG_HOME` 就解決了 |
| server 監聽位址 | 只有 127.0.0.1 |
| token | 出現在 `ps` 的輸出，其他帳號讀得到（已用 `nobody` 驗證） |
| 關掉視窗 | 登出並中斷遠端桌面 |
| 3 個桌面都閒置時 | 容器用了約 1.5 GB 記憶體 |
| `RLIMIT_DATA` 1 GiB 下配置 1.6 GB | 那一格程式碼出現 `MemoryError`，kernel 還活著；但一定要設 `OPENBLAS_NUM_THREADS`，否則 OpenBLAS 一 import 就失敗 |

## 4. 上游行為與出處

設計依賴下列行為。升級 JupyterLab Desktop 或 Jupyter Server 時，要逐條重新確認。

| # | 行為 | 出處（jupyterlab-desktop v4.6.3-1，commit `2b2fbe2`） |
|---|---|---|
| F1 | server 的啟動方式：`source <env>/bin/activate` 之後執行 `python -m jupyterlab ... --ServerApp.token="<token>"`；launch 腳本放在 0700 的暫存目錄 | `src/main/server.ts` 的 `createLaunchScript`；`src/main/config/settings.ts` 的 `serverLaunchArgsFixed` |
| F2 | 固定加上 `--JupyterApp.config_file_name=""`，server 不讀任何設定檔 | `settings.ts` 的 `serverLaunchArgsDefault` |
| F3 | `userData` 用 Electron 預設（Linux 上是 `$XDG_CONFIG_HOME/jupyterlab-desktop`）；single-instance 鎖也在這個目錄 | `src/main/main.ts`（`handleMultipleAppInstances`）、`src/main/utils.ts`（`getUserDataDir`） |
| F4 | `JLAB_DESKTOP_CONFIG_DIR` 決定 server 的 `JUPYTER_CONFIG_DIR` | `server.ts` 第 294 行 |
| F5 | 環境驗證只執行 `env_info.py`：確認能 import jupyterlab，並判斷是 venv 還是 conda | `src/main/env_info.py` |
| F6 | `settings.json` 的欄位與預設值（`pythonPath`、`startupMode`、`serverArgs`、`checkForUpdatesAutomatically` 等） | `settings.ts` 的 `UserSettings` |
| F7 | Jupyter Server 2.20 會讀 `JUPYTER_TOKEN` 和 `JUPYTER_TOKEN_FILE` | `jupyter_server/auth/identity.py` 第 211～216 行 |
| F8 | kernel connection file 用 `secure_write` 寫成 0600；ZMQ 訊息有 HMAC 簽章 | `jupyter_client/connect.py`、`jupyter_core/paths.py` |
| F9 | 支援 `MappingKernelManager.cull_idle_timeout`、`cull_interval`、`cull_busy`、`cull_connected` | `jupyter_server/services/kernels/kernelmanager.py` |
| F10 | postStart 和 ENTRYPOINT 同時開始；hook 失敗容器就會被殺；hook 可能執行不只一次；hook 執行完之前，容器可能不會進入 Running；失敗時只留下 `FailedPostStartHook` 事件 | Kubernetes 文件 `container-lifecycle-hooks.md` |
| F11 | tk8s 是 v1.37.1、cgroup v2，沒有設定 `singleProcessOOMKill`，所以容器 OOM 時整個被殺（`memory.oom.group`） | `kubectl get --raw .../configz`；**2026-11-04 e2e 實測確認**：`memory.oom.group=1`、`singleProcessOOMKill` 未設、配置 5GB 超過 4Gi limit 時整個 Pod 被 OOMKilled 重啟（restartCount 0→1），見 `docs/ops/2026-11-04-tk8s-e2e.md` |
| F12 | xrdp 0.10.1 的 `Policy=Default` 等於 `UB`：同一帳號、同一色深的連線會接回原本的桌面。Xorg 類型的桌面色深固定是 24，所以 client 用 16 bit 連線也會接回同一個桌面（Task 10 實測） | `/etc/xrdp/sesman.ini` 的註解；`libipm/scp.c`（`/* bpp is fixed for Xorg session types */`） |

## 5. 架構

### 元件

| 元件 | 位置 | 角色 |
|---|---|---|
| RDP 用戶端 | 使用者電腦 | 連到 `<節點 IP>:30391` |
| xrdp + xrdp-sesman | Pod | 接受 RDP 連線；`Policy=Default`，斷線後接回原本的桌面 |
| openbox | Pod | kiosk 模式：視窗最大化、無邊框 |
| JupyterLab Desktop | Pod 的 `/opt/JupyterLab` | Electron 應用程式；`app.asar` 已套用 token patch |
| Jupyter server 和 kernel | Pod，每個桌面各一組 | 由 JupyterLab Desktop 啟動，只監聽 127.0.0.1 |
| 基本 venv | `/opt/jupyter/venv` | root 擁有、使用者唯讀；jupyterlab、ipykernel、pandas、matplotlib、繁中語言包、jupyter-resource-usage |
| 額外套件 | `/opt/jupyter/extra/current` | postStart 依 ConfigMap 安裝，透過 `.pth` 接進 venv |
| 使用者套件 | `~/.local` | 使用者自己 `%pip install --user`；stateful 模式會保留 |

### 連線流程

1. 使用者用 RDP 連到 NodePort `30391`，在 xrdp 登入畫面輸入帳號密碼
2. sesman 找同一帳號斷線中的桌面：有就接回；沒有就建立新的 Xorg，執行 `startwm.sh`
3. `startwm.sh` 準備這個桌面專用的目錄、寫入 `settings.json`，再啟動 JupyterLab Desktop
4. JupyterLab Desktop 執行 launch 腳本：載入 venv 的 `activate`（裡面會套用記憶體上限和執行緒數），啟動 Jupyter server；token 透過環境變數傳
5. 使用者在 notebook 裡用 `<service>.<namespace>` 連叢集內的服務；notebook 存在 `~/`
6. 關掉視窗，桌面就結束；斷線則依 `DISCONNECTED_TIMEOUT` 保留

### 每個桌面的目錄

`startwm.sh` 建立 `/tmp/sess/<display>.<uid>/`（0700），沿用 rdp-vscode 的規則：別的帳號建立、自己刪不掉的目錄就拒絕使用。

| 路徑 | 用途 |
|---|---|
| `$S/xdg` | `XDG_CONFIG_HOME`，也就是這個桌面的 `userData`（F3）。`Policy=Default` 下同一帳號只會有一個桌面（F12），這個隔離是保險：萬一同一帳號出現兩個桌面（例如之後改用 `Policy=Separate`），JupyterLab Desktop 的 single-instance 鎖不會讓第二個桌面一啟動就結束 |
| `$S/xdg/jupyterlab-desktop/settings.json` | 每次啟動都重新寫入（見下表） |
| `$S/run` | `XDG_RUNTIME_DIR` |
| `~/.jupyter` | `JLAB_DESKTOP_CONFIG_DIR`（F4）：JupyterLab 的使用者設定（主題、快捷鍵等），在桌面之間共用，stateful 模式會保留 |

`settings.json` 內容：

| 欄位 | 值 |
|---|---|
| `pythonPath` | `/opt/jupyter/venv/bin/python` |
| `startupMode` | `new-local-session` |
| `checkForUpdatesAutomatically`、`installUpdatesAutomatically`、`notifyOnBundledEnvUpdates`、`showNewsFeed` | `false` |
| `defaultWorkingDirectory` | `$HOME` |
| `serverArgs` | `--MappingKernelManager.cull_idle_timeout=<KERNEL_CULL_IDLE_TIMEOUT> --MappingKernelManager.cull_interval=300 --ResourceUseDisplay.mem_limit=<KERNEL_MEMORY_LIMIT 換算成 bytes>`（F2：只能從這裡傳） |

### 語系

entrypoint 依 `JUPYTER_LOCALE` 產生 `/opt/jupyter/venv/share/jupyter/lab/settings/overrides.json`，把 `@jupyterlab/translation-extension:plugin` 的 `locale` 設成 `zh_TW` 或 `en`。這只是預設值，使用者在選單裡改過語言時，以使用者的設定為準。

## 6. 安全

### 威脅模型

情境：同一個 Pod 裡，帳號 A 想以帳號 B 的身分執行程式，或讀 B 的資料。

| 攻擊途徑 | 對策 | 驗證（`test/image/isolation.test.sh`，以 A 的身分執行） |
|---|---|---|
| 從 `/proc/*/cmdline` 讀到 B 的 token | D5：token 只放在 B 的程序環境變數裡 | 在 B 登入的過程中持續輪詢，要抓不到 token |
| 讀 B 的 `/proc/<pid>/environ`、ptrace B 的程序 | Linux 預設只有同 UID 能做；`allowPrivilegeEscalation: false` | 要讀不到、attach 不上 |
| 連 B 的 Jupyter server（127.0.0.1） | 沒有 token 就無法通過認證 | 不帶 token 呼叫 `/api/kernels`，要回 403 |
| 連 B 的 kernel ZMQ 埠 | F8：connection file 0600、HMAC 簽章 | 送出未簽章的 execute 請求，要被拒絕 |
| 讀 B 的家目錄、`$S`、`~/.local/share/jupyter/runtime` | 家目錄 0700（沿用 rdp-vscode）；`$S` 0700；runtime 目錄 0700 | 要讀不到 |
| 改寫共用的 venv 或 extra 目錄 | root 擁有，使用者唯讀 | 寫入要失敗 |
| 透過 JupyterLab Terminal 拿到 shell | 不算漏洞：A 本來就能在自己的桌面開 shell，權限只有 A 自己 | 寫進文件 |

### token patch（D5）

- 建置時在 builder stage 用 `@electron/asar` 解開 `app.asar`，改兩個地方再打包回去：
  1. `build/out/main/config/settings.js`：從 `serverLaunchArgsFixed` 拿掉 `--ServerApp.token="{token}"`
  2. `build/out/main/server.js`：在 `execOptions.env` 加上 `JUPYTER_TOKEN: this._info.token`（F7）
- patch 用腳本 `images/rdp-jupyter/patches/token-env.sh` 執行：每處修改都先確認原文剛好出現一次，否則讓建置失敗。升級上游時，patch 失效會在建置階段就被擋下
- 文件記錄這個 patch，之後可以送回上游

### Electron sandbox（Task 0 結果，使用者決定）

- tk8s 的 RuntimeDefault seccomp 擋掉 `unshare`，Chromium 的 namespace sandbox 無法啟動；JupyterLab Desktop 的套件沒有 `chrome-sandbox`，就算有，`allowPrivilegeEscalation: false`（NoNewPrivs）也會讓 SUID 失效
- 決定：`startwm.sh` 啟動 `jupyterlab-desktop` 時加 `--no-sandbox`。Pod 維持 RuntimeDefault seccomp，符合 Pod Security baseline（A8）
- 理由：這份威脅模型的邊界是 UID。renderer 被攻破後拿到的是使用者自己的 UID，而使用者本來就能透過 kernel 以這個 UID 執行任意程式；帳號之間的隔離（上表）不受影響
- 不採用：seccomp `Unconfined`（所有 kernel 失去 syscall 過濾、違反 A8）；Localhost seccomp profile（要改每個節點）
- 代價：惡意 notebook 輸出若攻破 renderer，可以用該使用者的權限做事，等同使用者自己執行程式

### 其他

- 帳號密碼來自 Secret，不寫進映像檔；TLS 憑證在容器啟動時產生（沿用 rdp-vscode）
- 預設帳密 `bigred`／`bigred` 只適合隔離的實驗叢集，README 要加警告（沿用 rdp-vscode）

## 7. 記憶體與長時間運算

### 記憶體上限

| 項目 | 做法 |
|---|---|
| kernel 上限 | 建置時在 venv 的 `bin/activate` 最後加一行 `. /opt/rdp-jupyter/server-env.sh`。launch 腳本會 source 這個檔案（F1），所以它設定的 `ulimit -S -H -d` 會由 Jupyter server 和之後啟動的 kernel、Terminal 繼承，使用者不能調高。大小由 `KERNEL_MEMORY_LIMIT` 決定，預設 `2Gi` |
| 執行緒數 | 同一個檔案設定 `OPENBLAS_NUM_THREADS`、`OMP_NUM_THREADS`、`MKL_NUM_THREADS`，由 `KERNEL_THREADS` 決定，預設 `2` |
| 設定怎麼傳到桌面 | sesman 用乾淨的環境啟動桌面，容器的環境變數不會帶進去（rdp-vscode 踩過）。entrypoint 驗證後寫出 `/run/rdp-jupyter/session.env`，`startwm.sh` 和 `server-env.sh` 都從這裡讀 |
| Pod 資源 | 公式：`limits.memory ≈ MAX_SESSIONS ×（0.5Gi + KERNEL_MEMORY_LIMIT）`。預設 3 人：requests `1` CPU／`2Gi`，limits `4` CPU／`8Gi` |
| 閒置回收 | `KERNEL_CULL_IDLE_TIMEOUT` 預設 `3600` 秒；正在執行的 kernel 不回收 |
| 用量顯示 | `jupyter-resource-usage` 在狀態列顯示記憶體用量；上限透過 `--ResourceUseDisplay.mem_limit` 一起放進 `serverArgs` |
| 已知限制 | 上限是每個程序各自計算。同一個人開 N 個 kernel，最多可用 N × `KERNEL_MEMORY_LIMIT`；超過 Pod limits 時整個 Pod 會被殺（F11）。寫進文件，靠閒置回收降低機率 |

### 斷線與重新連線（D6）

- `sesman.ini`：`Policy=Default`、`KillDisconnected=true`，`DisconnectedTimeLimit` 由 `DISCONNECTED_TIMEOUT` 決定，預設 `28800`（8 小時）
- 最短是 60 秒：xrdp 0.10 由 xorgxrdp 負責清掉斷線的桌面，它會把小於 60 的值當成 60，而且每 10 秒才檢查一次（`module/rdpClientCon.c`），所以實際會在逾時後 0～10 秒內清掉。entrypoint 遇到小於 60 的值會改成 60，並在 log 印出警告
- entrypoint 依環境變數改寫 `sesman.ini`（只接受正整數，不合法時用預設值並在 log 印出警告）
- `MAX_SESSIONS` 的計算包含斷線中的桌面，文件要寫明
- 同一帳號第二次登入會接回原本的桌面，第一個連線會被中斷
- 斷線逾時清掉桌面時，沿用 rdp-vscode 的 trap 清理：先送 TERM 給 JupyterLab Desktop，讓它關掉 server 和 kernel，再刪掉 `$S`

## 8. 套件安裝

### 管理者的套件（postStart）

`/opt/rdp-jupyter/install-extra.sh` 由 postStart 執行，設計依據 F10：

| 要求 | 做法 |
|---|---|
| 沒有 ConfigMap | 直接結束 |
| 可以重複執行 | 算出 `requirements.txt`、`PIP_INDEX_URL`、映像檔版本三者的 hash，跟 `/opt/jupyter/extra/.stamp` 相同就結束 |
| 原子切換 | 先裝到 `/opt/jupyter/extra/<hash>.tmp`，成功後改名為 `<hash>`，再把 symlink `current` 原子地切過去，最後刪掉舊目錄。中途中斷不影響原本的 `current` |
| 版本衝突 | 安裝時把基本 venv 的鎖定檔當 constraints，不讓額外套件改變 pandas、numpy 等的版本 |
| hash 鎖定 | `requirements.txt` 裡有 `--hash=` 就自動加上 `--require-hashes` |
| 失敗 | 腳本一律 `exit 0`，不讓容器被殺；寫出 `/opt/jupyter/extra/FAILED`（含錯誤摘要），桌面啟動時跳出通知 |
| log | 輸出同時寫到 `/proc/1/fd/1`，`kubectl logs` 看得到 |
| 安裝期間 | hook 執行完之前容器不會 Running，Pod 不會 Ready（F10），使用者連不進來 |
| 位置 | stateless：emptyDir；stateful：PVC（`requirements.txt` 沒變就不重裝） |

`.pth`：`/opt/jupyter/venv/lib/python3.13/site-packages/rdp-jupyter-extra.pth` 的內容是 `/opt/jupyter/extra/current`，在建置時就寫好。

### 使用者自己的套件

- venv 用 `--system-site-packages` 建立，這樣 pip 才允許 `--user`。映像檔不裝任何 `python3-*` 的 Debian 套件，所以系統的 site-packages 實際上是空的
- 使用者用 `%pip install --user <套件>` 裝到 `~/.local`，只影響自己；stateful 模式會保留

### Task 0 要驗證的項目

1. 用故障注入比較 postStart 和 initContainer：PyPI 連不到、套件名稱寫錯、安裝中途刪除 Pod、hook 被執行兩次。結果寫進 `docs/spike-notes.md`。如果 postStart 有無法補救的缺點，回頭找使用者討論
2. 用 constraints 安裝到 `--target` 時，會不會重複安裝基本 venv 已有的套件；會的話，記錄浪費的空間或改用其他方式
3. `--system-site-packages` 加上 `--user` 的實際行為和 `sys.path` 順序
4. Electron 的 sandbox 在 tk8s（CRI-O、RuntimeDefault seccomp）上能不能正常運作（rdp-vscode 的 VSCodium 可以，但這次要實際確認）
5. xrdp 剪貼簿傳檔案確實需要 FUSE（D9 的前提）

## 9. 映像檔

### 建置

多階段建置：

1. **builder**：下載 `.deb` 並驗證 SHA-256（`ARG JLD_SHA256`），用 `dpkg-deb -x` 解開；拿掉 `resources/env_installer/`、zh-TW 和 en 以外的 `locales/*.pak`、`LICENSES.chromium.html`（另外保存一份到 `/usr/share/doc/jupyterlab-desktop/`）；套用 token patch。用 `uv` 依 `images/rdp-jupyter/requirements.lock`（含 hash）建 venv，刪掉測試目錄，再用 `compileall` 預先編譯
2. **final**：`debian:trixie-slim` 加上 xrdp、xorgxrdp、xauth、openbox、dbus-x11、fonts-noto-cjk、fonts-dejavu-core、locales、tini、openssl、ca-certificates、python3，以及 `.deb` 的 Depends（libgtk-3-0、libnotify4、libnss3、libxss1、libxtst6、xdg-utils、libatspi2.0-0、libuuid1、libsecret-1-0）；再從 builder 複製 `/opt/JupyterLab` 和 `/opt/jupyter/venv`

### 大小預算（解壓縮後）

| 部分 | 實測（Task 9） |
|---|---|
| 基底（debian:trixie-slim） | 81 MB |
| Xorg、xrdp、GTK、字型、系統 Python 等套件（已拿掉 Mesa/LLVM、Noto Serif CJK、locale 原始檔） | 314 MB |
| JupyterLab Desktop（含壓縮後的 Chromium 授權檔） | 281 MB |
| venv | 381 MB |
| uv | 42 MB |
| 合計 | 1.10 GB（1,100,544,807 bytes；上限 1.2 GB，由測試強制檢查） |

如果超過，先用 `dive` 找出最大的層，再評估拿掉 Mesa/LLVM 等 Xorg 不需要的依賴。Task 9 的量測與取捨記在 `docs/spike-notes.md` 第 6 節。

### 供應鏈

- 用 syft 產生 SBOM，用 trivy 掃描；High/Critical 漏洞要不就修掉，要不就在 `docs/build-image.md` 說明原因
- 升級流程寫進 `docs/build-image.md`：每個月檢查 JupyterLab Desktop 的 release（Electron 和 Chromium 的安全更新）；升級時重跑 patch、F1～F12 的確認和全部測試

## 10. 部署

沿用 rdp-vscode 的 `manifests/` 結構：

| 路徑 | 內容 |
|---|---|
| `manifests/base/` | Namespace、Deployment（`Recreate`）、NodePort Service `30391`；`/dev/shm` 用 1Gi 的記憶體 emptyDir |
| `manifests/stateless/` | `users.txt` 產生 Secret；`/home` 和 `/opt/jupyter/extra` 都用 emptyDir |
| `manifests/stateful/` | `users.txt` 產生 Secret；`/home` 和 `/opt/jupyter/extra` 用 PVC |
| `manifests/example/requirements/` | 用 `configMapGenerator` 提供 `requirements.txt` 的範例（含 hash 鎖定的範例） |
| `install.sh` | `curl \| bash` 快速安裝：stateless、一個帳號 `bigred`／`bigred` |

postStart：`exec: ["/opt/rdp-jupyter/install-extra.sh"]`；ConfigMap `rdp-jupyter-requirements` 設成 `optional: true`。

### 環境變數

| 變數 | 預設值 | 說明 |
|---|---|---|
| `USERS_FILE` | `/etc/rdp-jupyter/users` | 帳號檔案，一行一個 `帳號:密碼` |
| `RDP_USER`、`RDP_PASSWORD` | `bigred`、— | 沒有帳號檔案時使用（單機 podman） |
| `MAX_SESSIONS` | `3` | 桌面數上限（包含斷線中的桌面） |
| `DISCONNECTED_TIMEOUT` | `28800` | 斷線的桌面保留幾秒；最短 60 秒（xorgxrdp 的限制），小於 60 會改成 60 並印出警告 |
| `KERNEL_MEMORY_LIMIT` | `2Gi` | 每個 kernel 的記憶體硬上限；接受 `Mi`、`Gi` 單位 |
| `KERNEL_THREADS` | `2` | BLAS/OpenMP 執行緒數 |
| `KERNEL_CULL_IDLE_TIMEOUT` | `3600` | 閒置 kernel 幾秒後回收；`0` 代表不回收 |
| `JUPYTER_LOCALE` | `zh-tw` | `zh-tw` 或 `en` |
| `PIP_INDEX_URL` | （pip 預設） | postStart 安裝時使用的 index |

不合法的值一律改用預設值，並在 Pod log 印出警告（沿用 rdp-vscode 的 `SSH_AUTO_CONNECT` 做法）。

## 11. Repo 結構

```
rdp-jupyter/
├── LICENSE、README.md、README.en.md、VERSION、install.sh
├── images/rdp-jupyter/
│   ├── Dockerfile
│   ├── requirements.in / requirements.lock
│   ├── patches/token-env.sh
│   └── rootfs/
│       ├── opt/rdp-jupyter/   # entrypoint.sh、accounts.sh、session-env.sh、server-env.sh、install-extra.sh、notify-extra.sh
│       ├── etc/xrdp/startwm.sh
│       └── etc/rdp-jupyter/openbox-rc.xml   # kiosk 視窗規則，root 擁有；startwm.sh 用 --config-file 指定
├── manifests/                 # base、stateless、stateful、example/requirements
├── test/                      # unit、image、deploy、e2e（沿用 rdp-vscode 的 lib.sh 和 e2e client）
└── docs/                      # architecture.md、install.md、user-guide.md、build-image.md、spike-notes.md、design/、superpowers/
```

`accounts.sh` 和 `startwm.sh` 的清理邏輯從 rdp-vscode 移植，連同它們的 unit 測試一起帶過來。

## 12. 驗收標準

每一項都要能重跑，log 和截圖存在 `test/e2e/out/`。

| # | 項目 | 方法 |
|---|---|---|
| A1 | unit 測試全部通過 | `accounts`、`session-env`、`server-env`（單位換算、不合法的值）、`install-extra`（hash、原子切換、失敗處理、重複執行）、`startwm` |
| A2 | 映像檔 ≤ 1.2 GB | `test/image/smoke.test.sh` |
| A3 | 不開畫面執行測試 notebook | `nbclient` 執行 `test/image/fixtures/smoke.ipynb`（pandas、matplotlib、`MemoryError` 後 kernel 還活著） |
| A4 | 帳號隔離 | `test/image/isolation.test.sh`：第 6 節每一項都是 PASS |
| A5 | token patch 有效 | 登入後，以其他帳號身分執行 `ps`，抓不到 token；JupyterLab 正常運作 |
| A6 | 桌面行為 | 本機 session 測試：登入、執行 notebook、斷線後接回同一個桌面、關掉視窗就登出、逾時清理 |
| A7 | tk8s e2e | stateless 和 stateful 都要：登入、執行 notebook、連叢集內的服務（例如部署一個 PostgreSQL 再用 pandas 查詢）、`KERNEL_MEMORY_LIMIT` 生效、確認 OOM 時整個 Pod 被殺（F11）、postStart 故障注入 |
| A8 | manifest 檢查 | kubeconform、kube-linter 通過；Pod Security Admission `baseline` 通過 |
| A9 | 供應鏈 | syft SBOM 產生成功；trivy 沒有未說明的 High/Critical |
| A10 | 獨立審查 | 另外找一個模型（Codex）只看 spec 和程式碼做 review，處理它提出的問題 |
| A11 | 真實使用者 | 一位分析師照 README 從零開始，用真實資料跑完一份 notebook；記錄卡住的地方和花費的時間 |

## 13. 風險

| 風險 | 影響 | 對策 |
|---|---|---|
| 上游改了 `server.js` 或 `settings.js` | token patch 失效 | patch 腳本找不到原文就讓建置失敗；A5 測試 |
| 一個人開很多 kernel | 整個 Pod OOM，所有人的內容消失 | 閒置回收、狀態列顯示用量、文件說明；需要強隔離時改用 JupyterHub |
| 斷線的桌面佔用名額 | 新使用者被 `MAX_SESSIONS` 擋下 | 文件說明；`DISCONNECTED_TIMEOUT` 可以調短 |
| JupyterLab Desktop 更新慢或停止維護 | Chromium 漏洞沒有修補 | 每月檢查；trivy 掃描；最壞情況改用 Firefox kiosk（spike 時評估過的 A 方案） |
| PyPI 連不到 | 額外套件沒裝上 | 不影響 Pod 啟動；桌面跳出通知；可以設定 `PIP_INDEX_URL` |
| Electron sandbox 在 tk8s 上不能用 | 程式起不來 | Task 0 已確認不能用；改加 `--no-sandbox`，理由見第 6 節 |
