# rdp-jupyter

用 Windows 內建的遠端桌面連進 Kubernetes 叢集，登入後就是一個全螢幕的 JupyterLab Desktop（Jupyter 官方的桌面版）。notebook 的 kernel 在叢集的 Pod 裡執行，可以用 `<service>.<namespace>` 直接連叢集內的資料庫、物件儲存等服務做資料分析，不必把資料拉到自己的電腦。

多人可以同時使用，每個帳號登入都有自己的桌面。預設同時最多 3 個桌面，數量可以調整。

## 簡述

- 登入後就是全螢幕的 JupyterLab Desktop，開 notebook 就能寫 Python。映像檔預裝了 pandas、matplotlib，kernel 直接在 Pod 裡執行。
- 用 `<service>.<namespace>`（例如 `postgres.default`）在 notebook 裡連叢集內的 PostgreSQL、MinIO 等服務。做法和需要的套件見 [data-access.md](docs/data-access.md)。
- 對外只要開一個 NodePort（Kubernetes 在每個節點上開放的固定埠號，這裡是 30391），不必開 HTTP、Ingress、TLS。
- Windows 內建的遠端桌面就能連線，不用在自己的電腦安裝 Jupyter 或 Python。
- 多個帳號可以同時登入，各自有獨立的桌面，彼此看不到對方的家目錄和 notebook。同一個帳號從第二台電腦登入時，會接回它原本的桌面並中斷第一條連線（見[斷線後接回](#4-斷線後接回)），不會另開一個新桌面。
- 介面預設繁體中文，可以用 `JUPYTER_LOCALE` 切換成英文。
- 要保留 notebook 和自己裝的套件就用 stateful 模式：`/home` 放在 PVC（向叢集申請的永久儲存空間），Pod 重建後內容還在。

**適合**：小團隊（同時 3～5 人）、實驗或教學叢集、不想對外開 Web 服務、已經在用 rdp-firefox 或 rdp-vscode 的環境。

**不適合**：大量使用者、需要強隔離或每人各自的資源配額、每人需要 GPU。這些情況請改用 JupyterHub + KubeSpawner（一人一個 Pod，資源和隔離都比較完整）。取捨的詳細比較見[架構文件](docs/architecture.md)。

## 架構

詳細說明請參考 [docs/architecture.md](docs/architecture.md)。

## 先決條件

### Kubernetes 叢集

- kubectl、curl、bash（用 Kustomize 安裝時另外需要 git）。kubectl 已內建 Kustomize（組合 YAML 設定的工具，`kubectl apply -k` 就是用它）
- kubeconfig（通常在 `~/.kube/config`），而且權限要夠 `install.sh` 用：建立和更新 Namespace、Deployment、Service、Secret（Kubernetes 存放密碼等敏感資料的物件；stateful 模式另外要 PVC），讀取 Deployment 和 Service，列出 Node，以及列出和刪除 namespace `rdp-jupyter` 裡舊的 `rdp-jupyter-users-*` Secret
- 節點能連到 `ghcr.io` 下載映像檔（解壓縮後約 1.1 GB）
- 資源：Pod 需求 1 CPU／2 GiB，上限 4 CPU／8 GiB（以 3 人同時使用估算）。**所有桌面都在同一個 Pod 裡，共用這組上限**，詳見[安全警告](#安全警告)
- NodePort `30391` 沒有被占用，而且用戶端連得到節點的 TCP 30391 埠（防火牆要放行）

### 遠端桌面用戶端

- **Windows**：內建的「遠端桌面連線」（`mstsc`）
- **macOS**：Mac App Store 的 Windows App；新增 PC 時 Credentials 選 **Ask when required**，才會出現 xrdp 登入畫面（未實測）

## 快速開始

在已安裝 kubectl、curl、bash，而且連得到目標叢集的電腦上執行：

```bash
curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-jupyter/main/install.sh | bash
```

腳本會部署到 namespace `rdp-jupyter`，完成後印出每個節點的連線位址。用遠端桌面連到 `<節點 IP>:30391`，帳號 `bigred`、密碼 `bigred`。

這個快速安裝只有一個帳號，也不會保留 notebook 和套件。多帳號、自訂密碼或保留 home（這三項都要改用 Kustomize 部署）、沒有 Kubernetes 時的單機 podman、節點在內部網段時怎麼從區網連線，以及怎麼移除，都在[安裝手冊](docs/install.md)。

## 怎麼用

### 1. 登入

按 `Win+R`，輸入 `mstsc` 開啟「遠端桌面連線」，再連到上面的位址。出現憑證警告時按「是」。Pod 每次啟動都會產生自己的憑證，所以重建後會再次出現警告。接著會看到 xrdp 登入畫面，Session 維持 `Xorg` 不用改，輸入帳號密碼後按 OK。

### 2. 開 notebook

登入後會看到全螢幕的 JupyterLab Desktop。從啟動頁（Launcher）的「Notebook」區按 **Python 3 (ipykernel)**，就會開一個新的 notebook，可以直接寫 Python。預裝了 pandas、matplotlib，`import pandas as pd` 就能用。

![全螢幕的 JupyterLab Desktop](docs/images/01-jupyterlab-desktop.png)

左邊的檔案瀏覽器顯示的是你在 Pod 裡的家目錄（`/home/<帳號>`）。notebook 預設存在這裡。stateless 模式下 Pod 重建就會清空，要保留請用 stateful 模式（見[安裝手冊](docs/install.md)）。

> 檔案瀏覽器上方的「上傳」按鈕，上傳的是**到 Pod 裡**，它看不到你自己電腦上的檔案，所以不能用它把本機檔案送進來。把資料搬進來的方式見下一節。

### 3. 連叢集內的服務

kernel 在 Pod 裡執行，所以在 notebook 裡可以用 `<service>.<namespace>` 直接連叢集內的服務。例如用 pandas 查詢 namespace `default` 裡的 PostgreSQL：

```python
import pandas as pd
from sqlalchemy import create_engine

engine = create_engine("postgresql+psycopg2://user:pass@postgres.default:5432/mydb")
df = pd.read_sql("SELECT * FROM sales LIMIT 100", engine)
df.head()
```

讀寫 MinIO／S3、用 Git 搬進 notebook，以及每個範例需要先裝哪些套件，都在[資料存取指南](docs/data-access.md)。

> 這個桌面**不能和你自己的電腦互傳檔案**（遠端桌面的磁碟轉送和剪貼簿傳檔都已關閉，進來、出去都不行，原因見[資料存取指南](docs/data-access.md)）。資料一律透過叢集服務或 Git 進出。文字剪貼簿不受影響，複製貼上只能貼文字。

### 4. 斷線後接回

**斷線後可以接回原本的桌面**：網路斷掉或不小心關掉遠端桌面視窗，重新用同一個帳號登入，就會回到原本的桌面，正在執行的 kernel 和運算結果都還在。斷線的桌面預設保留 8 小時（`DISCONNECTED_TIMEOUT`），逾時才清掉。

代價是同一個帳號不能同時開兩個桌面：第二次登入會接回第一個桌面，第一個連線隨即中斷。

要主動結束桌面，關掉 JupyterLab Desktop 的視窗（右上角的關閉按鈕）就會登出。

完整的操作說明和常見問題見 [docs/user-guide.md](docs/user-guide.md)。

## 映像檔

映像檔是 `ghcr.io/braveantony/rdp-jupyter:0.1`，解壓縮後約 1.1 GB，內含 JupyterLab Desktop 4.6.3-1、Python 3.13 的 venv（jupyterlab 4.6.3、ipykernel、pandas、matplotlib、繁中語言包、jupyter-resource-usage），以及 Noto CJK 和 DejaVu 字型。從原始碼建置和升級的步驟見 [build-image.md](docs/build-image.md)。

## 文件

- [install.md](docs/install.md)：安裝手冊（快速安裝、Kustomize 多帳號與保留 home、單機 podman、從區網連線、移除）
- [architecture.md](docs/architecture.md)：系統運作架構（連線流程、Pod 內各 process 的職責、安全邊界與威脅模型）
- [user-guide.md](docs/user-guide.md)：使用手冊（連線登入、開 notebook、裝套件、斷線重連、多人使用、常見問題）
- [data-access.md](docs/data-access.md)：資料存取指南（PostgreSQL、MinIO／S3、Git 的範例，以及為什麼不能從本機拖檔案）
- [build-image.md](docs/build-image.md)：建置手冊（從原始碼建置映像檔、測試，到升級 JupyterLab Desktop 的完整步驟）
- [design/](docs/design/README.md)：設計決策、威脅模型、驗收標準與風險

## 環境變數

先依[安裝手冊](docs/install.md#kustomize多個帳號與保留-home) clone 這個 repo，改 `manifests/base/deployment.yaml` 的 `env`，再執行一次 `kubectl apply -k manifests/stateless`（或 `manifests/stateful`，看你用哪一個）。不合法的值一律改用預設值，並在 Pod log 印出警告。

| 變數 | 預設值 | 說明 |
|---|---|---|
| `USERS_FILE` | `/etc/rdp-jupyter/users` | 帳號檔案，一行一個 `帳號:密碼`；Kubernetes 上一定會由 Secret `rdp-jupyter-users-*` 掛載 |
| `RDP_USER` | `bigred` | 沒有帳號檔案時的登入帳號（UID 1000）；Kubernetes 上一定有帳號檔案，用不到 |
| `RDP_PASSWORD` | — | 沒有帳號檔案時的登入密碼，此時必填；Kubernetes 上用不到 |
| `MAX_SESSIONS` | `3` | 可以同時存在的桌面數上限（所有帳號合計）。**斷線後還沒被清掉的桌面也算在內**，所以斷線的桌面會一直占用名額，直到 `DISCONNECTED_TIMEOUT` 逾時 |
| `DISCONNECTED_TIMEOUT` | `28800` | 斷線的桌面保留幾秒（預設 8 小時），逾時後清掉，裡面正在執行的 kernel 和未存檔內容都會消失。**最短 60 秒**：xrdp 由 xorgxrdp 負責清桌面，它會把 1～59 的值當成 60，所以設小於 60 時會被改成 60 並在 log 印出警告。`0` 或非數字等不合法的值則改用預設 `28800` |
| `KERNEL_MEMORY_LIMIT` | `2Gi` | 每個 kernel 的記憶體硬上限（`RLIMIT_DATA`），超過會在那一格跳 `MemoryError`，kernel 本身不會死。接受 `Mi`、`Gi` 單位；小於 `1Gi` 會被改成 `1Gi`（OpenBLAS 等套件在更小的上限下會載入失敗）並印出警告 |
| `KERNEL_THREADS` | `2` | 數值運算（BLAS／OpenMP，numpy、pandas 底層用來做矩陣運算的函式庫）用的平行執行緒數（`OPENBLAS_NUM_THREADS` 等），避免一個 kernel 吃光所有 CPU |
| `KERNEL_CULL_IDLE_TIMEOUT` | `3600` | 閒置的 kernel 幾秒後自動回收（釋放記憶體）；`0` 代表不回收。正在執行的 kernel 不會被回收 |
| `JUPYTER_LOCALE` | `zh-tw` | 介面語言：`zh-tw` 或 `en`。這只是預設值，使用者在選單裡改過語言時以自己的設定為準 |
| `PIP_INDEX_URL` | （pip 預設） | postStart 安裝額外套件時使用的 pip index（pip 下載套件的來源網址）；可以改成內部鏡像站 |
| `INSTALL_TIMEOUT` | `900` | postStart 安裝額外套件的時間上限（秒）。安裝未完成前 container 還不會 Ready、使用者連不進來，所以這個值會延後可以開始連線的時間；逾時會放棄安裝並在桌面跳出通知，但不會害 Pod 啟動失敗 |

額外套件（管理者透過 ConfigMap（Kubernetes 存放設定檔的物件）提供的 `requirements.txt`，或使用者自己 `%pip install --user`）的機制見[使用手冊](docs/user-guide.md)和 `manifests/example/requirements`。

## 安全警告

**預設帳密 `bigred`／`bigred` 只適合隔離的實驗叢集。** 能連到 NodePort 30391 的人，用這組帳密就能進到叢集內部網路，在 notebook 裡以這個身分連叢集內的任何服務。部署到其他環境前，請改用[多個帳號](docs/install.md#kustomize多個帳號與保留-home)並設定自己的密碼。

**所有桌面共用同一個 Pod 的記憶體。** 每個 kernel 有各自的記憶體硬上限（`KERNEL_MEMORY_LIMIT`），但整個 Pod 的 `limits.memory` 是所有桌面、所有 kernel 一起分。一個人開很多 kernel，或很多人同時跑大運算，加起來超過 Pod 上限時，**整個 Pod 會被 OOM（記憶體用盡時，系統強制終止程式）殺掉重啟，所有人的桌面和未存檔內容都會消失**。設定 `MAX_SESSIONS` 和 Pod 的 `limits.memory` 時要一起考慮，建議公式：`limits.memory ≈ MAX_SESSIONS ×（0.5Gi + KERNEL_MEMORY_LIMIT）`。閒置回收（`KERNEL_CULL_IDLE_TIMEOUT`）可以降低發生機率。需要強隔離或每人各自的配額時，請改用 JupyterHub。

## 授權

[Apache-2.0](LICENSE)
