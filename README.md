# Taiwan Drone Pilot Assistant 台灣空拍機飛行助手

這是一個可直接開啟的手機版 UI 原型，入口為 [`index.html`](./index.html)。目前包含：

本專案已附上 `server.js` CWA 後端代理，避免授權碼暴露在前端。啟動前請將 `.env.example` 複製成 `.env.local`，填入 CWA 與 Brave Search 金鑰後，以 `node server.js` 啟動。Brave 僅作為 MapKit 地點搜尋失敗時的地址備援，不是空域或天氣資料來源。

## 資安與隱私

- `.env`、`.env.local` 與其他環境檔已加入 `.gitignore`，CWA、Brave、OpenAI 等後端金鑰不得提交到 GitHub。
- RevenueCat 的 `appl_` Public SDK Key 與 AdMob App ID／廣告單元 ID 會出現在 iOS App 中，這些是平台設計上的公開識別值；後端 secret 絕不放入 iOS 原始碼。
- 若任何後端金鑰曾被貼到公開場所，請立即在服務商後台撤銷並重新建立，不要只修改 Git 歷史。
- 隱私權政策頁面位於 [`privacy-policy.html`](./privacy-policy.html)，GitHub Pages 發佈後網址為：<https://eric1207cvb.github.io/DronePilotAssistant/privacy-policy.html>。

實體 iPhone 測試時，請讓 Mac 與 iPhone 連接同一個 Wi-Fi，並在 App「設定 → 備援服務」填入 Mac 的區域網路 IP；Simulator 可使用 `http://127.0.0.1:8000`。請確認 Mac 防火牆允許 Node 服務接收區域網路連線。

AdMob App ID 已設定為 `ca-app-pub-8563333250584395~5797408070`，Banner Ad Unit ID 已設定為 `ca-app-pub-8563333250584395/8231999725`。請在 Xcode 以 `File → Add Package Dependencies` 加入 `https://github.com/googleads/swift-package-manager-google-mobile-ads.git`；Debug 會使用 Google 測試 Banner，Release 才使用正式廣告單元。Banner 目前放在固定安全區域，會在可滑動內容與分頁按鈕列上方持續顯示，不會被捲動內容藏住或覆蓋格子。

為避免對中央氣象署造成過度請求，代理已加入：相同地點 10 分鐘快取、單一用戶端 30 秒查詢間隔、相同地點請求合併、10 秒上游逾時，以及前端 30 秒防連點。

- 天候摘要、風速／陣風／風向／降雨／雲覆蓋率／能見度、日出日落與飛行建議
- 可見衛星、Kp、衛星鎖定等飛行輔助數值
- 台灣空域規範偵測卡片與官方民航局入口
- 附近空域地圖示意、飛行前檢查清單
- 廣告版位與 Taiwan Drone Pilot Assistant Pro 移除廣告的訂閱流程原型

正式 iOS 版本建議：天氣使用中央氣象署（CWA）開放資料 API，地圖使用 MapKit，空域圖資以民航局遙控無人機管理資訊系統及各縣市公告為資料來源；廣告採 Google Mobile Ads SDK，移除廣告則採 Apple StoreKit 非消耗型／訂閱內購。圖資與判定需顯示更新時間及「以官方公告為準」的安全聲明。CWA API 需要先申請會員與 API 授權金鑰。

官方空域查詢：<https://drone.caa.gov.tw/>

空域查詢已使用民航局 ArcGIS REST 圖資服務 `UAV_Fly_Zone_Cut`，由 `/api/airspace` 以目前座標查詢附近 1 公里範圍並回傳 GeoJSON；前端會繪製 Polygon／MultiPolygon。介面固定標示「資料來源：交通部民航局／僅供參考，以最新公告為準」。民航局圖資請求也有 10 分鐘快取、每個用戶端 30 秒間隔、同座標請求合併與 10 秒逾時。

中央氣象署開放資料：<https://opendata.cwa.gov.tw/devManual/insrtuction>
