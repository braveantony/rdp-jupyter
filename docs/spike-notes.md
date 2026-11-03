# Task 0 Spike 紀錄

日期：2026-11-03。對應 spec §8「Task 0 要驗證的項目」。

環境：

- tk8s：Kubernetes v1.37.1、CRI-O 1.37.2（`sudo podman exec tk8s-worker-1 crio --version`），三個節點。暫時 namespace `rdp-jupyter-spike`，做完已刪除
- 本機：rootless podman、`debian:trixie-slim`（Python 3.13.5、uv 0.13.7、pip 25.1.1）
- 映像檔：`localhost/rdp-jupyter-spike:b`（JupyterLab Desktop 4.6.3 疊在 rdp-vscode 映像檔上）

**結論摘要**

| # | 項目 | 結果 |
|---|---|---|
| 1 | postStart vs. initContainer | spec 假設成立。postStart 加 `exit 0` 可用，但沒有 initContainer 好除錯 |
| 2 | `--target` 加 constraints | 會重複安裝基本 venv 已有的套件（uv 浪費 75 MB、pip 浪費 123 MB）；有不重複的做法 |
| 3 | `--system-site-packages` 加 `--user` | 可用；但 `--user` 不能蓋掉基本 venv 已有的套件 |
| 4 | Electron sandbox | **推翻 spec 假設**：RuntimeDefault seccomp 下沒有可用的 sandbox，JupyterLab Desktop 一啟動就結束 |
| 5 | 剪貼簿傳檔需要 FUSE | spec 假設成立，而且還要 `CAP_SYS_ADMIN` |

---

## 1. postStart vs. initContainer 故障注入

**問題**：spec F10 說 postStart 失敗會殺掉容器、hook 完成前容器不會 Running、失敗只留下 `FailedPostStartHook` 事件。實際在 tk8s 上，跟 initContainer 比起來差在哪裡？有沒有 postStart 無法補救的缺點？

**做法**：

- namespace `rdp-jupyter-spike`，映像檔 `python:3.13-slim`（pip 26.2.2），主容器執行 `sleep infinity`
- 每種情況建四個 Deployment：`ps-strict`（postStart，pip 失敗就回傳非 0）、`ps-ok`（postStart，輸出導到 `/proc/1/fd/1`，失敗一律 `exit 0`）、`ic-strict`、`ic-ok`（同樣兩種腳本，但放在 initContainer）
- 指令（腳本由 ConfigMap 掛載，requirements 也是 ConfigMap）：`pip install --retries 1 --timeout 5 -r /req/requirements.txt --target /extra`
- (a) 用 NetworkPolicy 對 `blocked=true` 的 Pod 只放行 DNS（UDP/TCP 53）、其餘 egress 全擋，requirements 是 `requests==2.32.3`
- (b) requirements 是不存在的 `requestss-no-such-pkg-xyz==1.0`
- (c) requirements 是 `pandas`、`scipy`，apply 後約 12 秒執行 `kubectl delete pod`
- (d) 對已經有 `/extra` 的 Pod 用 `kubectl exec` 再跑一次腳本，並對空的 `/extra` 同時跑兩份
- 每個 Pod 看 `kubectl get pod`、`kubectl describe` 的 Events、`kubectl logs`（initContainer 用 `-c install`）、restartCount

**結果**：

(b) 套件名稱錯誤（約 60 秒後）：

| 變體 | 狀態 | 事件與 log |
|---|---|---|
| ps-strict | `PostStartHookError`，約 95 秒時變 `CrashLoopBackOff`、`RESTARTS 1`、`READY 0/1`；`lastState.terminated.exitCode=137` | Events：`FailedPostStartHook`（訊息只有 `PostStartHook failed`）、`Killing ... FailedPostStartHook`、`BackOff`。`kubectl logs` 完全沒有輸出，pip 的錯誤在哪裡都看不到 |
| ps-ok | `Running 1/1`，restart 0 | Events 只有一般的 Created、Started。`kubectl logs` 看得到 `ERROR: No matching distribution found ...` 和 `[hook] FAILED rc=1`（靠導到 `/proc/1/fd/1`） |
| ic-strict | `Init:Error`，約 60 秒時 init `restarts=3`，主容器沒啟動（`kubectl logs` 回 `PodInitializing`） | Events：`BackOff ... restarting failed container install`。`kubectl logs -c install` 看得到 pip 錯誤 |
| ic-ok | `Running 1/1`，restart 0，約 3 秒進入 Running | `kubectl logs -c install` 看得到錯誤與 `[hook] FAILED rc=1` |

