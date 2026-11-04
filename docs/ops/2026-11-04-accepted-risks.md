# 已接受的安全風險紀錄

本檔記錄經維護者明確決定後「接受並暫不修補」的安全發現。每一條都附日期、理由，以及未來重新評估的觸發條件。對應的掃描忽略設定在 `.trivyignore`。

## 2026-11-04 — JupyterLab 剪貼簿 XSS（CVE-2026-102831）

- **影響套件**：`jupyterlab` 4.6.3（前端）
- **弱點**：從系統剪貼簿貼上惡意 notebook 儲存格內容時可觸發 XSS。相關的同批修補還有 CVE-2026-102830（惡意語言包）、CVE-2026-102832（命令連結信任提示）。
- **上游修補狀態**：
  - 核心 `jupyterlab` 已於 4.6.4（2026-09-21）與 4.6.5（2026-10-29）修正。
  - 但 **JupyterLab Desktop（本專案使用的 Electron 前端）尚無已修補的發行版**，最新 tag 仍是 `v4.6.3-1`；把 bundle 升到 4.6.4 的 PR 已合併但尚未發行。
  - 本專案的 `jupyterlab` pip pin 刻意鎖定成與 JupyterLab Desktop 4.6.3-1 打包的版本一致；且有弱點的前端程式打包在 Electron asar bundle 內，單純升 pip 套件無法修補實際 UI。
- **決定**：**接受風險、維持現狀**，在 `.trivyignore` 保留 `CVE-2026-102831`。
- **理由**：
  1. 目前沒有已修補的 JupyterLab Desktop 發行版可升級。
  2. 部署型態為「單一使用者 / 單一 Pod」的 kiosk，Pod 內唯一的操作者就是該分析師本人；對自己進行剪貼簿 / 語言包 XSS 的實際價值很低。
- **重新評估觸發條件**：當 JupyterLab Desktop 發布 `4.6.4-1` 或更新版本時，同時升級 Desktop bundle 與 pip pin（維持兩者一致），並移除 `.trivyignore` 中的這條，重跑 `test/image/supply-chain.test.sh`。
