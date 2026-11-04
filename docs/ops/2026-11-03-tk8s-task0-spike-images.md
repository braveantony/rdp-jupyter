# 2026-11-03 在 tk8s 節點載入 Task 0 spike 映像檔

## 為什麼要改

rdp-jupyter 的 Task 0（見 [../spike-notes.md](../spike-notes.md)）要在 tk8s 上驗證 Electron sandbox，所以把本機的 spike 映像檔 `localhost/rdp-jupyter-spike:b` 載入了節點。做法照 rdp-vscode 的 `test/e2e/run.sh`（`podman save` 加 `sudo skopeo copy`）。測試用的 namespace `rdp-jupyter-spike` 已經刪除，但節點的映像檔儲存區有變動，而且 rdp-vscode 的 `run.sh` 沒有清理映像檔的做法，所以這些映像檔還留在節點上。

## 修改前的狀態

- 三個節點上都沒有 `localhost/rdp-jupyter-spike`
- `python:3.13-slim` 不在節點上（Task 0 第 1 題的 Pod 啟動時才拉取）

## 做了什麼

1. 載入 spike 映像檔到兩個 worker（寫入節點的 containers-storage）：

   ```bash
   podman save -o img.tar localhost/rdp-jupyter-spike:b
   for n in tk8s-worker-1 tk8s-worker-2; do
     st=/var/lib/containers/storage/volumes/$n-var/_data/lib/containers/storage
     sudo skopeo copy -q "docker-archive:$PWD/img.tar" \
       "containers-storage:[overlay@$st+/run/rdp-jupyter-load-$n]localhost/rdp-jupyter-spike:b"
   done
   ```

2. 第 1 題的 Pod 排到 `tk8s-control-plane-1`，CRI-O 在那個節點拉取了 `docker.io/library/python:3.13-slim`（約 123 MB）。

## 修改後的狀態

唯讀檢查（`sudo podman exec <節點> crictl images`）：

| 節點 | 多出來的映像檔 |
|---|---|
| `tk8s-control-plane-1` | `docker.io/library/python:3.13-slim`（123 MB） |
| `tk8s-worker-1` | `localhost/rdp-jupyter-spike:b`（3.41 GB） |
| `tk8s-worker-2` | `localhost/rdp-jupyter-spike:b`（3.41 GB） |

沒有改動節點的其他設定、kubelet 設定或 StorageClass。

## 如何移除（尚未執行，等決定之後再做）

```bash
for n in tk8s-worker-1 tk8s-worker-2; do
  sudo podman exec "$n" crictl rmi localhost/rdp-jupyter-spike:b
done
sudo podman exec tk8s-control-plane-1 crictl rmi docker.io/library/python:3.13-slim
```

移除後用 `sudo podman exec <節點> crictl images | grep -E "python|rdp-jupyter"` 確認沒有輸出。移除前先確認沒有 Pod 在使用（`kubectl get pod -A -o jsonpath='{..image}' | tr ' ' '\n' | grep -E "rdp-jupyter-spike|python:3.13-slim"` 沒有輸出）。
