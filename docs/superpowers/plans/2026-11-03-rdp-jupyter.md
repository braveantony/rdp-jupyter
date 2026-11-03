# rdp-jupyter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 RDP 連進 Kubernetes，登入後是全螢幕 JupyterLab Desktop 的多帳號資料分析環境，映像檔 ≤ 1.2 GB。

**Architecture:** 一個 Pod 裡跑 xrdp（`Policy=Default`，斷線可接回），每個桌面各自一個 Xorg、一份 `XDG_CONFIG_HOME` 和一組 Jupyter server/kernel。JupyterLab Desktop 的 `app.asar` 在建置時 patch，token 改用環境變數傳。kernel 記憶體上限由 venv 的 `activate` 透過 `ulimit -d` 套用。額外套件由 postStart 依 ConfigMap 原子安裝。

**Tech Stack:** Debian trixie-slim、xrdp 0.10.1、openbox、JupyterLab Desktop 4.6.3-1（Electron）、Python 3.13 venv（uv 鎖定）、bash、podman、Kustomize、tk8s（Kubernetes 1.37.1、CRI-O）。

**Spec:** `docs/superpowers/specs/2026-11-03-rdp-jupyter-design.md`（以下稱 spec，§ 表示章節）

**移植來源:** `~/rdp-vscode`（下稱 rdp-vscode）。標註「移植」的檔案從那裡複製，把 `rdp-vscode` 改成 `rdp-jupyter`，再依該 task 的說明修改。

## Global Constraints

- 程式碼、註解、commit message 用英文；文件用繁體中文（台灣用語），另附 `README.en.md`
- 腳本用 bash，`set -eu`（被 source 的檔案除外）；全部通過 `shellcheck`
- 測試沿用 rdp-vscode 的 `test/lib.sh`（`say`／`pass`／`bad`／`finish`），一支測試一個檔案，用 `bash test/<kind>/<name>.test.sh` 執行
- 路徑：程式在 `/opt/JupyterLab`；venv 在 `/opt/jupyter/venv`；額外套件在 `/opt/jupyter/extra`；腳本在 `/opt/rdp-jupyter/`；session 設定在 `/run/rdp-jupyter/session.env`；帳號檔在 `/etc/rdp-jupyter/users`；ConfigMap 掛在 `/etc/rdp-jupyter/requirements/requirements.txt`
- 名稱：namespace `rdp-jupyter`、NodePort `30391`、映像檔 `ghcr.io/braveantony/rdp-jupyter`、本機 tag `localhost/rdp-jupyter:dev`、Secret `rdp-jupyter-users`、ConfigMap `rdp-jupyter-requirements`
- 環境變數與預設值照 spec §10 的表：`MAX_SESSIONS=3`、`DISCONNECTED_TIMEOUT=28800`、`KERNEL_MEMORY_LIMIT=2Gi`、`KERNEL_THREADS=2`、`KERNEL_CULL_IDLE_TIMEOUT=3600`、`JUPYTER_LOCALE=zh-tw`。不合法的值改用預設值，並在 stderr 印出 `[entrypoint] invalid <NAME>: <value>`
- 映像檔解壓縮後 ≤ 1.2 GB（`1200000000` bytes）
- JupyterLab Desktop 固定 `4.6.3-1`；`jupyterlab` 固定 `4.6.*` 裡的單一版本，跟 Desktop 內建的版本相容
- Pod 資源：requests `1` CPU／`2Gi`，limits `4` CPU／`8Gi`
- 對 tk8s 的任何修改（不是部署本專案）都要先經使用者同意，並在 `docs/ops/` 留紀錄
- 不 push、不建立 GitHub repo、不對上游送 PR，除非使用者明確要求

## Review Focus

1. **`requirements.txt` 內容很亂**：Windows 換行（CRLF）、只有註解或空行、ConfigMap 存在但是空的。只有註解或空白時視為沒有套件；CRLF 要去掉 → Task 4
2. **`KERNEL_MEMORY_LIMIT` 設得太小**（例如 `256Mi`）：Jupyter server 自己就起不來，使用者只看到啟動失敗。低於 `1Gi` 時改用 `1Gi` 並印出警告 → Task 2
3. **用不同色深重新連線**（例如手機上的 RDP 用 16 bit）：Xorg 桌面的色深固定是 24（F12），所以會接回原本的桌面，而不是開第二個。要能看到原本的 JupyterLab 畫面 → Task 10
4. **使用者在選單改過語言**：重新登入後要保留使用者的選擇，不能被 `JUPYTER_LOCALE` 蓋掉 → Task 10
5. **stateful 模式升級映像檔**：PVC 上的額外套件是用舊版 Python/numpy 裝的，`requirements.txt` 沒變也要重裝 → Task 4

---

### Task 0: 驗證 spec §8 的五個前提

只做驗證，不寫產品程式碼。用 spike 映像檔 `localhost/rdp-jupyter-spike:b`（本機已有；不在的話，依 spec §3 用 `/tmp/claude-1000/-home-bigred-rdp-jupyter/1813561c-9839-4476-a980-a117c893f1b7/scratchpad/spike/Dockerfile` 重建），以及在 tk8s 的暫時 namespace `rdp-jupyter-spike` 建立的 Pod，做完就刪掉。

**Files:**
- Create: `docs/spike-notes.md`

- [ ] **Step 1: postStart vs. initContainer 故障注入**

