# 資料存取指南

適用映像檔：`ghcr.io/braveantony/rdp-jupyter:0.1`。

notebook 的 kernel 在叢集的 Pod 裡執行，所以可以用 `<service>.<namespace>`（例如 `postgres.default`）直接連叢集內的資料庫、物件儲存等服務，資料不必流出叢集。本文件給三種常見來源的範例，以及為什麼不能從自己的電腦直接拖檔案進來。

映像檔只預裝 pandas、matplotlib。每個範例下面都列了要先裝的套件，兩種裝法擇一：

- **自己裝**：在 notebook 執行 `%pip install --user <套件>`，裝完到 **Kernel → Restart Kernel** 再 import。stateless 模式下 Pod 重建要重裝。
- **請管理者裝**：加進 `requirements.txt` 的 ConfigMap，所有人共用（見[安裝手冊](install.md#管理者提供額外-python-套件)）。

連線用的帳號密碼、endpoint、bucket 名稱等請向管理者索取；下面的範例值要換成實際的。不要把密碼寫死在 notebook 裡，否則很容易跟著 notebook 一起 push 出去。這個桌面裡設不了環境變數、也掛不了叢集的 Secret，建議的做法是把密碼放在家目錄下的一個小檔案（例如 `~/secrets.json`），把它的權限設成 `0700`（`chmod 700 ~/secrets.json`，別的帳號讀不到），在 notebook 裡讀進來，並把這個檔案排除在 Git 之外（寫進 `.gitignore`）：

```python
import json, pathlib

creds = json.loads(pathlib.Path.home().joinpath("secrets.json").read_text())
# creds["pg_password"] 等，下面的範例用得到
```

## 為什麼不能從本機拖檔案進來（D9）

這個遠端桌面**關掉了 RDP 的磁碟轉送**，所以你**不能把自己電腦上的檔案拖進 JupyterLab**，也看不到本機磁碟。

原因是安全邊界。RDP 的磁碟轉送要靠 FUSE 把用戶端的磁碟掛進 Pod，Pod 必須有 `/dev/fuse` 並授予 `SYS_ADMIN` 這個很大的 Linux capability。這會打破本專案以 **UID 為界**的帳號隔離（見[架構文件的威脅模型](architecture.md#威脅模型)），也違反 Kubernetes Pod Security 的 baseline 等級。權衡之下，映像檔把 drive redirection（`rdpdr`）和 FUSE 掛載（`EnableFuseMount`）都關掉了。

所以資料一律透過**叢集服務**（資料庫、物件儲存）或 **Git** 進出，也就是本文件的三種方式。

> **文字剪貼簿不受影響。** 你還是可以在自己的電腦複製一段程式碼或一小段文字，在 JupyterLab 按 `Ctrl+V` 貼上。只是不能傳**檔案**。

## 1. PostgreSQL（用 pandas + SQLAlchemy）

用 SQLAlchemy 建連線，再用 pandas 直接把查詢結果讀成 DataFrame。

**要裝的套件**（加進 `requirements.txt`，或 `%pip install --user`）：

```text
sqlalchemy
psycopg2-binary
```

`psycopg2-binary` 是 PostgreSQL 的驅動（含預編譯的二進位，不必在映像檔裡裝編譯器）。pandas 已經預裝。

**讀取**：

```python
import pandas as pd
from sqlalchemy import create_engine

# 格式：postgresql+psycopg2://<帳號>:<密碼>@<service>.<namespace>:5432/<資料庫>
engine = create_engine("postgresql+psycopg2://analyst:secret@postgres.default:5432/sales")

df = pd.read_sql("SELECT region, amount FROM orders WHERE year = 2026", engine)
df.groupby("region")["amount"].sum()
```

**寫回**（把 DataFrame 存成一張表）：

```python
df.to_sql("orders_summary", engine, if_exists="replace", index=False)
```

- `<service>.<namespace>` 是叢集內的短名稱。如果 PostgreSQL 和你在同一個 namespace，也可以只寫 service 名稱。
- 查詢大表時先加 `LIMIT`，或用 `pd.read_sql(..., chunksize=...)` 分批讀，避免一次塞爆 kernel 的[記憶體上限](user-guide.md#5-記憶體與長時間運算)。

## 2. MinIO／S3（用 pandas + s3fs）

MinIO 是叢集內常見的 S3 相容物件儲存。裝了 `s3fs` 之後，pandas 可以直接用 `s3://` 路徑讀寫，底層自動透過 S3 API。

**要裝的套件**：

```text
s3fs
pyarrow
```

`s3fs` 讓 pandas 認得 `s3://` 路徑；`pyarrow` 用來讀寫 Parquet（一種以欄為單位、壓縮過的表格檔案格式，分析大資料時比 CSV 省空間也快很多；讀 CSV 可以不裝）。

**讀取**：

```python
import pandas as pd

endpoint = "http://minio.default:9000"          # <service>.<namespace>:<埠>
storage_options = {
    "key": "ACCESS_KEY",
    "secret": "SECRET_KEY",
    "client_kwargs": {"endpoint_url": endpoint},  # 指向叢集內的 MinIO，不是 AWS
}

df = pd.read_parquet("s3://datasets/orders.parquet", storage_options=storage_options)
df.head()
```

**寫回**：

```python
df.to_parquet("s3://results/orders_summary.parquet", storage_options=storage_options)
```

- `endpoint_url` 一定要指到叢集內的 MinIO（`<service>.<namespace>`），否則 s3fs 會去連真正的 AWS S3。
- 公開 bucket 不需要金鑰時，`storage_options` 可以只留 `client_kwargs`，並加上 `"anon": True`。
- 要列出 bucket、刪檔等操作，可以直接用 `s3fs.S3FileSystem(**storage_options)` 拿到一個檔案系統物件。

## 3. Git（用 dulwich）

要把 notebook 或資料集搬進搬出，Git 是最方便的方式：從叢集內或外部的 Git 服務 clone 一個 repo，改完再 push 回去。

**注意**：這個映像檔**沒有 `git` 命令列工具**（為了控制大小，系統層只裝了必要的套件，而且 apt 依賴是刻意弄壞的、不能再 `apt-get install`，見[建置手冊](build-image.md)）。所以用純 Python 的 **dulwich**，它自己實作 Git 協定，不需要 `git` 執行檔。

**要裝的套件**：

```text
dulwich
```

**clone 一個 repo**（在 notebook 的家目錄底下）：

```python
from dulwich import porcelain

porcelain.clone("http://gitea.default:3000/team/notebooks.git", "notebooks")
```

clone 下來的 `notebooks/` 會出現在左邊的檔案瀏覽器裡，可以直接打開 notebook 編輯。

**commit 並 push 回去**：

```python
from dulwich import porcelain

porcelain.add("notebooks", ["notebooks/analysis.ipynb"])
porcelain.commit("notebooks", message=b"Update analysis", author=b"Analyst <analyst@example.com>", committer=b"Analyst <analyst@example.com>")
porcelain.push("notebooks", "http://gitea.default:3000/team/notebooks.git", b"refs/heads/main")
```

- 需要帳密時，用 `porcelain.clone(..., username="...", password="...")`、`porcelain.push(..., username="...", password="...")` 傳。密碼請別寫死在 notebook 裡，照本文件開頭提到的家目錄小檔案方式讀進來。
- **一定要用 HTTP／HTTPS 的 repo 網址**（像上面的 `http://…`）。這個映像檔**沒有 `ssh` 執行檔**，所以 dulwich 的 SSH 連線（`git@…` 或 `ssh://…` 的網址）在這裡用不了。
- 連外部的 GitHub 等服務時，Pod 要連得到外網，請向管理者確認叢集的網路政策。

## 小結

| 來源 | 套件 | 怎麼連 |
|---|---|---|
| PostgreSQL | `sqlalchemy`、`psycopg2-binary` | `postgresql+psycopg2://…@<service>.<namespace>:5432/<db>` |
| MinIO／S3 | `s3fs`、`pyarrow` | `s3://<bucket>/…`，`endpoint_url` 指向 `<service>.<namespace>` |
| Git | `dulwich` | `porcelain.clone/commit/push`（純 Python，無需 `git` 執行檔） |

共通原則：資料透過叢集服務或 Git 進出，不能從本機拖檔案；連線用 `<service>.<namespace>` 短名稱；查詢大資料時注意 kernel 的[記憶體上限](user-guide.md#5-記憶體與長時間運算)。
