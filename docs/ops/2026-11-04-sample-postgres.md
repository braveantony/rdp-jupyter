# tk8s 操作紀錄：為 A11 分析師試用建立範例 PostgreSQL

- **日期**：2026-11-04
- **叢集**：tk8s（context `kubernetes-admin@tk8s`）
- **操作者**：維護者授權，Claude 代為執行
- **目的**：`test/e2e/manual-checklist.md` 第 4 步（讀真實資料）需要一個叢集內真實存在的資料來源。e2e 測試用的 PostgreSQL（namespace `rdp-jupyter-e2e-data`）測完就由 `test/e2e/run.sh` 刪掉了，所以為分析師試用另外起一個常駐的範例資料庫。

## 建立的資源

在獨立的 namespace `sample-data` 裡部署一個 PostgreSQL 16，開機時種入一張 `sales` 範例表（20 筆、4 個地區、2026 年多個月份），方便分析師做 `GROUP BY` 與時間序列繪圖（第 4～5 步）。

| 項目 | 值 |
|---|---|
| namespace | `sample-data` |
| Service | `pg`（ClusterIP，埠 5432） |
| 叢集內連線主機 | `pg.sample-data` |
| 帳號 / 密碼 | `analyst` / `analyst` |
| 資料庫 | `analytics` |
| 表 | `sales(id, order_date, region, product, amount)` |
| 儲存 | `emptyDir`（重啟即清空並重新種入，純為試用，不保留資料） |

Manifest 全文見本次工作目錄（scratchpad）的 `sample-postgres.yaml`，內容與 `test/e2e/fixtures/postgres.yaml` 同結構，差別只在 namespace、Service 名稱與種入的資料集。

## 驗證（2026-11-04）

- `kubectl rollout status deployment/pg -n sample-data`：成功。
- 種入資料：`SELECT count(*) FROM sales` 回傳 20；依地區加總 West 7391.60、North 7160.40、East 5565.75、South 4616.25。
- 從 rdp-jupyter Pod 實測連線：`pg.sample-data` 解析到 10.98.0.182，TCP 5432 可連。
- 叢集目前沒有任何 NetworkPolicy／CiliumNetworkPolicy，跨 namespace 連線暢通。

## 從 notebook 連線（給分析師）

```python
%pip install --user sqlalchemy psycopg2-binary
# 裝完到 Kernel → Restart Kernel 再執行下面
```

```python
import pandas as pd
from sqlalchemy import create_engine

engine = create_engine(
    "postgresql+psycopg2://analyst:analyst@pg.sample-data:5432/analytics"
)
df = pd.read_sql("SELECT * FROM sales", engine)
df.head()
```

正式用法（把密碼放在 `~/secrets.json`）見 [docs/data-access.md](../data-access.md)。

## 清理

試用結束後刪掉整個 namespace 即可：

```bash
kubectl delete namespace sample-data
```