在 `rdp-jupyter-spike` 用 `python:3.13-slim` 建兩個 Deployment：一個用 postStart，一個用 initContainer，都執行 `pip install -r /req/requirements.txt --target /extra`。分別注入四種情況：(a) 用 NetworkPolicy 擋掉對外連線、(b) 套件名稱寫錯、(c) 安裝中 `kubectl delete pod`、(d) 讓 hook 腳本被執行兩次。記錄：Pod 的狀態變化、`kubectl describe` 的事件、`kubectl logs` 看不看得到輸出、Pod 會不會 Ready、會不會一直重啟。
預期：依 spec F10，postStart 失敗會殺掉容器；`exit 0` 的版本不會。

- [ ] **Step 2: `--target` 加 constraints 會不會重複安裝**

在 `debian:trixie-slim` 建 `--system-site-packages` 的 venv，裝 pandas；再用 `uv pip install --target /tmp/extra -c <base 的 freeze> requests pandas`，列出 `/tmp/extra` 裡有沒有 pandas 和 numpy。
預期：記錄實際行為。有重複的話，改用 `uv pip install --target` 加上 base 的 `site-packages` 當 `--python` 參考，或接受重複並記下浪費的 MB 數。

- [ ] **Step 3: `--system-site-packages` 加 `--user`**

同一個 venv，以一般使用者執行 `pip install --user requests`，再印出 `python -c "import sys; print(sys.path)"`。
預期：安裝成功；`~/.local/lib/python3.13/site-packages` 在 `sys.path` 裡。記下它跟 venv `site-packages` 的先後順序。

- [ ] **Step 4: Electron sandbox 在 tk8s 上能不能用**

用 rdp-vscode `test/e2e/run.sh` 的 skopeo 方式，把 spike 映像檔載入 tk8s 節點，在 `rdp-jupyter-spike` 以 `allowPrivilegeEscalation: false`、RuntimeDefault seccomp 執行；用 `test/e2e/client` 登入並截圖。
預期：JupyterLab 畫面出現，不需要 `--no-sandbox`。不行的話，記錄錯誤訊息和改用的旗標。

- [ ] **Step 5: xrdp 剪貼簿傳檔案需要 FUSE**

在 spike 容器以 `rdpdr=true` 執行，查 `xrdp-chansrv` 的 log，看 `thinclient_drives` 的掛載結果，並從 `xfreerdp` 用 `+clipboard` 複製一個檔案。
預期：沒有 `/dev/fuse` 時，log 顯示 FUSE 掛載失敗，傳檔失敗。

- [ ] **Step 6: 寫 `docs/spike-notes.md`，刪掉 namespace `rdp-jupyter-spike`**

每一項寫成「問題／做法／結果／對設計的影響」。只要有任何一項推翻了 spec 的假設，就停下來回報使用者，不要繼續 Task 1。

- [ ] **Step 7: Commit**

```bash
git add docs/spike-notes.md
git commit -m "docs: record Task 0 spike results"
```

---

### Task 1: Repo 骨架與帳號（移植）

**Files:**
- Create: `LICENSE`（Apache-2.0，複製 rdp-vscode）、`VERSION`（內容 `0.1`）、`test/lib.sh`（移植）
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/accounts.sh`（移植）
- Test: `test/unit/accounts.test.sh`（移植）

**Interfaces:**
- Produces: `accounts.sh [users_file]`，建立或更新帳號後印出帳號名稱（以空白分隔），預設檔案 `/etc/rdp-jupyter/users`；行為與 rdp-vscode 相同（UID 從 1000 依序分配、home 0700、CRLF 去除、重排時重新 chown）

- [ ] **Step 1: 複製 `accounts.test.sh`，把路徑改成 `images/rdp-jupyter/...`**
- [ ] **Step 2: 執行 `bash test/unit/accounts.test.sh`**，預期 FAIL（找不到 `accounts.sh`）
- [ ] **Step 3: 複製 `accounts.sh`，把 `rdp-vscode` 改成 `rdp-jupyter`**
- [ ] **Step 4: 執行 `bash test/unit/accounts.test.sh`**，預期全部 PASS；`shellcheck` 沒有警告
- [ ] **Step 5: Commit** `feat: port account setup from rdp-vscode`

---

### Task 2: session 設定（`session-env.sh`）

**Files:**
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/session-env.sh`
- Test: `test/unit/session-env.test.sh`

**Interfaces:**
- Produces: `session-env.sh` 讀取容器環境變數，在 stdout 印出可以 source 的 `NAME=value`（用 `printf %q`），驗證失敗的值寫警告到 stderr。輸出的變數：
  - `KERNEL_MEMORY_LIMIT_KB`：整數 KiB
  - `KERNEL_MEMORY_LIMIT`：正規化後的原始字串，例如 `2Gi`
  - `KERNEL_THREADS`：正整數
  - `KERNEL_CULL_IDLE_TIMEOUT`：非負整數
  - `JUPYTER_LOCALE`：`zh_TW` 或 `en`（JupyterLab 的語系代碼）
  - `DISCONNECTED_TIMEOUT`：正整數

- [ ] **Step 1: 寫失敗的測試**

沿用 rdp-vscode `session-env.test.sh` 的 `check <name> <var> <want> [VAR=value...]` 寫法：

