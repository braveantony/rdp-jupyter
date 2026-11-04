# 手動驗收清單（A11：分析師從零開始跑一份 notebook）

`test/e2e/run.sh` 已經自動驗證了所有能用程式檢查的部分（三帳號同時登入、`pandas.read_sql`
查叢集內的 PostgreSQL、額外套件安裝、`requirements.txt` 沒變時跳過、pip 被擋時的
`xmessage`、kernel 記憶體上限、OOM 行為）。

這份清單是給**分析師本人**用的：請用真實的 RDP 用戶端（Windows 遠端桌面、Remmina、
FreeRDP 等），照 README 從零開始，完整跑一遍。每一步請填「花費時間」和「卡住的地方」，
目的是量出真實使用者的體感，而不是只確認功能存在。

> 連線資訊：RDP 連到 `<任一節點 IP>:30391`，xrdp 登入畫面輸入 `帳號` / `密碼`
> （預設 `bigred` / `bigred`，正式環境請改掉）。Session 選 `Xorg`。

| 步驟 | 要做的事 | 預期結果 | 花費時間 | 卡住的地方 |
|---|---|---|---|---|
| 1. 從零部署 | 照 README 執行 `kubectl apply -k manifests/stateful`（要保留檔案就用 stateful），再 `kubectl -n rdp-jupyter wait --for=condition=Ready pod -l app=rdp-jupyter --timeout=180s` | Pod 進入 Ready，沒有 `CrashLoopBackOff` | | |
| 2. 登入 | 用 RDP 連到 `<節點 IP>:30391`，輸入帳號密碼 | 幾秒內出現全螢幕、無邊框的 JupyterLab Desktop（kiosk），介面是繁體中文 | | |
| 3. 開新 notebook | 在 Launcher 按「Python 3 (ipykernel)」 | 開出一個空的 notebook，右下角狀態列看得到記憶體用量 | | |
| 4. 讀真實資料 | 在 cell 裡連叢集內的資料來源讀一份真實資料。範例（PostgreSQL，需要時先 `%pip install --user pg8000`）：<br>`import pandas as pd, pg8000`<br>`conn = pg8000.connect(user=..., password=..., host='pg.<namespace>', port=5432, database=...)`<br>`df = pd.read_sql('SELECT * FROM <table> LIMIT 100', conn)`<br>`df.head()`<br>（MinIO 則用 `s3fs`/`boto3` 讀物件） | `df` 顯示出真實的資料列 | | |
| 5. 畫圖 | `df.plot(...)` 或 `import matplotlib.pyplot as plt; ...; plt.show()` | notebook 裡內嵌顯示圖表 | | |
| 6. 存檔 | `Ctrl+S` 存 notebook；把圖另存成檔案 `fig.savefig('out.png')` | notebook 與 `out.png` 都寫進 `~`（stateful 模式會保留） | | |
| 7. 斷線後接回 | 直接關掉 RDP 用戶端（不要關 JupyterLab 視窗），過一下再用同一帳號重新連回來 | 接回**原本那個桌面**，notebook 和 kernel 狀態都還在，不是一個全新的桌面 | | |
| 8. 關閉即登出 | 從 JupyterLab Desktop 的標題列按關閉（X） | RDP 連線隨即結束（關掉視窗就登出） | | |

## 補充觀察（有空再填）

- [ ] kernel 吃掉太多記憶體時，是不是只有那個 kernel 報 `MemoryError`，桌面其他部分還正常？
- [ ] 同時開 2～3 個 kernel 時，狀態列的記憶體上限顯示是否合理（每個 kernel 各自計算）？
- [ ] 中文輸入、字型、matplotlib 中文標籤有沒有問題？
- [ ] 從按下 RDP 連線到能開始打第一行程式，大約幾秒？

## 已知限制（先讓分析師心裡有數）

- 所有人的桌面都在**同一個 Pod** 裡，kernel 的記憶體上限是「每個程序各自計算」。同一個人開
  N 個 kernel，最多可用 N × `KERNEL_MEMORY_LIMIT`；全部加起來超過 Pod 的 `limits.memory`
  時，整個 Pod 會被 OOM 殺掉，所有人的未存檔內容都會消失（spec F11）。需要強隔離時改用
  JupyterHub。
- stateless 模式（emptyDir）Pod 一重建，`~` 和額外套件就全沒了；要保留請用 stateful（PVC）。
- 斷線中的桌面也算進 `MAX_SESSIONS`；滿了的話新使用者會被擋下，可調短 `DISCONNECTED_TIMEOUT`。