(a) 擋掉對外連線：

- pip 報 `Failed to establish a new connection: [Errno 101] Network is unreachable`（pypi.org）。即使設了 `--retries 1 --timeout 5`，仍花約 60 秒才放棄
- 這段時間 postStart 的 Pod 是 `0/1 ContainerCreating`（Events 已經有 `Created`、`Started`，但 status 還不是 Running）；initContainer 的 Pod 是 `0/1 Init:0/1`。t=60 秒時四個都還沒 Ready
- `ps-ok`、`ic-ok`：t=80 秒時 `Running 1/1`，log 看得到失敗訊息
- `ps-strict`：t=100 秒 `PostStartHookError`，3 分 10 秒時 `CrashLoopBackOff`、`restarts=1`，`kubectl logs` 空白
- `ic-strict`：t=120 秒 `Init:Error`，3 分 10 秒時 init `restarts=2`，Pod 一直不 Ready

(c) 安裝中途刪除 Pod（emptyDir）：

- 四個變體的新 Pod 都在約 40 秒內 `Running 1/1`、restart 0，`/extra` 都是 291 MB、13 個項目，含 `numpy`、`pandas`、`scipy`。沒有留下半成品（emptyDir 本來就跟著 Pod 消失）
- 舊 Pod 的消失時間：有 postStart 的舊 Pod 在 t=32 秒時仍是 `Terminating`，t=40 秒才消失；initContainer 的舊 Pod 在 t=24～32 秒前就消失了。原因沒有進一步確認（主容器 `sleep infinity` 當 PID 1 不處理 SIGTERM，可能要等 30 秒寬限時間）
- **沒有測 PVC**：stateful 模式中途被刪時，半成品會留在 PVC 上。這點仍由設計裡的 `<hash>.tmp` 加改名、symlink 原子切換負責，Task 0 沒有驗證

(d) 腳本執行兩次：

- 先後執行（`/extra` 已有內容）：`rc=0`，7 秒；已存在的目錄各印一行 `WARNING: Target directory /extra/numpy.libs already exists. Specify --upgrade to force replacement.`，大小沒有改變（291 MB），`import pandas` 正常
- 同時執行兩份（空的 `/extra`）：一份正常結束（`[hook] done`），另一份的 pip 噴 `ERROR: Exception:`，內有 `OSError: [Errno 18] Invalid cross-device link: '/tmp/pip-target-.../dateutil' -> '/extra/dateutil'`，接著 `FileExistsError: ... '/extra/dateutil'`。最後 `/extra` 仍是 291 MB，`PYTHONPATH=/extra python -c "import pandas,numpy,scipy"` 成功，但那份失敗的腳本在 strict 模式會回傳非 0
- 順帶看到：`pip --target` 先把檔案裝在 `/tmp/pip-target-*`，再搬到目標目錄，兩者在不同檔案系統（emptyDir vs. 容器的 `/tmp`）時會出現 cross-device 錯誤訊息

**對設計的影響**：

- F10 的行為都得到證實：postStart 失敗（回傳非 0）會殺掉容器、進入 `CrashLoopBackOff`，事件只有 `PostStartHook failed`，`kubectl logs` 沒有輸出；hook 執行期間 Pod 不是 Running、不是 Ready
- 沒有發現 postStart 無法補救的缺點，不需要回頭找使用者討論。spec 的做法（一律 `exit 0`、輸出導到 `/proc/1/fd/1`、`FAILED` 標記檔）可行：`ps-ok` 在套件名錯誤和網路被擋兩種情況下都進入 Running，log 看得到
- 必須維持「一律 `exit 0`」：`ps-strict` 實測在兩種故障下都進入 CrashLoopBackOff，使用者連不進來
- 腳本必須處理「同時執行兩份」：用 flock 或在 `<hash>.tmp` 上做互斥；pip 暫存目錄（`TMPDIR`）要跟目標目錄在同一個檔案系統，避免 cross-device 錯誤
- 網路不通時 pip 要約 60 秒才放棄，這段時間 Pod 不 Ready。`install-extra.sh` 應設合理的 `--timeout`／整體 `timeout`，並在驗收測試把這段時間列入
- initContainer 比較好除錯（`kubectl logs -c install` 直接有輸出、事件明確、不用 `/proc/1/fd/1`），但同樣讓 Pod 在安裝期間不 Ready，所以兩者在「使用者等待時間」上沒有差別；spec 維持 postStart 不需更動