```bash
say defaults
check "memory 2Gi" KERNEL_MEMORY_LIMIT_KB 2097152
check "threads 2" KERNEL_THREADS 2
check "cull 3600" KERNEL_CULL_IDLE_TIMEOUT 3600
check "locale zh_TW" JUPYTER_LOCALE zh_TW
check "disconnect 28800" DISCONNECTED_TIMEOUT 28800
say memory
check "Mi" KERNEL_MEMORY_LIMIT_KB 1572864 KERNEL_MEMORY_LIMIT=1536Mi
check "Gi" KERNEL_MEMORY_LIMIT_KB 4194304 KERNEL_MEMORY_LIMIT=4Gi
check "below 1Gi is raised" KERNEL_MEMORY_LIMIT_KB 1048576 KERNEL_MEMORY_LIMIT=256Mi
check "garbage is default" KERNEL_MEMORY_LIMIT_KB 2097152 KERNEL_MEMORY_LIMIT=lots
check "bare number is default" KERNEL_MEMORY_LIMIT_KB 2097152 KERNEL_MEMORY_LIMIT=2048
say others
check "locale en" JUPYTER_LOCALE en JUPYTER_LOCALE=en
check "locale bad" JUPYTER_LOCALE zh_TW JUPYTER_LOCALE=fr
check "cull 0 allowed" KERNEL_CULL_IDLE_TIMEOUT 0 KERNEL_CULL_IDLE_TIMEOUT=0
check "threads 0 is default" KERNEL_THREADS 2 KERNEL_THREADS=0
check "disconnect bad" DISCONNECTED_TIMEOUT 28800 DISCONNECTED_TIMEOUT=-5
```

另外驗證：`KERNEL_MEMORY_LIMIT=256Mi` 時 stderr 含 `raised to 1Gi`；`KERNEL_MEMORY_LIMIT=lots` 時 stderr 含 `[entrypoint] invalid KERNEL_MEMORY_LIMIT: lots`。

- [ ] **Step 2: 執行測試**，預期 FAIL
- [ ] **Step 3: 實作 `session-env.sh`**（`case` 驗證；`Mi`、`Gi` 換算成 KiB；最小值 1Gi）
- [ ] **Step 4: 執行測試**，預期 PASS
- [ ] **Step 5: Commit** `feat: validate session settings into session.env`

---

### Task 3: kernel 執行環境（`server-env.sh`）

**Files:**
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/server-env.sh`
- Test: `test/unit/server-env.test.sh`

**Interfaces:**
- Consumes: Task 2 的 `session.env` 格式
- Produces: `server-env.sh`，由 venv 的 `bin/activate` source（Task 9 在建置時加進去）。從 `${RDP_JUPYTER_SESSION_ENV:-/run/rdp-jupyter/session.env}` 讀設定；檔案不存在就用 Task 2 的預設值。執行：`ulimit -S -H -d "$KERNEL_MEMORY_LIMIT_KB"`，並 export `OPENBLAS_NUM_THREADS`、`OMP_NUM_THREADS`、`MKL_NUM_THREADS`（都等於 `KERNEL_THREADS`）。不使用 `set -e`（被 source 的檔案），也不能讓呼叫端的 shell 結束

- [ ] **Step 1: 寫失敗的測試**

```bash
GEN=images/rdp-jupyter/rootfs/opt/rdp-jupyter/server-env.sh
f=$(mktemp); printf 'KERNEL_MEMORY_LIMIT_KB=1572864\nKERNEL_THREADS=3\n' > "$f"
out=$(RDP_JUPYTER_SESSION_ENV=$f GEN=$GEN bash -c '. $GEN; ulimit -S -d; ulimit -H -d; echo $OPENBLAS_NUM_THREADS $OMP_NUM_THREADS $MKL_NUM_THREADS')
[ "$out" = $'1572864\n1572864\n3 3 3' ] && pass "limits and threads" || bad "got: $out"
# hard limit cannot be raised again
RDP_JUPYTER_SESSION_ENV=$f GEN=$GEN bash -c '. $GEN; ulimit -S -d 3000000' 2>/dev/null && bad "raised above hard limit" || pass "hard limit holds"
# missing file falls back to defaults
out=$(RDP_JUPYTER_SESSION_ENV=/nonexistent GEN=$GEN bash -c '. $GEN; ulimit -H -d; echo $OPENBLAS_NUM_THREADS')
[ "$out" = $'2097152\n2' ] && pass "defaults" || bad "got: $out"
# sourcing never exits the caller
RDP_JUPYTER_SESSION_ENV=/nonexistent GEN=$GEN bash -c '. $GEN; echo alive' | grep -q alive && pass "caller survives" || bad "caller exited"
```

- [ ] **Step 2: 執行測試**，預期 FAIL
- [ ] **Step 3: 實作 `server-env.sh`**
- [ ] **Step 4: 執行測試**，預期 PASS
- [ ] **Step 5: Commit** `feat: apply kernel memory and thread limits from activate`

---

### Task 4: 額外套件安裝（`install-extra.sh`）

**Files:**
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/install-extra.sh`
- Test: `test/unit/install-extra.test.sh`

**Interfaces:**
- Produces: `install-extra.sh`，postStart 執行，**一律 `exit 0`**。可以用環境變數覆寫路徑（測試用）：
  - `REQ_FILE`（預設 `/etc/rdp-jupyter/requirements/requirements.txt`）
  - `EXTRA_DIR`（預設 `/opt/jupyter/extra`）
  - `BASE_CONSTRAINTS`（預設 `/opt/jupyter/constraints.txt`，Task 9 產生）
  - `IMAGE_VERSION_FILE`（預設 `/opt/rdp-jupyter/VERSION`）
  - `PIP_CMD`（預設 `uv pip install --python /opt/jupyter/venv/bin/python`；Task 0 Step 2 的結論可能改變這個預設值）
  - `LOG_OUT`（預設 `/proc/1/fd/1`；寫不進去時改寫 stdout）
