import SwiftUI
import GoogleMobileAds

@main
struct TaiwanDronePilotAssistantApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }

    init() { MobileAds.shared.start() }
}