---

## 2. `--target` 加 constraints 會不會重複安裝

**問題**：用基本 venv 的鎖定檔當 constraints 安裝到 `--target`，pip／uv 會不會把基本 venv 已有的 pandas、numpy 再裝一份？

**做法**：`debian:trixie-slim` 加 `python3`、`python3-venv`、`ca-certificates`；`python3 -m venv --system-site-packages /opt/venv`；用 uv（裝在另一個 venv `/opt/uvtool`）把 pandas 裝進 `/opt/venv`；`uv pip freeze --python /opt/venv/bin/python > /tmp/base.txt`（內容：numpy==2.5.4、pandas==3.1.0、pip==25.1.1、python-dateutil==4.0.0、tzdata==2026.6）。基本 venv 的 `site-packages` 是 117 MB。

每次先 `rm -rf /tmp/extra`，裝完用 `du -sm` 量大小，並檢查 `/tmp/extra/pandas`、`/tmp/extra/numpy` 是否存在。

**結果**：

| 指令 | `/tmp/extra` | pandas | numpy |
|---|---|---|---|
| A. `uv pip install --target /tmp/extra -c /tmp/base.txt requests pandas`（沒有 `--python`） | 108 MB | 有（45 MB） | 有（30 MB） |
| B. 同 A，加 `--python /opt/venv/bin/python` | 108 MB | 有 | 有 |
| C. `/opt/venv/bin/pip install --target /tmp/extra -c /tmp/base.txt requests pandas` | 157 MB | 有（80 MB） | 有（43 MB） |
| D. 對照：B 拿掉 `-c` | 108 MB | 有 | 有 |
| E. B 的指令，只裝 `requests` | 3 MB | 無 | 無 |
| G1. B 的指令，裝 `seaborn`（相依 pandas、numpy、matplotlib） | 182 MB | 有（45 MB） | 有（30 MB） |
| G2. C 的指令，裝 `seaborn` | 251 MB | 有（80 MB） | 有（43 MB） |
| H. `uv pip compile` 解出完整清單，濾掉基本 venv 已有的套件名稱，剩下用 `--target --no-deps` 安裝（seaborn） | 78 MB | 無 | 無 |

H 的做法（指令）：

```sh
uv pip compile /tmp/req.in -c /tmp/base.txt --python /opt/venv/bin/python -q --no-header --no-annotate -o /tmp/resolved.txt
# 濾掉 resolved.txt 裡名稱已在 base.txt 的套件 -> /tmp/delta.txt（delta 有 9 個套件，不含 pandas、numpy、dateutil、tzdata）
uv pip install --target /tmp/extra --no-deps --python /opt/venv/bin/python -r /tmp/delta.txt
```

H 之後把 `/tmp/extra` 用 `.pth` 放進 `/opt/venv` 的 `sys.path`，`import seaborn, pandas, numpy, matplotlib` 成功，`pandas.__file__` 和 `numpy.__file__` 都指向 `/opt/venv/lib/python3.13/site-packages/...`。

**對設計的影響**：

- `--target` 不看已經安裝的套件，不管是 uv 或 pip、有沒有 `--python`、有沒有 `-c`，只要「管理者列的套件，或它的相依套件」包含基本 venv 已有的套件，就會再裝一份。constraints 只固定版本，不會讓它略過
- 浪費量：uv 在 pandas 加 numpy 的情況下 75 MB（G1：182 MB 裡的 45+30）；pip 123 MB（G2）。不依賴基本套件的（E）沒有浪費
- 重複的那份是死重量：`.pth` 把 extra 放在基本 venv `site-packages` 之後（見第 3 節的 `sys.path`），所以 import 時會用基本 venv 的版本；constraints 確保版本一樣
- **PIP_CMD 建議**：`uv pip install --python /opt/venv/bin/python --target "$tmpdir" -c <基本 venv 的 freeze> -r requirements.txt`。uv 比 pip 小（182 vs. 251 MB），`--python` 在這個情況下對結果沒有影響但能讓 uv 明確指向基本 venv，可以保留。如果要連 75 MB 都省，改用 H 的「compile、濾掉、`--no-deps`」；它多一步，也多一個「濾掉的名稱比對」要維護，建議第一版接受重複、在 docs 註明
- uv 要出現在最終映像檔（spec §9 目前只有 builder 階段有 uv）；不想帶 uv 就用 pip（C），浪費的 MB 較多
- 沒有驗證 `--require-hashes`（requirements 帶 `--hash=` 的情況）在這兩種指令下的行為；Task 3 寫腳本時要補測
- 測試用的 venv 路徑是 `/opt/venv`，不是 spec 寫的 `/opt/jupyter/venv`，不影響結論