- 結果：`$EXTRA_DIR/current` → `$EXTRA_DIR/<hash>`；`$EXTRA_DIR/.stamp` 內容是 `<hash>`；失敗時寫 `$EXTRA_DIR/FAILED`（前 20 行錯誤），`current` 不變。`<hash>` = sha256（去掉 CRLF 的 requirements 內容 + `PIP_INDEX_URL` + 映像檔版本）的前 16 碼
- 安裝指令：`$PIP_CMD --target $EXTRA_DIR/<hash>.tmp -c $BASE_CONSTRAINTS -r <清理後的 requirements>`；requirements 含 `--hash=` 時加上 `--require-hashes`

- [ ] **Step 1: 寫失敗的測試**

用一支假的 `PIP_CMD`（`test/unit/fixtures/fake-pip.sh`）：把收到的參數寫進 `$CALLS`，建立 `--target` 目錄並放一個 `marker` 檔；`FAKE_PIP_FAIL=1` 時印出錯誤訊息並 exit 1。每個情境用新的暫存 `EXTRA_DIR`：

| 測試名稱 | 情境 | 斷言 |
|---|---|---|
| `no requirements file` | `REQ_FILE` 不存在 | exit 0；沒呼叫 pip；沒有 `current` |
| `comments only` | 內容只有 `# x` 和空行，CRLF 換行 | 同上 |
| `first install` | `requests==2.32.3` | exit 0；`current` 指向 16 碼的目錄；`.stamp` 等於該目錄名稱；`current/marker` 存在；沒有 `*.tmp` |
| `same input skips` | 再執行一次 | 沒呼叫 pip |
| `index change reinstalls` | 改 `PIP_INDEX_URL` | 呼叫 pip；`current` 換了；舊目錄已刪 |
| `image upgrade reinstalls` | 改 `IMAGE_VERSION_FILE` 的內容 | 呼叫 pip（Review Focus 5） |
| `failure keeps current` | `FAKE_PIP_FAIL=1`，換一份 requirements | exit 0；`current` 不變；`FAILED` 含假 pip 的錯誤訊息；沒有 `*.tmp` |
| `success clears FAILED` | 接著讓安裝成功 | `FAILED` 不見了 |
| `leftover tmp cleaned` | 先放一個 `abc.tmp` 目錄 | 安裝後 `abc.tmp` 不見了 |
| `hashes enable require-hashes` | 內容含 `--hash=sha256:...` | `$CALLS` 含 `--require-hashes` |
| `constraints passed` | 任一次安裝 | `$CALLS` 含 `-c $BASE_CONSTRAINTS` |
| `CRLF stripped` | CRLF 的 requirements | 傳給 pip 的檔案不含 `\r` |

- [ ] **Step 2: 執行測試**，預期 FAIL
- [ ] **Step 3: 實作 `install-extra.sh`**（`ln -sfn` 到暫存名稱再 `mv -T`，達成原子切換；所有輸出用 `tee -a "$LOG_OUT"`）
- [ ] **Step 4: 執行測試**，預期 PASS
- [ ] **Step 5: Commit** `feat: install extra packages atomically from a ConfigMap`

---

### Task 5: 桌面設定產生器

**Files:**
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/desktop-settings.sh`
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/lab-overrides.sh`
- Test: `test/unit/desktop-settings.test.sh`、`test/unit/lab-overrides.test.sh`

**Interfaces:**
- Consumes: Task 2 的變數（從環境讀）
- Produces:
  - `desktop-settings.sh <home>`：在 stdout 印出 spec §5 表格裡的 `settings.json`。`serverArgs` = `--MappingKernelManager.cull_idle_timeout=$KERNEL_CULL_IDLE_TIMEOUT --MappingKernelManager.cull_interval=300 --ResourceUseDisplay.mem_limit=<KERNEL_MEMORY_LIMIT_KB*1024>`。用 `python3 -c 'import json…'` 輸出，確保跳脫正確
  - `lab-overrides.sh`：印出 `{"@jupyterlab/translation-extension:plugin": {"locale": "<JUPYTER_LOCALE>"}}`

- [ ] **Step 1: 寫失敗的測試**：用 `python3 -c` 解析輸出並逐欄位斷言：`pythonPath == "/opt/jupyter/venv/bin/python"`、`startupMode == "new-local-session"`、四個更新／新聞欄位都是 `false`、`defaultWorkingDirectory` 等於傳入的 home（測試用含空格和引號的路徑 `/tmp/a b"c`）、`serverArgs` 含 `cull_idle_timeout=3600` 和 `mem_limit=2147483648`；`JUPYTER_LOCALE=en` 時 overrides 的 locale 是 `en`
- [ ] **Step 2: 執行測試**，預期 FAIL
- [ ] **Step 3: 實作兩支腳本**
- [ ] **Step 4: 執行測試**，預期 PASS
- [ ] **Step 5: Commit** `feat: generate JupyterLab Desktop settings and lab overrides`

---

### Task 6: token patch

**Files:**
- Create: `images/rdp-jupyter/patches/token-env.sh`
- Test: `test/unit/token-env.test.sh`（含 fixture `test/unit/fixtures/asar/build/out/main/{server.js,config/settings.js}`）

**Interfaces:**
- Produces: `token-env.sh <extracted-asar-dir>`，修改兩個檔案，任何一處的原文不是剛好出現一次就 exit 1（訊息 `[token-env] expected exactly one match for <pattern> in <file>`）：
  1. `build/out/main/config/settings.js`：刪掉 `` `--ServerApp.token="{token}"`, ``（含後面的逗號和換行）
  2. `build/out/main/server.js`：把 `JUPYTERLAB_WORKSPACES_DIR: process.env.JLAB_DESKTOP_WORKSPACES_DIR || jlabWorkspacesDir,` 改成同一行後面再接 `JUPYTER_TOKEN: this._info.token,`

