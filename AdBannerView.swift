import SwiftUI
import GoogleMobileAds

struct AdBannerView: UIViewRepresentable {
    private let productionUnitID = "ca-app-pub-8563333250584395/8231999725"
    private let testUnitID = "ca-app-pub-3940256099942544/2435281174"

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        #if DEBUG
        banner.adUnitID = testUnitID
        #else
        banner.adUnitID = productionUnitID
        #endif
        banner.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {}
}
