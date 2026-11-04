# rdp-jupyter 安裝手冊

適用映像檔：`ghcr.io/braveantony/rdp-jupyter:0.1`。先決條件見 [README](../README.md#先決條件)。

## 選擇安裝方式

| 方式 | 適合 | 帳號 | `/home`、`/opt/jupyter/extra` |
|---|---|---|---|
| [快速安裝](#快速安裝installsh) | 先試用看看 | 只有 `bigred` / `bigred` | emptyDir |
| [Kustomize：stateless](#kustomize多個帳號與保留-home) | 多人使用，但不需要保留 notebook | 自己的帳號清單 | emptyDir |
| [Kustomize：stateful](#kustomize多個帳號與保留-home) | 多人使用，而且要保留 notebook 和套件 | 自己的帳號清單 | PVC（向叢集申請的永久儲存空間） |
| [單機（podman）](#單機podman) | 沒有 Kubernetes，只想在一台 Linux 主機上用 | 單一帳號，或掛載帳號清單 | container 裡（刪掉 container 就消失） |

emptyDir 是 Pod 刪掉就跟著消失的暫存空間，所以 Pod 重建後（例如重新部署）notebook 和額外套件都會回到映像檔的原始狀態。

前三種都部署到 namespace（Kubernetes 用來分組資源的名稱）`rdp-jupyter`，用遠端桌面連到 `<節點 IP>:30391`。登入步驟和操作見 [README 的「怎麼用」](../README.md#怎麼用)。

## 快速安裝（install.sh）

在已安裝 kubectl、curl、bash，而且連得到目標叢集的電腦上執行（可以先用 `kubectl config current-context` 確認目前選用的是哪個叢集）：

```bash
curl -fsSL https://raw.githubusercontent.com/braveantony/rdp-jupyter/main/install.sh | bash
```

腳本會部署單一帳號 `bigred` / `bigred`，完成後印出每個節點的連線位址。節點 IP 也可以用 `kubectl get nodes -o wide` 的 INTERNAL-IP 欄查看，連任何一個節點都可以；雲端叢集則要改成用戶端連得到的 IP（例如節點的外部 IP）。

平常不需要設定任何變數。`install.sh` 讀取的變數：

| 變數 | 說明 |
|---|---|
| `RDP_JUPYTER_IMAGE` | 改用其他映像檔，例如私有 registry 上的映像檔 |
| `RDP_JUPYTER_REF` | 下載 `manifests/` 時用的 branch 或 tag，決定部署哪個版本的設定和映像檔；預設 `main`。主要給測試用 |
| `RDP_JUPYTER_RAW` | `manifests/` 的下載位置，可以是網址或 `file://` 路徑；預設是 GitHub 上 `RDP_JUPYTER_REF` 指定的版本。主要給測試用 |

移除：`kubectl delete namespace rdp-jupyter`。

## Kustomize：多個帳號與保留 home

帳號清單寫在 `users.txt`，由 Kustomize 的 `secretGenerator` 產生 Secret（Kubernetes 存放密碼等敏感資料的物件），掛載到 container 的 `/etc/rdp-jupyter/users`。有兩種 overlay（在共用的基本設定上再加的修改，例如儲存空間要用哪一種）：

| Overlay | `/home`、`/opt/jupyter/extra` | Pod 重建時 |
|---|---|---|
| `manifests/stateless` | emptyDir | notebook、自己裝的套件、管理者的額外套件都會消失 |
| `manifests/stateful` | PVC `rdp-jupyter-home`（10 GiB）和 `rdp-jupyter-extra`（5 GiB），都是 ReadWriteOnce | `/home` 和額外套件都會保留；`requirements.txt` 沒變就不重裝 |

兩個資料夾各有自己的 `users.txt`，**要編輯的是你接下來要套用的那個資料夾裡的檔案**。

在快速安裝用的那台電腦上執行，另外需要 git：

```bash
git clone https://github.com/braveantony/rdp-jupyter.git
cd rdp-jupyter
vi manifests/stateful/users.txt   # 用你熟悉的文字編輯器修改帳號清單，這裡以 vi 為例
kubectl apply -k manifests/stateful
kubectl -n rdp-jupyter rollout status deploy/rdp-jupyter   # 等待 Pod 啟動完成（第一次要下載映像檔）
```

不需要保留時，把上面兩處的 `manifests/stateful` 都換成 `manifests/stateless`。完成後用遠端桌面連到 `<節點 IP>:30391`，以 `users.txt` 裡的帳號登入。

已經用快速安裝裝過也沒關係，直接執行 `kubectl apply -k` 就會改用新的設定；之後不要再執行 `install.sh`，否則會還原成 `bigred` / `bigred` 和 emptyDir。

### 帳號清單

`users.txt` 一行一個 `帳號:密碼`，`#` 開頭是註解：

```text
alice:Alice-pw
bob:Bob-pw
```

- 帳號規則：小寫英文字母或 `_` 開頭，可以用小寫英數字、`_`、`-`，最長 32 字元，不可以是 `root`、`xrdp` 或系統既有的帳號；密碼不可空白，可以包含冒號。檔案在 Windows 上編輯（CRLF 換行）也沒關係。不符規則時 Pod 會啟動失敗，原因可以用 `kubectl -n rdp-jupyter logs deploy/rdp-jupyter` 查看。
- 帳號依檔案順序分配 UID（Linux 的使用者編號）1000、1001……。在 stateful 模式下調換順序，Pod 啟動時會把既有的 home 改歸新的 UID 所有；被移除帳號的 home 會改由 root 擁有，之後分到同一個 UID 的帳號也讀不到。
- 修改 `users.txt` 後再執行一次 `kubectl apply -k` 即可。因為 Secret 名稱帶有內容雜湊（`rdp-jupyter-users-<雜湊>`），`users.txt` 的內容一有變動就會自動重建 Pod。所有桌面都在同一個 Pod 裡，所以重建時使用中的連線都會中斷。
- `users.txt` 含明文密碼，請不要提交到公開的 repo；可以改用 SOPS、Sealed Secrets 等工具管理。

### stateful 的 StorageClass

StorageClass 是決定 PVC 用哪種儲存的叢集設定。這兩個 PVC 都沒有指定 `storageClassName`，會使用叢集預設的 StorageClass，所以叢集一定要有一個預設的；先用 `kubectl get storageclass` 確認有沒有標著 `(default)` 的，沒有的話 PVC 會一直 `Pending`。

兩個 PVC 都是 ReadWriteOnce，而且 Deployment 用 `Recreate`，所以要落在同一個節點上。這個 StorageClass 必須是網路儲存，或設定成 `volumeBindingMode: WaitForFirstConsumer`。`local-path` 這類只存在一台節點的 volume，那台節點故障時 Pod 就起不來。

### 管理者提供額外 Python 套件

映像檔只預裝 pandas、matplotlib。要讓每個桌面都能用其他套件（例如 `sqlalchemy`、`s3fs`），管理者可以掛一份 `requirements.txt`，由 postStart 在 Pod 啟動時安裝。範例在 `manifests/example/requirements`：

```bash
cd rdp-jupyter
vi manifests/example/requirements/requirements.txt   # 一行一個套件
kubectl apply -k manifests/example/requirements
```

- 這個範例以 `manifests/stateless` 為基礎，所以帳號清單是 `manifests/stateless/users.txt`。
- `configMapGenerator` 會在 ConfigMap 名稱後面加內容雜湊，所以改了 `requirements.txt` 就會重新安裝；內容沒變則跳過。
- 安裝失敗（例如套件名稱打錯、連不到 PyPI）不會害 Pod 啟動失敗，而是在桌面跳出一個通知，log 也看得到（`kubectl -n rdp-jupyter logs deploy/rdp-jupyter`）。
- 要可重現的安裝（鎖定版本和 hash），把 `files:` 指到 `requirements-hashed.txt`，`install-extra.sh` 會自動加上 `--require-hashes`。產生 hash 的指令在 `requirements-hashed.txt` 的註解裡。
- 使用者也可以不靠管理者，自己在 notebook 裡 `%pip install --user <套件>`，裝到自己的 `~/.local`，只影響自己（stateful 模式會保留）。詳見[使用手冊](user-guide.md)。

### 其他設定

- **換映像檔**（例如私有 registry）：在 overlay 的 `kustomization.yaml` 加上 `images:` 區塊：

  ```yaml
  images:
  - name: ghcr.io/braveantony/rdp-jupyter
    newName: registry.example.com/rdp-jupyter
    newTag: "0.1"
  ```

- **改環境變數**：修改 `manifests/base/deployment.yaml` 的 `env`，再執行一次 `kubectl apply -k manifests/stateless`（或 `manifests/stateful`）。變數說明見 [README 的「環境變數」](../README.md#環境變數)。

## 單機（podman）

沒有 Kubernetes 時，可以在一台 Linux 主機上用 podman（類似 Docker 的容器工具）直接執行。單機沒有叢集內的服務可以連，主要用來試用 JupyterLab Desktop 本身。

```bash
podman run -d --name rdp-jupyter -p 13391:3389 --shm-size 1g \
  -e RDP_PASSWORD=bigred \
  ghcr.io/braveantony/rdp-jupyter:0.1
```

用遠端桌面連到 `<主機 IP>:13391`。`<主機 IP>` 是執行 podman 的那台主機的 IP；在同一台主機上連可以用 `localhost:13391`。帳號 `bigred`、密碼 `bigred`（`RDP_PASSWORD` 可以自己改）。

- `--shm-size 1g` 用來加大共用記憶體，因為用預設的 64 MiB 時，kernel 載入中文字型或大陣列會崩潰。
- **多個帳號**：用帳號清單取代 `RDP_PASSWORD`。拿掉 `-e RDP_PASSWORD=bigred`，改在映像檔名稱之前加上 `-v ./users.txt:/etc/rdp-jupyter/users:ro,Z`（`ro` 表示唯讀，`Z` 是給 SELinux 系統用的標記，沒有 SELinux 也不影響）。`users.txt` 的格式和[帳號清單](#帳號清單)相同。
- **調整 kernel 上限等設定**：用 `-e` 傳[環境變數](../README.md#環境變數)，例如 `-e KERNEL_MEMORY_LIMIT=4Gi`。單機沒有 Pod 的 `limits.memory`，kernel 上限直接受主機記憶體影響。
- notebook 和設定都在 container 裡，刪掉 container（`podman rm -f rdp-jupyter`）就會消失。

## 從區網連線（節點在內部網段時）

如果節點位在某台 Linux 主機的內部網段（例如 tk8s，節點都是主機上的 podman container），區網裡的電腦連不到 NodePort。這時在那台主機上用 socat（把一個埠的連線轉送到另一個位址的小工具），把主機的 3391 埠轉到任一節點的 30391。

在那台主機上執行（需要 podman）；`<節點 IP>` 換成 `kubectl get nodes -o wide` 的 INTERNAL-IP 欄裡任一個：

```bash
podman run -d --name rdp-jupyter-forward --restart=always --network host \
  docker.io/alpine/socat:1.8.0.3 TCP-LISTEN:3391,fork,reuseaddr TCP:<節點 IP>:30391
```

之後用遠端桌面連到 `<主機 IP>:3391`。

如果你是以一般使用者（不是 root）執行 podman，要讓這個 container 在你登出或主機重開機後仍然自動啟動，請再執行一次下面兩行：

```bash
sudo loginctl enable-linger $USER
systemctl --user enable podman-restart.service
```

## 移除

| 安裝方式 | 指令 |
|---|---|
| 快速安裝、Kustomize | `kubectl delete namespace rdp-jupyter` |
| 單機 | `podman rm -f rdp-jupyter` |
| 區網轉發 | `podman rm -f rdp-jupyter-forward` |

stateful 模式的 PVC 會跟著 namespace 一起刪除。大多數 StorageClass 預設的 reclaimPolicy 是 `Delete`，這時 `/home` 的 notebook 也會消失，要保留請先備份。