---

## 3. `--system-site-packages` 加 `--user`

**問題**：`--system-site-packages` 的 venv 裡，一般使用者 `pip install --user` 能不能成功？`sys.path` 的順序？

**做法**：`debian:trixie-slim`，`python3 -m venv --system-site-packages /opt/venv`，pandas 裝在 venv；在 `site-packages` 放 `rdp-jupyter-extra.pth`，內容 `/opt/extra/current`（目錄已建立）。建 `useradd -m -u 1000 bigred`，以 `su bigred` 執行：

```sh
/opt/venv/bin/pip install --user requests
/opt/venv/bin/python -c "import sys,site; print(sys.path); print('ENABLE_USER_SITE',site.ENABLE_USER_SITE,site.getusersitepackages())"
/opt/venv/bin/pip install --user 'pandas==2.3.3'
```

**結果**（bigred）：

- `pip install --user requests`：`Successfully installed certifi-2026.10.23 charset_normalizer-3.5.2 idna-3.20 requests-2.34.2 urllib3-2.8.0`，rc=0，只多一行 `WARNING: The script normalizer is installed in '/home/bigred/.local/bin' which is not on PATH.`
- `sys.path`：

  ```
  ['', '/usr/lib/python313.zip', '/usr/lib/python3.13', '/usr/lib/python3.13/lib-dynload',
   '/opt/venv/lib/python3.13/site-packages', '/opt/extra/current',
   '/home/bigred/.local/lib/python3.13/site-packages',
   '/usr/local/lib/python3.13/dist-packages', '/usr/lib/python3/dist-packages']
  ```

  `ENABLE_USER_SITE True /home/bigred/.local/lib/python3.13/site-packages`；`requests.__file__` 在 `/home/bigred/.local/...`
- `pip install --user 'pandas==2.3.3'`：失敗，`ERROR: Will not install to the user site because it will lack sys.path precedence to pandas in /opt/venv/lib/python3.13/site-packages`；`import pandas` 仍是 3.1.0（venv 的）
- root 執行的結果相同（`/root/.local/...`）

**對設計的影響**：

- 預期成立：`--user` 可以裝，`~/.local/lib/python3.13/site-packages` 在 `sys.path` 裡
- 順序是「基本 venv `site-packages` → 管理者的 extra（`.pth`）→ 使用者的 `~/.local`」，user site 排在最後。後果：使用者不能用 `--user` 升級或降級基本 venv 已有的套件（pip 直接拒絕）；管理者 extra 的套件也優先於使用者自己裝的。需要換版本的使用者要用 `venv` 或自己的路徑，文件要寫清楚
- 測的是在 shell 裡用 venv 的 pip；Notebook 裡的 `%pip install --user` 沒有另外測
- 使用者的 `~/.local/bin` 不在 PATH，要不要加進 PATH 留給 Task 3 決定

---

## 4. Electron sandbox 在 tk8s 上能不能用

**問題**：JupyterLab Desktop（Electron）在 tk8s（CRI-O、RuntimeDefault seccomp、`allowPrivilegeEscalation: false`）能不能不加 `--no-sandbox` 執行？

**做法**：