- [ ] **Step 1: 從 v4.6.3-1 的 `app.asar`（`npx @electron/asar extract`）擷取這兩段的原文，做成最小的 fixture**
- [ ] **Step 2: 寫測試**：(a) patch 後 settings.js 不含 `ServerApp.token`、server.js 剛好含一次 `JUPYTER_TOKEN: this._info.token`；(b) 對已經 patch 過的目錄再執行一次 → exit 1；(c) 原文出現兩次的 fixture → exit 1，而且檔案沒有被修改
- [ ] **Step 3: 執行測試**，預期 FAIL
- [ ] **Step 4: 實作**（用 `grep -c` 計數後再 `sed`；先複製到暫存檔，全部成功才覆蓋）
- [ ] **Step 5: 執行測試**，預期 PASS
- [ ] **Step 6: Commit** `feat: pass the Jupyter token through the environment`

---

### Task 7: 失敗通知與 `startwm.sh`

**Files:**
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/notify-extra.sh`
- Create: `images/rdp-jupyter/rootfs/etc/xrdp/startwm.sh`（以 rdp-vscode 的為基礎改寫）
- Create: `images/rdp-jupyter/rootfs/etc/skel/.config/openbox/rc.xml`（移植）
- Test: `test/unit/notify-extra.test.sh`；`test/unit/startwm.test.sh`（移植，Task 9 之後才能執行）

**Interfaces:**
- Consumes: Task 2 的 `session.env`、Task 5 的 `desktop-settings.sh`
- Produces:
  - `notify-extra.sh`：`$EXTRA_DIR/FAILED` 存在時，以 `${XMESSAGE:-xmessage} -center` 顯示「額外套件安裝失敗」加上檔案內容；不存在就什麼都不做
  - `startwm.sh`：沿用 rdp-vscode 的 session 目錄規則（`/tmp/sess/<display>.<uid>`、拒絕不屬於自己的目錄）、dbus、trap 清理（TERM → 等 10 秒 → KILL）。改動的部分：`XDG_CONFIG_HOME=$S/xdg`；`JLAB_DESKTOP_CONFIG_DIR=$HOME/.jupyter`；寫入 `$S/xdg/jupyterlab-desktop/settings.json`；背景執行 `notify-extra.sh`；直接執行 `/opt/JupyterLab/jupyterlab-desktop --no-sandbox`（背景執行再 `wait`；`--no-sandbox` 的理由見 spec 第 6 節）

- [ ] **Step 1: 寫 `notify-extra.test.sh`**：用假的 `XMESSAGE`（寫入參數到檔案），斷言 `FAILED` 存在時有呼叫、參數含檔案內容；不存在時沒呼叫
- [ ] **Step 2: 執行**，預期 FAIL；**Step 3: 實作**；**Step 4: 執行**，預期 PASS
- [ ] **Step 5: 寫 `startwm.sh` 和移植 `rc.xml`**；把 rdp-vscode 的 `startwm.test.sh` 改成檢查「`/home/bob/.jupyter` 不存在」
- [ ] **Step 6: `shellcheck`** 兩支腳本，沒有警告
- [ ] **Step 7: Commit** `feat: kiosk session for JupyterLab Desktop`

---

### Task 8: `entrypoint.sh`

**Files:**
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/entrypoint.sh`（以 rdp-vscode 的為基礎）
- Create: `images/rdp-jupyter/rootfs/opt/rdp-jupyter/sesman-config.sh`
- Test: `test/unit/sesman-config.test.sh`

**Interfaces:**
- Consumes: Task 1、2、5
- Produces:
  - `sesman-config.sh <sesman.ini> <max_sessions> <disconnected_timeout>`：就地把 `Policy` 改成 `Default`、`KillDisconnected=true`、`DisconnectedTimeLimit`、`MaxSessions` 改成指定值；某個鍵不存在時 exit 1
  - `entrypoint.sh`：跟 rdp-vscode 相同（驗證 `MAX_SESSIONS`、帳號、TLS、清掉殘留、啟動 sesman 和 xrdp、任一個結束就讓容器結束），拿掉 SSH 和字型設定，改成：寫出 `/run/rdp-jupyter/session.env`、呼叫 `sesman-config.sh`、用 `lab-overrides.sh` 產生 `/opt/jupyter/venv/share/jupyter/lab/settings/overrides.json`

- [ ] **Step 1: 寫測試**：用 Debian 原版 `sesman.ini` 的片段當 fixture（`Policy=Separate`、`KillDisconnected=false`、`DisconnectedTimeLimit=0`、`MaxSessions=50`），斷言改完後四個值正確，其他行不變；缺少 `Policy=` 的 fixture → exit 1
- [ ] **Step 2: 執行**，預期 FAIL；**Step 3: 實作兩支腳本**；**Step 4: 執行**，預期 PASS
- [ ] **Step 5: Commit** `feat: entrypoint with reconnectable sessions`

---

### Task 9: Dockerfile、Python 環境與 image 測試

**Files:**
- Create: `images/rdp-jupyter/Dockerfile`
- Create: `images/rdp-jupyter/requirements.in`、`images/rdp-jupyter/requirements.lock`
- Create: `test/image/smoke.test.sh`、`test/image/notebook.test.sh`、`test/image/fixtures/smoke.ipynb`
- Create: `test/build.sh`（`podman build -t localhost/rdp-jupyter:dev images/rdp-jupyter`）

