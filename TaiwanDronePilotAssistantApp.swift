import SwiftUI
import GoogleMobileAds

@main
struct TaiwanDronePilotAssistantApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }

    init() {
        // 僅允許一般觀眾（G）內容，降低色情、賭博、暴力或驚悚素材出現的機率。
        // AdMob 後台的敏感類別封鎖仍需另外設定，SDK 分級不是絕對內容保證。
        MobileAds.shared.requestConfiguration.maxAdContentRating = GADMaxAdContentRating.general
        MobileAds.shared.start()
    }
}