- 照 `~/rdp-vscode/test/e2e/run.sh` 的方式，`podman save` 加 `sudo skopeo copy` 把映像檔載入 `tk8s-worker-1`、`tk8s-worker-2` 的 containers-storage
- Deployment（`nodeSelector: tk8s-worker-1`、`imagePullPolicy: Never`）：`securityContext: {allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}}`，`RDP_PASSWORD=bigred`，`/dev/shm` 掛 1Gi memory emptyDir，Service 用 NodePort 30392
- 用 `localhost/rdp-vscode-e2e-client:dev` 連 `172.22.0.2:30392` 登入並截圖
- 對照 B：同樣的 Pod，`seccompProfile: Unconfined`
- 對照 C：RuntimeDefault，但用 ConfigMap 蓋掉 `/etc/xrdp/startwm.sh`，在 `jupyterlab-desktop` 加 `--no-sandbox`

**結果**：

- RuntimeDefault，不加旗標：登入後畫面全黑。`xrdp-sesman.log`：`Window manager (pid 57, display 10) exited quickly (0 secs)`。`/tmp/jlab-1000-10.log`：

  ```
  FATAL:content/browser/zygote_host/zygote_host_impl_linux.cc:128] No usable sandbox! If you are running on Ubuntu 23.10+ ...
  ... If you want to live dangerously and need an immediate workaround, you can try using --no-sandbox.
  ```

- 診斷（在該 Pod 內）：`grep -E "^(Seccomp|NoNewPrivs|CapEff)" /proc/self/status` → `Seccomp: 2`、`NoNewPrivs: 1`、`CapEff: 00000000000005fb`；`su bigred -c "unshare -U --map-root-user id"` 和 root 執行 `unshare -U id` 都是 `unshare: unshare failed: Function not implemented`（seccomp 擋掉了 user namespace）。核心的 `user.max_user_namespaces` 是 81183（Pod 內與本機都一樣），不是核心沒開 user namespace
- 對照 B（`Unconfined`，`Seccomp: 0`）：`su bigred -c "unshare -U id"` 成功（`uid=65534(nobody)`）；登入後出現 JupyterLab 的 Launcher 畫面（截圖 `s4-unconf.png`）。所有行程的命令列都沒有 `--no-sandbox`；renderer 行程的 `Seccomp: 2`，`/proc/<pid>/uid_map` 是 `1000 1000 1`（在自己的 user namespace 裡），gpu-process 和 utility 是 `Seccomp: 0`、`uid_map` 是 `0 0 4294967295`
- 對照 C（RuntimeDefault 加 `--no-sandbox`）：出現 JupyterLab 的 Launcher 畫面（截圖 `s4-nosb.png`），行程命令列有 `--no-sandbox`
- `/opt/JupyterLab` 底下沒有 `chrome-sandbox`（`find /opt/JupyterLab -iname "*sandbox*"` 無輸出），沒有 SUID 的備用 sandbox 可用
- 順帶：Pod 內 `/tmp/jlab-*.log` 還有 `Failed to connect to the bus: /run/dbus/system_bus_socket`、`Failed to adjust OOM score of renderer ...: Permission denied`，不影響畫面

**對設計的影響**：**推翻 spec 的假設**。spec §3 的「透過 xrdp 顯示，不用加 `--no-sandbox`」是本機 podman 的結果，在 tk8s 的 RuntimeDefault 下不成立。三個選項：

1. 在 `startwm.sh` 加 `--no-sandbox`：實測可用，不用改 Pod 規格。代價是 Chromium 的 renderer 沒有 sandbox（Chromium 對 JupyterLab 的隔離變弱，要評估風險並寫進 spec §6）
2. Pod 用 `seccompProfile: Unconfined`：實測可用，sandbox 完整。代價是整個容器（含使用者的 kernel）都沒有 seccomp，而且不符合 Kubernetes Pod Security Standards 的 baseline 等級
3. 自訂的 `Localhost` seccomp profile，只放行 user namespace 相關的 syscall：**沒有測**，需要在每個節點放 profile 檔案，Task 0 規定不能改節點

需要由使用者／controller 決定用哪一個。在決定之前，`startwm.sh`、spec §3 的表格和 §6、驗收標準裡的「不加 `--no-sandbox`」都要等這個決定。

---

## 5. xrdp 剪貼簿傳檔案需要 FUSE

**問題**：D9 的前提：xrdp 從 RDP 用戶端用剪貼簿傳檔案，需要 FUSE。沒有 `/dev/fuse` 時會怎樣？

**做法**（本機 rootless podman，tk8s 的 Pod 沒有 `/dev/fuse`）：