**Interfaces:**
- Consumes: Task 1～8 的全部腳本、Task 6 的 patch
- Produces: 映像檔 `localhost/rdp-jupyter:dev`，內含 spec §9 的內容，以及：
  - `/opt/jupyter/constraints.txt`（等於 `requirements.lock` 去掉 hash 後的 `name==version`）
  - `/opt/rdp-jupyter/VERSION`（複製 repo 的 `VERSION`）
  - venv 的 `bin/activate` 最後一行是 `. /opt/rdp-jupyter/server-env.sh`
  - `site-packages/rdp-jupyter-extra.pth` 的內容是 `/opt/jupyter/extra/current`
  - 映像檔內有 `uv`，給 `install-extra.sh` 用

- [ ] **Step 1: 寫 `requirements.in`**：`jupyterlab==4.6.*`、`ipykernel`、`pandas`、`matplotlib`、`jupyterlab-language-pack-zh-TW`、`jupyter-resource-usage`；用 `uv pip compile --generate-hashes --python-version 3.13` 產生 `requirements.lock`
- [ ] **Step 2: 寫 `smoke.test.sh`**，斷言：
  - `podman image inspect --format '{{.Size}}'` ≤ `1200000000`
  - `/opt/JupyterLab/resources/env_installer` 不存在；`locales/` 只有 `en-US.pak` 和 `zh-TW.pak`
  - `app.asar` 解開後不含 `ServerApp.token="{token}"`
  - 以 UID 65534 執行 `/opt/jupyter/venv/bin/python -c 'import jupyterlab, pandas, matplotlib'` 成功，`jupyterlab.__version__` 以 `4.6.` 開頭
  - 以 UID 65534 寫入 `/opt/jupyter/venv` 失敗
  - `.pth` 和 `activate` 的最後一行符合上面的 Interfaces
  - `jupyterlab-desktop --version`（`HOME=/tmp`）輸出含 `4.6.3`
- [ ] **Step 3: 寫 `smoke.ipynb` 和 `notebook.test.sh`**：notebook 有三格：(1) pandas 建 DataFrame、matplotlib 存 PNG；(2) `np.ones(400_000_000)`，預期 `MemoryError`；(3) `print("alive")`。測試在容器裡用 `KERNEL_MEMORY_LIMIT=1Gi` 跑 entrypoint 產生的 `session.env`，`source activate` 後用 `nbclient`（`allow_errors=True`）執行，斷言第 2 格的 ename 是 `MemoryError`、第 3 格輸出 `alive`
- [ ] **Step 4: 執行兩支測試**，預期 FAIL（沒有映像檔）
- [ ] **Step 5: 寫 Dockerfile**（spec §9 的兩個 stage；`ARG JLD_VERSION=4.6.3-1`、`ARG JLD_SHA256=<實際下載後計算的值>`；builder 用 `node` 執行 `npx @electron/asar` 解開、執行 `patches/token-env.sh`、再打包；venv 用 `uv venv --system-site-packages` 加 `uv pip sync --require-hashes requirements.lock`；刪掉 `tests`／`test` 目錄後 `compileall`）
- [ ] **Step 6: `bash test/build.sh && bash test/image/smoke.test.sh && bash test/image/notebook.test.sh`**，預期全部 PASS。超過 1.2 GB 時，用 `dive` 找出最大的層，依 spec §9 處理，並記在 `docs/spike-notes.md`
- [ ] **Step 7: 執行 `bash test/unit/startwm.test.sh`**（Task 7 移植的），預期 PASS
- [ ] **Step 8: Commit** `feat: build the rdp-jupyter image`

---

### Task 10: 本機桌面測試

**Files:**
- Create: `test/e2e/client/`（從 rdp-vscode 移植 `Dockerfile` 和 `login.sh`；`login.sh` 加上第 6 個選填參數 `bpp`，傳給 `xfreerdp3 /bpp:<n>`）
- Create: `test/image/session.test.sh`

**Interfaces:**
- Consumes: Task 9 的映像檔
- Produces: 可重跑的 session 測試，截圖和 log 寫到 `test/e2e/out/`

- [ ] **Step 1: 寫 `session.test.sh`**（server 用 `--shm-size=1g -e RDP_PASSWORD=bigred -p 33391:3389`），每一段一個 `say`：

| 段落 | 動作 | 斷言 |
|---|---|---|
| kiosk | client 1 登入 | 40 秒內出現 `python -m jupyterlab` 程序；截圖 |
| token | 同上 | 以 `nobody` 執行 `ps -eo args` 不含 `ServerApp.token`；以 bigred 讀 server 的 `/proc/<pid>/environ` 含 `JUPYTER_TOKEN` |
| limits | 同上 | server 程序的 `/proc/<pid>/limits` 中 `Max data size` 的 soft 和 hard 都是 `2147483648` |
| reconnect | `podman rm -f` client 1，再用 client 2 登入 | Xorg 數量還是 1；jupyterlab server 的 PID 跟斷線前相同 |
| other-bpp | client 3 用 `bpp=16` 登入（Review Focus 3） | Xorg 數量變 2；兩個 server 都在；client 3 截圖有 JupyterLab 畫面 |
| locale-kept | 在 `~/.jupyter/lab/user-settings/@jupyterlab/translation-extension/plugin.jupyterlab-settings` 寫入 `{"locale":"en"}`，關掉所有桌面再登入（Review Focus 4） | 檔案內容沒變；`overrides.json` 的 locale 還是 `zh_TW` |
| failed-notice | 建立 `/opt/jupyter/extra/FAILED` 後登入 | 30 秒內出現 `xmessage` 程序 |
| close | 在 client 的視窗按右上角的關閉按鈕（`xdotool`） | 10 秒內該 display 的 Xorg 消失；`/tmp/sess/<display>.1000` 被刪掉 |
| timeout | 用 `-e DISCONNECTED_TIMEOUT=20` 重新啟動 server，登入後斷線 | 40 秒內 Xorg 和 jupyterlab server 都消失 |