- 映像檔預設 `rdpdr=false`、`cliprdr=true`（`/etc/xrdp/xrdp.ini`）；執行後用 `sed -i 's/^rdpdr=false/rdpdr=true/' /etc/xrdp/xrdp.ini`，再讓客戶端登入
- 客戶端：把 e2e client 的 `login.sh` 的 `xfreerdp3` 加上 `+clipboard /drive:share,/share`；`/share/hello.txt` 內容是 `hello from client`
- 登入後在客戶端的 X（`:95`）用 `xclip -selection clipboard -t text/uri-list` 放入 `file:///share/hello.txt`；在伺服器端以 bigred 用 `xclip -o -selection clipboard -t TARGETS` 與 `-t text/uri-list` 檢查，並直接讀檔
- 三種情況：(i) 預設；(ii) `--device /dev/fuse`，並在容器裡裝 `fuse3`（提供 setuid 的 `fusermount3`，映像檔本來沒有）；(iii) (ii) 再加 `--cap-add SYS_ADMIN`
- log 在 `/home/bigred/.local/share/xrdp/xrdp-chansrv.10.log`

**結果**：

| 情況 | chansrv log | `thinclient_drives` | 傳檔 |
|---|---|---|---|
| (i) 預設 | 三次 `[ERROR] FUSE mount on /home/bigred/thinclient_drives failed. If /home/bigred/thinclient_drives is already mounted, you must first unmount it`，之後 `Detected remote drive 'share'` | 空目錄，`mount` 沒有 fuse | 剪貼簿的 TARGETS 有 `text/uri-list`、`x-special/gnome-copied-files`，內容 `file:///home/bigred/thinclient_drives/.clipboard/hello.txt`；但 `cat` 該路徑是 `No such file or directory`。**失敗** |
| (ii) `/dev/fuse` 加 `fuse3` | 同 (i)，三次 FUSE 錯誤 | 空目錄 | 同 (i)，失敗。bigred 的 `CapBnd: 00000000800405fb`（沒有 `CAP_SYS_ADMIN`） |
| (iii) 再加 `CAP_SYS_ADMIN` | 沒有 ERROR，只有 `Detected remote drive 'share'` | `mount`：`xrdp-chansrv on /home/bigred/thinclient_drives type fuse.xrdp-chansrv (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)` | `cat .../.clipboard/hello.txt` 輸出 `hello from client`，`.../thinclient_drives/share/hello.txt` 也在。**成功** |

另外：

- 映像檔裡 `xrdp-chansrv` 連結的是 `libfuse.so.2`（`ldd /usr/sbin/xrdp-chansrv`），映像檔沒有 `fusermount`
- tk8s 的 Pod（RuntimeDefault、沒有 `/dev/fuse`、`rdpdr=false`）的 chansrv log 同樣出現三次 `FUSE mount ... failed`，而且 HOME 底下會建立一個空的 `thinclient_drives` 目錄，JupyterLab 的檔案瀏覽器根目錄看得到它（截圖 `s4-unconf.png`）

**對設計的影響**：

- 前提成立：沒有可用的 FUSE，剪貼簿傳檔一定失敗
- 而且不只要 `/dev/fuse`：要同時有 `/dev/fuse`、`CAP_SYS_ADMIN`（讓 setuid 的 `fusermount3` 能 mount）、`fuse3` 套件。`CAP_SYS_ADMIN` 跟 spec §6 的安全姿態（drop capabilities、RuntimeDefault）衝突，所以預設部署不開，傳檔的替代方式是 JupyterLab 檔案瀏覽器的上傳／下載按鈕
- 預設部署保持 `rdpdr=false`；chansrv 的 FUSE 錯誤 log 是預期的雜訊，要寫進文件避免被當成故障
- `thinclient_drives` 空目錄會出現在 HOME，要決定要不要隱藏或接受

---

## 清理

- `kubectl delete ns rdp-jupyter-spike` 已執行，`kubectl get ns` 已沒有該 namespace
- 本機測試用的 podman 容器已移除
- rdp-vscode 的 `run.sh` 沒有清理節點上映像檔的做法，所以 `localhost/rdp-jupyter-spike:b` 仍在 `tk8s-worker-1`、`tk8s-worker-2` 的 containers-storage；CRI-O 也快取了 `python:3.13-slim`。沒有動節點設定