- [ ] **Step 2: 執行**，預期全部 PASS；失敗時用 superpowers:systematic-debugging 找原因，不要放寬斷言
- [ ] **Step 3: Commit** `test: local RDP session tests`

---

### Task 11: 帳號隔離攻擊測試

**Files:**
- Create: `test/image/isolation.test.sh`、`test/image/fixtures/attack.py`

**Interfaces:**
- Consumes: Task 9 的映像檔、Task 10 的 client
- Produces: spec §6 威脅模型每一列的 PASS/FAIL

- [ ] **Step 1: 寫測試**：用 `-e USERS_FILE` 掛載 `alice:a\nbob:b` 的帳號檔，bob 用 client 登入。在 bob 的桌面啟動 kernel 之前，先以 alice 身分在背景執行輪詢程式，每 1 ms 讀一次所有 `/proc/*/cmdline`，持續 60 秒。之後以 alice 身分執行 `attack.py`，每一項一個斷言：
  - 輪詢程式從沒看過 `token=` 字串
  - 讀 bob 的 server 的 `/proc/<pid>/environ` → `PermissionError`
  - 不帶 token 對 bob 的 server 發出 `GET /api/kernels` → 403
  - 讀 bob 的 connection file（`/home/bob/.local/share/jupyter/runtime/kernel-*.json`）→ 失敗
  - 不帶 HMAC 簽章，對 bob 的 kernel shell 埠（從 `ss -ltnp` 找出 bob 的 kernel 埠）送 `execute_request`，要求建立 `/tmp/pwned` → 5 秒後檔案不存在
  - `ls /home/bob`、`ls /tmp/sess/*.1001` → 失敗
  - 寫入 `/opt/jupyter/venv/lib` 和 `/opt/jupyter/extra` → 失敗
  - `python -c 'import ctypes; …ptrace(PTRACE_ATTACH, <bob 的 pid>)'` → 回傳 -1
- [ ] **Step 2: 執行**，預期全部 PASS。任何一項 FAIL 都要停下來回報使用者，這代表 spec §6 的對策有缺口
- [ ] **Step 3: Commit** `test: cross-account isolation attacks`

---

### Task 12: Kubernetes manifests 與 `install.sh`

**Files:**
- Create: `manifests/base/{kustomization,namespace,deployment,service}.yaml`
- Create: `manifests/stateless/{kustomization.yaml,users.txt,volumes-emptydir.yaml}`
- Create: `manifests/stateful/{kustomization.yaml,users.txt,pvc.yaml,volumes-pvc.yaml}`
- Create: `manifests/example/requirements/{kustomization.yaml,requirements.txt,requirements-hashed.txt}`
- Create: `install.sh`（移植）
- Test: `test/deploy/render.test.sh`、`test/deploy/lint.test.sh`、`test/unit/install.test.sh`（移植）

**Interfaces:**
- Consumes: 映像檔 `ghcr.io/braveantony/rdp-jupyter:0.1`
- Produces: `kubectl apply -k manifests/stateless`（或 `stateful`）就能部署。Deployment 規格：`Recreate`；`allowPrivilegeEscalation: false`；spec §10 的環境變數全部列出並附繁中註解（照 rdp-vscode 的寫法）；requests／limits 照 Global Constraints；readiness 和 liveness 用 TCP 3389；volume：`users`（Secret，0400）、`requirements`（ConfigMap `rdp-jupyter-requirements`，`optional: true`）、`dshm`（記憶體 emptyDir 1Gi）、`home`、`extra`；`lifecycle.postStart.exec.command: ["/opt/rdp-jupyter/install-extra.sh"]`。stateful 的 PVC：`rdp-jupyter-home` 10Gi、`rdp-jupyter-extra` 5Gi，不指定 StorageClass

- [ ] **Step 1: 寫 `render.test.sh`**：對 `stateless`、`stateful`、`example/requirements` 執行 `kubectl kustomize`，斷言：NodePort 是 `30391`；namespace 全部是 `rdp-jupyter`；有 postStart；`/home` 和 `/opt/jupyter/extra` 在 stateless 是 emptyDir、在 stateful 是 PVC；limits.memory 是 `8Gi`；example 會產生帶 hash 後綴的 `rdp-jupyter-requirements-*` ConfigMap，而且 Deployment 引用的就是它
- [ ] **Step 2: 寫 `lint.test.sh`**：每個 overlay 都要通過 `kubeconform -strict -kubernetes-version 1.37.1` 和 `kube-linter lint`（必要的例外寫在 `.kube-linter.yaml`，逐條附原因）；再用 `kubectl apply --dry-run=server` 到一個標記 `pod-security.kubernetes.io/enforce=baseline` 的暫時 namespace，不能出現警告或拒絕
- [ ] **Step 3: 移植 `install.sh` 和 `install.test.sh`**：namespace、NodePort、名稱改成 rdp-jupyter；拿掉 SSH 相關的提示
- [ ] **Step 4: 執行三支測試**，預期 FAIL；**Step 5: 寫 manifests**；**Step 6: 執行**，預期 PASS
- [ ] **Step 7: Commit** `feat: kustomize manifests and quick installer`

---

### Task 13: tk8s 端到端驗收

**Files:**
- Create: `test/e2e/run.sh`（以 rdp-vscode 的為基礎，用 skopeo 把映像檔載入節點）
- Create: `test/e2e/fixtures/postgres.yaml`（namespace `rdp-jupyter-e2e-data`，一個 PostgreSQL 16 加 Service `pg`）
- Create: `test/e2e/manual-checklist.md`
- Create: `docs/ops/<執行日期 YYYY-MM-DD>-tk8s-e2e.md`（實際執行的紀錄）

**Interfaces:**
- Consumes: Task 9 的映像檔、Task 12 的 manifests
- Produces: spec A7 的證據

- [ ] **Step 1: 寫 `run.sh`**，每個情境一個函式，log 和截圖寫到 `test/e2e/out/`：

| 情境 | 斷言 |
|---|---|
| `stateless` | 3 個帳號同時登入都有畫面；在 notebook 用 `pandas.read_sql` 查 `pg.rdp-jupyter-e2e-data` 回傳資料列 |
| `stateful` | 寫一個 notebook，刪掉 Pod，重建後檔案還在；`requirements.txt` 沒變時，postStart 的 log 顯示跳過 |
| `requirements` | 套用 `example/requirements` 後，notebook 能 `import` 裡面的套件 |
| `pip-unreachable` | 用 NetworkPolicy 擋掉對外連線：Pod 會 Ready；登入後出現 `xmessage`；`kubectl logs` 看得到 pip 的錯誤 |
| `oom` | `KERNEL_MEMORY_LIMIT=6Gi`、limits `4Gi`，在 notebook 配置 5 GB：記錄 Pod 是整個被殺（`memory.oom.group`）還是只殺 kernel，寫進 ops 紀錄，並跟 spec F11 對照 |
| `kernel-limit` | 預設值下配置 3 GB → `MemoryError`，Pod 沒有重啟 |

- [ ] **Step 2: 執行 `bash test/e2e/run.sh`**，全部情境 PASS（`oom` 只記錄結果）；跑完刪掉測試用的 namespace
- [ ] **Step 3: 把 `oom` 的結果和任何跟 spec 不一致的地方寫進 `docs/ops/`，必要時更新 spec F11**
- [ ] **Step 4: 寫 `manual-checklist.md`**：給分析師用的 A11 清單（從零部署、登入、從 MinIO 或 PostgreSQL 讀真實資料、畫圖、存檔、斷線後接回），每一步都有「花費時間／卡住的地方」欄位
- [ ] **Step 5: Commit** `test: tk8s end-to-end acceptance`

---

### Task 14: 供應鏈

**Files:**
- Create: `test/image/supply-chain.test.sh`
- Create: `.trivyignore`（只有必要時才建立，每條附原因）

**Interfaces:**
- Consumes: Task 9 的映像檔
- Produces: `test/e2e/out/sbom.spdx.json`、`test/e2e/out/trivy.txt`

- [ ] **Step 1: 寫測試**：`syft localhost/rdp-jupyter:dev -o spdx-json` 成功，而且 SBOM 含 `jupyterlab`、`pandas`、`xrdp`；`trivy image --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore localhost/rdp-jupyter:dev` 通過
- [ ] **Step 2: 執行**；有漏洞時優先升級套件，升級不了才寫進 `.trivyignore` 並附原因
- [ ] **Step 3: Commit** `test: SBOM and vulnerability scan`

---

### Task 15: 文件

**Files:**
- Create: `README.md`、`README.en.md`、`docs/architecture.md`、`docs/install.md`、`docs/user-guide.md`、`docs/build-image.md`、`docs/data-access.md`
- Create: `docs/design/README.md`（指向 spec，並把 spec 的決策表 D1～D12 整理成 rdp-vscode `docs/design/01-decisions.md` 的格式）

**Interfaces:**
- Consumes: 全部 task 的結果、Task 10 的截圖

- [ ] **Step 1: 照 rdp-vscode README 的章節結構寫 `README.md`**：簡述（含 spec §1「適合／不適合」）、先決條件、快速開始、怎麼用（登入、開 notebook、連叢集服務、斷線後接回）、環境變數表（spec §10）、安全警告（預設帳密、同一個 Pod 共用記憶體）、授權
- [ ] **Step 2: 寫 `docs/data-access.md`**：用 pandas 讀寫 PostgreSQL（SQLAlchemy）、MinIO（s3fs）、Git 的範例；每個範例都附上需要放進 `requirements.txt` 的套件；寫明不能從本機直接拖檔案進來（D9）和原因
- [ ] **Step 3: 寫 `docs/build-image.md`**：建置、測試、升級流程（每月檢查 JupyterLab Desktop、重跑 token patch、逐條確認 spec F1～F12、跑全部測試）、patch 的說明
- [ ] **Step 4: 寫其他文件**；`docs/architecture.md` 附上連線流程和威脅模型
- [ ] **Step 5: 用 docs-review skill 審閱全部文件，依結果修改**
- [ ] **Step 6: Commit** `docs: README, guides and architecture`

---

### Task 16: 獨立審查與交付

- [ ] **Step 1: 用 codex:rescue 請 Codex 審查**：只提供 spec 路徑和 `git diff` 的範圍，不提供我們的結論，請它找出 bug、安全問題和跟 spec 不一致的地方
- [ ] **Step 2: 用 superpowers:receiving-code-review 處理意見**；修改的部分重跑相關測試
- [ ] **Step 3: 重跑全部測試**：`for t in test/unit/*.test.sh test/image/*.test.sh test/deploy/*.test.sh; do bash "$t" || echo "FAILED: $t"; done`，預期沒有任何 `FAILED`
- [ ] **Step 4: 把 `test/e2e/manual-checklist.md` 交給使用者，請他安排分析師執行（A11）**；依回饋修改文件
- [ ] **Step 5: 用 superpowers:finishing-a-development-branch 決定怎麼整合**（push 和建立 GitHub repo 都要使用者同意）
