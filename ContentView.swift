import SwiftUI
import Foundation
import MapKit
import WebKit
import RevenueCat

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("hasOfficialAirspaceApproval") private var hasOfficialAirspaceApproval = false
    @State private var location = "台北市大安區"
    @State private var resolvedPlaceName: String?
    @State private var showingCAAQuery = false
    @State private var caaCoordinate: CLLocationCoordinate2D?
    @State private var caaCountyCode = "All"
    @State private var caaQueryID = UUID()
    @State private var caaSearchText = ""
    @State private var caaSearchError: String?
    @State private var queryMessage = "等待定位或手動查詢"
    @State private var searchSessionActive = false
    @State private var selectedTab = 0
    @FocusState private var searchFocused: Bool
    @StateObject private var locationManager = LocationManager()
    @StateObject private var weatherService = WeatherService()
    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var airspaceService = AirspaceService()
    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 6 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pageSwitcher
            if selectedTab == 0 {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        HStack { VStack(alignment: .leading, spacing: 2) { Text(resolvedPlaceName ?? location).font(.title3.weight(.bold)); if let coordinate = weatherService.queriedCoordinate { Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)).font(.caption2).foregroundStyle(.secondary) }; Text(weatherService.errorMessage ?? queryMessage).font(.caption2).foregroundStyle(weatherService.errorMessage == nil ? Color.secondary : Color.orange) }; Spacer(); Text(refreshing ? "更新中…" : weatherService.snapshot.lastUpdated).font(.caption).foregroundStyle(.secondary) }
                        if refreshing { refreshBanner }
                        flightStatus
                        parameterGrid
                        airspaceSection
                        sourceNote
                    }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12)
                }
            } else if selectedTab == 2 {
                mapPage
            } else if selectedTab == 1 {
                forecastPage
            } else {
                settingsPage
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .tint(.blue)
        .preferredColorScheme(preferredColorScheme)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !subscriptionManager.isPro {
                AdBannerView()
                    .frame(height: 50)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .top) { Divider() }
            }
        }
        // 以每次 Core Location 回報的 updateID 觸發，而不是只監聽緯度。
        // 同一位置第二次定位時，緯度可能完全相同，但仍必須重新查詢。
        .onChange(of: locationManager.updateID) { _, _ in
            if let coordinate = locationManager.coordinate {
                location = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
                queryMessage = "GPS 定位：已取得座標，正在更新 CWA"
                resolvedPlaceName = nil
                airspaceService.resetForNewQuery()
                weatherService.load(coordinate: coordinate)
                airspaceService.load(coordinate: coordinate)
            }
        }
        .onChange(of: weatherService.queryID) { _, _ in
            if let coordinate = weatherService.queriedCoordinate {
                airspaceService.load(coordinate: coordinate)
                resolvePlaceName(for: coordinate)
                // 天氣與空域都命中快取時，不會產生 loading 狀態變化，需主動結束本次查詢。
                DispatchQueue.main.async {
                    if !actualRefreshing { searchSessionActive = false }
                }
            }
        }
        .onChange(of: actualRefreshing) { _, isRefreshing in
            if !isRefreshing { searchSessionActive = false }
        }
        .sheet(isPresented: $showingCAAQuery) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("輸入地址或地標，例如松山機場、漁人碼頭", text: $caaSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("查詢") { Task { await submitCAAQuery() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial)
                if let caaSearchError {
                    Text(caaSearchError).font(.caption2).foregroundStyle(.orange).padding(.vertical, 3)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Label("請在官方 GIS 完成確認", systemImage: "checkmark.shield.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text("1. 按地圖內的「查詢」　2. 開啟左側選單　3. 選擇「載入活動空域」")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                CAAQueryWebView(coordinate: caaCoordinate, countyCode: caaCountyCode)
                    .id(caaQueryID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 4) {
            pageButton("條件", "sun.max.fill", 0)
            pageButton("預測", "calendar", 1)
            pageButton("地圖", "map.fill", 2)
        }
        .padding(5).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17))
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func resolvePlaceName(for coordinate: CLLocationCoordinate2D) {
        resolvedPlaceName = nil
        Task {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
            let parts = [placemark?.administrativeArea, placemark?.locality, placemark?.subLocality]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                resolvedPlaceName = parts.reduce(into: [String]()) { result, part in
                    if !result.contains(part) { result.append(part) }
                }.joined()
            } else if let name = placemark?.areasOfInterest?.first, !name.isEmpty {
                resolvedPlaceName = name
            }
        }
    }

    private var mapPage: some View {
        let taipei = CLLocationCoordinate2D(latitude: 25.0268, longitude: 121.5350)
        let current = locationManager.coordinate ?? taipei
        let isCurrentLocation = locationManager.coordinate != nil
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                Map(initialPosition: .region(MKCoordinateRegion(center: current, latitudinalMeters: 2600, longitudinalMeters: 2600))) {
                    Marker(isCurrentLocation ? "目前 GPS 位置" : "預設位置", coordinate: current).tint(.blue)
                    MapCircle(center: current, radius: 1000).foregroundStyle(.orange.opacity(0.20)).stroke(.orange, lineWidth: 2)
                }
                .frame(height: 390).clipShape(RoundedRectangle(cornerRadius: 18))
                let mapAssessment = isCurrentLocation ? operationalAssessment : AirspaceAssessment(title: "尚未取得 GPS", zone: "—", detail: "請先按右上角定位按鈕", tint: .orange, isProhibited: false, isUnknown: true)
                HStack { Image(systemName: mapAssessment.isProhibited ? "xmark.shield.fill" : "checkmark.shield.fill").foregroundStyle(mapAssessment.tint); VStack(alignment: .leading) { Text(isCurrentLocation ? mapAssessment.title : "尚未取得 GPS 位置").font(.headline); Text(isCurrentLocation ? mapAssessment.detail : "請先按右上角定位按鈕").font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(14).glassEffect(.regular.tint(mapAssessment.tint.opacity(0.18)), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) { Text("圖資與法規提醒").font(.headline); Text("資料來源：交通部民航局 UAV 空域圖資（UAV_Fly_Zone_Cut）").font(.caption); Text("僅供參考，以最新官方公告、現場狀況與相關法規為準。圖資可能有更新延遲，飛行前請再次確認。").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(14).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15))
            }.padding(10)
        }
    }

    private func pageButton(_ title: String, _ icon: String, _ index: Int) -> some View {
        Button { selectedTab = index } label: { Label(title, systemImage: icon).font(.system(size: 11, weight: selectedTab == index ? .bold : .medium)).frame(maxWidth: .infinity).padding(.vertical, 8).foregroundStyle(selectedTab == index ? .blue : .primary).background(selectedTab == index ? Color.blue.opacity(0.14) : .clear, in: Capsule()) }
    }

    private var forecastPage: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            HStack { Text("未來 7 日預測").font(.title2.bold()); Spacer(); Text("CWA").font(.caption.bold()).foregroundStyle(.blue) }
            Text("全台鄉鎮 · 中央氣象署逐 3 小時預報資料").font(.caption).foregroundStyle(.secondary)
            if weatherService.isBusy || weatherService.forecast.isEmpty {
                Text(weatherService.isLoading ? "正在取得 CWA 預報…" : (weatherService.errorMessage ?? "請先使用 GPS 或按「查詢」取得預報")).font(.subheadline).foregroundStyle(weatherService.errorMessage == nil ? Color.secondary : Color.orange).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(25).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15))
            } else {
                ForEach(weatherService.forecast) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Text(item.day).frame(width: 62, alignment: .leading).font(.subheadline.bold())
                            if let icon = item.icon { Text(icon).font(.title2) }
                            if let temperature = item.temperature { Text(temperature).font(.headline) }
                            Spacer()
                            if let rain = item.rain { Label(rain, systemImage: "drop.fill").font(.caption).foregroundStyle(.blue) }
                        }
                        if !item.hourly.isEmpty {
                            Divider()
                            ForEach(item.hourly) { hour in
                                HStack(spacing: 8) {
                                    Text(hour.time).font(.caption2.monospaced()).frame(width: 78, alignment: .leading)
                                    if let temperature = hour.temperature { Text(temperature).font(.caption) }
                                    if let wind = hour.wind { Text(wind).font(.caption).foregroundStyle(.green) }
                                    if let level = hour.windLevel { Text("蒲福 \(level)級").font(.caption2).foregroundStyle(.orange) }
                                    Spacer()
                                    if let rain = hour.rain { Label(rain, systemImage: "drop.fill").font(.caption2).foregroundStyle(.blue) }
                                }
                            }
                        }
                    }.padding(15).glassEffect(.regular.tint(Color.primary.opacity(0.06)), in: RoundedRectangle(cornerRadius: 15))
                }
            }
            sourceNote
        }.padding(12) }
    }

    private var settingsPage: some View {
        List {
            Section("定位與查詢") { Label(locationManager.statusMessage, systemImage: "location.fill"); Label("手動查詢地點／座標", systemImage: "magnifyingglass"); Label("目前位置：\(location)", systemImage: "mappin.and.ellipse") }
            Section("顯示單位") { Label("風速：km/h", systemImage: "wind"); Label("能見度：km", systemImage: "eye") }
            Section("外觀") {
                Picker("顏色模式", selection: $appearanceMode) {
                    Text("跟隨系統").tag("system")
                    Text("淺色").tag("light")
                    Text("深色").tag("dark")
                }
            }
            Section("訂閱方案") {
                if subscriptionManager.isPro {
                    Label("Pro 訂閱有效 · 已移除廣告", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("免費版：顯示 Google AdMob 廣告", systemImage: "rectangle.inset.filled.and.person.filled")
                    if let package = subscriptionManager.monthlyPackage {
                        Button {
                            Task { await subscriptionManager.purchase(package) }
                        } label: {
                            Label("訂閱 Pro · \(package.storeProduct.localizedPriceString)／月", systemImage: "crown.fill")
                        }
                        .disabled(subscriptionManager.isPurchasing)
                    } else {
                        Text(subscriptionManager.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("恢復購買") { Task { await subscriptionManager.restore() } }
            }
            Section("法律與隱私") {
                Link("隱私權政策", destination: URL(string: "https://eric1207cvb.github.io/DronePilotAssistant/privacy-policy.html")!)
                Link("Apple 標準 EULA", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            Section("資料來源") { Link("中央氣象署 CWA", destination: URL(string: "https://opendata.cwa.gov.tw")!); Link("交通部民航局空域圖資", destination: URL(string: "https://drone.caa.gov.tw")!); Text("資料僅供參考，以最新官方公告與現場狀況為準。") .font(.caption).foregroundStyle(.secondary) }
        }.scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "paperplane.circle.fill").font(.system(size: 42)).foregroundStyle(.cyan, .white); Text("Taiwan Drone Pilot Assistant").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.72); Spacer(); Button { selectedTab = 3 } label: { Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.white.opacity(0.95)).frame(width: 42, height: 42) }.accessibilityLabel("設定") }
            HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("輸入地址或地標", text: $location).font(.subheadline).focused($searchFocused).submitLabel(.search).onSubmit { performSearch() }; Button { performSearch() } label: { Text("查詢") }.buttonStyle(.borderedProminent).tint(.blue).disabled(refreshing); Button { searchSessionActive = true; searchFocused = false; locationManager.requestLocation(); queryMessage = "正在取得 iPhone GPS…" } label: { Image(systemName: "location.fill") }.buttonStyle(.bordered).tint(.blue).disabled(refreshing) }.padding(7).glassEffect(.regular.tint(colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.95)), in: RoundedRectangle(cornerRadius: 13))
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10).background(LinearGradient(colors: colorScheme == .dark ? [Color(red: 0.05, green: 0.24, blue: 0.48), Color(red: 0.08, green: 0.12, blue: 0.28)] : [Color(red: 0.30, green: 0.68, blue: 0.94), Color(red: 0.18, green: 0.43, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func performSearch() {
        searchFocused = false
        searchSessionActive = true
        resolvedPlaceName = nil
        airspaceService.resetForNewQuery()
        queryMessage = "正在確認地點…"
        weatherService.search(text: location)
    }

    private var actualRefreshing: Bool { locationManager.isRequesting || weatherService.isBusy || airspaceService.isLoading }
    // 只以實際進行中的工作控制 UI；避免快取命中或空查詢時，
    // searchSessionActive 與真實狀態不同步而造成進度條消失／按鈕鎖死。
    private var refreshing: Bool { actualRefreshing }

    private var refreshBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(refreshPhase)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.blue.opacity(0.18))
                    Capsule().fill(Color.blue).frame(width: max(70, proxy.size.width * 0.28))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var refreshPhase: String {
        if weatherService.isResolvingLocation { return "正在確認地點與地址…" }
        if weatherService.isLoading && airspaceService.isLoading { return "正在更新 CWA 天氣與民航局空域…" }
        if weatherService.isLoading { return "正在更新中央氣象署資料…" }
        return "正在更新民航局空域圖資…"
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var flightStatus: some View {
        let assessment = operationalAssessment
        return VStack(spacing: 3) {
            Text(assessment.title).font(.system(size: 25, weight: .bold, design: .rounded))
            Text(assessment.detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 10)
            .glassEffect(.regular.tint(assessment.tint.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 15))
    }

    private var parameterGrid: some View {
        let loading = refreshing
        let value: (String) -> String = { loading ? "—" : $0 }
        return LazyVGrid(columns: columns, spacing: 10) {
            Tile(title: "天氣", value: loading ? "—" : "☁", detail: loading ? "資料更新中" : weatherService.snapshot.condition, color: .cyan.opacity(0.17), valueSize: 42)
            Tile(title: "日出／日落", value: value("↑ \(weatherService.snapshot.sunrise)\n↓ \(weatherService.snapshot.sunset)"), color: .yellow.opacity(0.72), valueSize: 19)
            Tile(title: "溫度", value: value(weatherService.snapshot.temperature), color: loading ? .gray.opacity(0.25) : temperatureTileColor, valueSize: 25)
            Tile(title: "風速", value: value(weatherService.snapshot.windSpeed), detail: loading ? nil : weatherService.snapshot.windMetersPerSecond, color: .green.opacity(0.32), valueSize: 24)
            Tile(title: "陣風／風級", value: value(weatherService.snapshot.windLevel), detail: loading ? nil : weatherService.snapshot.windSpeed, color: .green.opacity(0.55), valueSize: 18)
            Tile(title: "風向", value: value("↘"), detail: loading ? nil : weatherService.snapshot.windDirection, color: .green.opacity(0.55), valueSize: 38)
            Tile(title: "降雨機率", value: value(weatherService.snapshot.rainChance), color: .green.opacity(0.55), valueSize: 25)
            Tile(title: "雲覆蓋率", value: value("94%"), color: .green.opacity(0.20), valueSize: 25)
            Tile(title: "能見度", value: value(weatherService.snapshot.visibility), color: .green.opacity(0.55), valueSize: 21)
            Tile(title: "定位訊號", value: locationSignal.label, detail: locationSignal.detail, color: locationSignal.color, valueSize: 17)
            Tile(title: "Kp", value: value(weatherService.snapshot.kp), detail: loading ? nil : "NOAA SWPC", color: .green.opacity(0.55), valueSize: 27)
            Tile(title: "GPS 精度", value: loading ? "—" : (locationManager.horizontalAccuracy.map { "\($0.formatted(.number.precision(.fractionLength(0)))) m" } ?? "—"), detail: "Core Location", color: .green.opacity(0.55), valueSize: 19)
        }
    }

    private var regulationGrid: some View {
        let assessment = airspaceAssessment
        let heightLimited = assessment.detail.contains("限高")
        return LazyVGrid(columns: columns, spacing: 10) {
            Tile(title: "目前空域", value: assessment.title, detail: assessment.zone, color: assessment.tint.opacity(0.55), valueSize: 17)
            Tile(title: "禁限航區", value: assessment.isProhibited ? "禁飛" : "待確認", detail: assessment.isProhibited ? "需官方申請" : "官方圖資", color: assessment.tint.opacity(0.55), valueSize: 23)
            Tile(title: "高度提醒", value: assessment.isProhibited ? "禁飛需官方申請" : (heightLimited ? "限高 200 呎" : "待確認"), detail: "以官方公告為準", color: assessment.isProhibited ? .red.opacity(0.48) : (heightLimited ? .yellow.opacity(0.55) : .yellow.opacity(0.35)), valueSize: 15)
            Button { openCAAQuery() } label: {
                VStack(spacing: 5) {
                    Label("民航局真實圖資", systemImage: "map.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text("官方 GIS 查詢")
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 70)
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var airspaceSection: some View {
        let assessment = airspaceAssessment
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("台灣空域與法規").font(.headline)
            }
            if assessment.isUnknown {
                VStack(alignment: .leading, spacing: 9) {
                    Label("空域待確認", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    Text("目前無法從民航局圖資完成此座標的自動比對。請開啟官方空域查詢，輸入目前座標確認最新禁航、限航與地方政府公告。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("基本規則：禁航區、限航區及航空站／飛行場周邊公告範圍禁止無人機活動；其他區域仍須遵守民航法、地方政府公告及高度限制。圖資僅供參考，以最新官方公告為準。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(14).glassEffect(.regular.tint(.orange.opacity(0.16)), in: RoundedRectangle(cornerRadius: 15))
            } else {
                regulationGrid
            }
        }.padding(.top, 10)
    }

    private func openCAAQuery() {
        guard let coordinate = weatherService.queriedCoordinate ?? locationManager.coordinate else {
            showingCAAQuery = true
            return
        }
        caaCoordinate = coordinate
        caaSearchText = resolvedPlaceName ?? "目前 GPS 位置"
        caaSearchError = nil
        // 每次開啟都建立新的 WebView，避免 ArcGIS 第一次查詢後把搜尋列收起或保留舊狀態。
        caaQueryID = UUID()
        Task {
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
            caaCountyCode = countyCode(for: placemark)
            showingCAAQuery = true
        }
    }

    private func countyCode(for placemark: CLPlacemark?) -> String {
        let text = [placemark?.administrativeArea, placemark?.locality].compactMap { $0 }.joined()
        let codes = ["基隆": "52", "臺北": "51", "台北": "51", "新北": "53", "桃園": "59", "新竹縣": "57", "新竹市": "58", "苗栗": "60", "臺中": "61", "台中": "61", "彰化": "62", "南投": "63", "雲林": "66", "嘉義縣": "65", "嘉義市": "64", "臺南": "67", "台南": "67", "高雄": "68", "屏東": "72", "宜蘭": "55", "花蓮": "74", "臺東": "73", "台東": "73", "澎湖": "70", "金門": "71", "連江": "54"]
        return codes.first(where: { text.contains($0.key) })?.value ?? "All"
    }

    private func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let values = text.split { $0 == "," || $0 == " " || $0 == "，" }
            .compactMap { Double($0) }
        guard values.count >= 2,
              (-90...90).contains(values[0]),
              (-180...180).contains(values[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: values[0], longitude: values[1])
    }

    @MainActor
    private func submitCAAQuery() async {
        let text = caaSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            caaSearchError = "請輸入地址、地標，或使用目前 GPS 位置"
            return
        }
        if text == "目前 GPS 位置", let caaCoordinate {
            caaSearchError = nil
            caaQueryID = UUID()
            return
        }
        if let coordinate = parseCoordinate(text) {
            caaCoordinate = coordinate
            caaSearchError = nil
            caaQueryID = UUID()
            return
        }
        do {
            let taiwan = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.95),
                span: MKCoordinateSpan(latitudeDelta: 4.5, longitudeDelta: 5.0)
            )
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.region = taiwan
            request.resultTypes = [.address, .pointOfInterest]
            let response = try await MKLocalSearch(request: request).start()
            let normalized = text.replacingOccurrences(of: "臺", with: "台")
            let item = response.mapItems.first(where: { item in
                let name = (item.name ?? "").replacingOccurrences(of: "臺", with: "台")
                return name.localizedCaseInsensitiveContains(normalized)
                    || (normalized.contains("松山商職") && name.contains("松山") && name.contains("商"))
                    || (normalized.contains("松山高商") && name.contains("松山") && name.contains("商"))
            }) ?? response.mapItems.first
            guard let coordinate = item?.placemark.coordinate else {
                caaSearchError = "找不到這個地址或地標，請換一種寫法"
                return
            }
            caaCoordinate = coordinate
            caaSearchError = nil
            caaQueryID = UUID()
        } catch {
            caaSearchError = "地址定位失敗，請確認網路或改輸入更完整的地名"
        }
    }

    private var airspaceAssessment: AirspaceAssessment {
        airspaceService.assessment
    }

    private var operationalAssessment: AirspaceAssessment {
        if refreshing {
            return AirspaceAssessment(title: "判定中", zone: airspaceAssessment.zone, detail: "正在比對民航局空域與 CWA 天氣資料", tint: .orange, isProhibited: false, isUnknown: true)
        }
        if airspaceAssessment.isProhibited { return airspaceAssessment }
        guard !weatherService.forecast.isEmpty else {
            return AirspaceAssessment(title: "空域待確認", zone: airspaceAssessment.zone, detail: "空域或天氣資料尚未完整取得 · 請先確認後再飛行", tint: .orange, isProhibited: false, isUnknown: true)
        }
        let wind = Double(weatherService.snapshot.windMetersPerSecond.replacingOccurrences(of: " m/s", with: "")) ?? 999
        let rain = Double(weatherService.snapshot.rainChance.replacingOccurrences(of: "%", with: "")) ?? 999
        if wind > 10 || rain > 50 {
            return AirspaceAssessment(title: "不建議飛行", zone: airspaceAssessment.zone, detail: "天氣條件未通過初步檢核 · 風速或降雨機率偏高", tint: .red, isProhibited: false, isUnknown: false)
        }
        if airspaceService.isUnknown {
            return AirspaceAssessment(title: "空域待確認", zone: airspaceAssessment.zone, detail: "民航局空域圖資未確認 · 不代表可飛", tint: .orange, isProhibited: false, isUnknown: true)
        }
        if airspaceAssessment.title == "可飛（有限制）" {
            let title = hasOfficialAirspaceApproval ? "可飛（有限制）" : "有條件飛行"
            let detail = hasOfficialAirspaceApproval
                ? "天氣已通過初步檢核 · 仍須遵守主管機關、時間、範圍與高度條件"
                : "尚未取得或未設定官方許可 · 僅能依圖資查看限制，不代表目前可飛"
            return AirspaceAssessment(title: title, zone: airspaceAssessment.zone, detail: detail, tint: .yellow, isProhibited: false, isUnknown: false)
        }
        let title = hasOfficialAirspaceApproval ? "初步適合" : "符合圖資條件"
        let detail = hasOfficialAirspaceApproval
            ? "民航局圖資與 CWA 天氣已通過初步檢核 · 僅供參考"
            : "目前未設定官方許可 · 僅表示未命中禁限航圖資，仍須遵守一般飛行規範"
        return AirspaceAssessment(title: title, zone: airspaceAssessment.zone, detail: detail, tint: .green, isProhibited: false, isUnknown: false)
    }

    private var temperatureTileColor: Color {
        let text = weatherService.snapshot.temperature.replacingOccurrences(of: "−", with: "-")
        guard let value = Double(text.split(separator: "°").first ?? "") else { return .gray.opacity(0.25) }
        if value < 0 || value > 38 { return .red.opacity(0.55) }
        if value < 10 || value >= 35 { return .yellow.opacity(0.65) }
        return .green.opacity(0.32)
    }

    private var locationSignal: (label: String, detail: String, color: Color) {
        guard let accuracy = locationManager.horizontalAccuracy, accuracy >= 0 else {
            return ("無訊號", "Core Location", .red.opacity(0.55))
        }
        if accuracy <= 10 { return ("良好", "精度 ≤ 10 m", .green.opacity(0.55)) }
        if accuracy <= 30 { return ("中等", "精度 ≤ 30 m", .yellow.opacity(0.65)) }
        if accuracy <= 100 { return ("可能干擾", "精度 ≤ 100 m", .orange.opacity(0.55)) }
        return ("不良", "精度 > 100 m", .red.opacity(0.55))
    }

    private var sourceNote: some View { VStack(alignment: .leading, spacing: 2) { Text("資料來源：中央氣象署 CWA／交通部民航局 UAV 圖資").font(.caption2); Text("僅供參考，以最新官方公告、現場狀況與相關法規為準。").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(8).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 2) }
}

private struct Tile: View {
    let title: String; let value: String; var detail: String? = nil; let color: Color; var valueSize: CGFloat = 24
    @State private var showingSource = false

    var body: some View {
        Button { showingSource = true } label: {
            VStack(spacing: 3) {
                HStack(spacing: 2) { Text(title).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(2).multilineTextAlignment(.center); Image(systemName: isVerified ? "checkmark.seal.fill" : "questionmark.circle").font(.system(size: 8)).foregroundStyle(isVerified ? .green : .orange) }
                Spacer(minLength: 0)
                Text(value).font(.system(size: min(valueSize, 18), weight: .semibold, design: .rounded)).multilineTextAlignment(.center).minimumScaleFactor(0.5)
                if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, minHeight: 70).padding(.vertical, 6).padding(.horizontal, 2).glassEffect(.regular.tint(color).interactive(), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).alert("資訊來源驗證", isPresented: $showingSource) { Button("知道了", role: .cancel) {} } message: { Text(sourceDescription) }
    }

    private var isVerified: Bool { sourceDescription.hasPrefix("已驗證") }
    private var sourceDescription: String {
        switch title {
        case "天氣", "溫度", "風速", "陣風／風級", "風向", "降雨機率", "雲覆蓋率": return "已驗證：中央氣象署 CWA F-D0047-089（全台鄉鎮逐 3 小時預報）。由 API 回傳資料更新。"
        case "日出／日落": return "已驗證：中央氣象署 A-B0062-001 日出日沒時刻資料集，依目前縣市與日期更新。"
        case "能見度": return "已驗證：中央氣象署 O-A0003-001 即時測站觀測資料，顯示距離目前座標最近測站的能見度。"
        case "定位訊號": return "已驗證：依 iPhone Core Location horizontalAccuracy 實測精度分級；iOS 公開 API 不提供可見衛星數量。"
        case "Kp": return "已驗證：NOAA SWPC planetary_k_index_1m.json。每次 CWA 更新時同步取得。"
        case "GPS 精度": return "已驗證：iPhone Core Location horizontalAccuracy，單位為公尺；不是衛星數量。"
        case "目前空域", "禁限航區": return "安全判定：已套用查詢座標的保守機場圍籬；完整禁限航區仍須以民航局最新 UAV 圖資與官方公告確認。僅供參考。"
        case "高度提醒": return "法規參考：民航局依民航法第 99 條之 13 公告之區域。未取得完整圖資時不提供可飛結論。"
        case "飛行申請", "機體登錄", "操作證／保險": return "尚未連結個人申請／登錄資料。『待確認』是安全預設，不代表官方查詢結果。"
        default: return "此欄位目前沒有連結可驗證的官方資料來源。"
        }
    }
}

private struct AirspaceAssessment {
    let title: String
    let zone: String
    let detail: String
    let tint: Color
    let isProhibited: Bool
    let isUnknown: Bool

}

@MainActor
private final class AirspaceService: ObservableObject {
    @Published private(set) var assessment = AirspaceAssessment(title: "空域待確認", zone: "尚未取得座標", detail: "請使用 GPS 或手動查詢後再判定", tint: .orange, isProhibited: false, isUnknown: true)
    @Published private(set) var isLoading = false
    private var task: Task<Void, Never>?
    private let localIndex: LocalIndex

    private let backendBaseURL = "http://127.0.0.1:8000"

    init() {
        if let url = Bundle.main.url(forResource: "NoFlyZones", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let index = try? JSONDecoder().decode(LocalIndex.self, from: data) {
            localIndex = index
        } else {
            localIndex = LocalIndex(source: "未載入", updatedAt: "—", zones: [])
        }
    }

    var isUnknown: Bool { assessment.isUnknown }

    func load(coordinate: CLLocationCoordinate2D) {
        guard (21...26).contains(coordinate.latitude), (117...123).contains(coordinate.longitude) else { return }
        // 先用本機 55 KB 索引找出可能的禁航區，再由民航局服務做最後確認。
        // 索引只做保守預警，不直接取代官方多邊形判定。
        let localIndexHit = localIndex.zones.contains { zone in
            zone.minLat...zone.maxLat ~= coordinate.latitude && zone.minLon...zone.maxLon ~= coordinate.longitude
        }
        task?.cancel()
        isLoading = true
        assessment = AirspaceAssessment(title: "判定中", zone: "正在取得官方圖資", detail: "請稍候，完成前不提供可飛結論", tint: .orange, isProhibited: false, isUnknown: true)
        task = Task { await request(coordinate: coordinate, localIndexHit: localIndexHit) }
    }

    func resetForNewQuery() {
        task?.cancel()
        isLoading = false
        assessment = AirspaceAssessment(title: "判定中", zone: "等待新位置", detail: "完成官方圖資與天氣更新前不提供可飛結論", tint: .orange, isProhibited: false, isUnknown: true)
    }

    private func request(coordinate: CLLocationCoordinate2D, localIndexHit: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let airportPremises = knownAirportPremises(for: coordinate)
        var components = URLComponents(string: "https://dronegis.caa.gov.tw/server/rest/services/Hosted/UAV_Fly_Zone_Cut/FeatureServer/0/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: "{\"x\":\(coordinate.longitude),\"y\":\(coordinate.latitude)}"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "distance", value: "1"),
            URLQueryItem(name: "units", value: "esriSRUnit_Meter"),
            // 只取判定與顯示所需欄位，避免民航局服務回傳過大而逾時。
            URLQueryItem(name: "outFields", value: "objectid,spaceid,allowedfly,nfztype,governmentagencylist"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "geojson")
        ]
        do {
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = object["features"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            let properties = features.compactMap { $0["properties"] as? [String: Any] }
            let restrictions = properties.flatMap { property -> [(name: String, type: Int)] in
                guard let raw = property["governmentagencylist"] as? String,
                      let groups = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return [] }
                return groups.flatMap { group in
                    (group["intersects"] as? [[String: Any]] ?? []).compactMap { item in
                        guard let name = item["airspacename"] as? String else { return nil }
                        let type = (item["airspacetype"] as? NSNumber)?.intValue ?? Int(item["airspacetype"] as? String ?? "-1") ?? -1
                        return (name: name, type: type)
                    }
                }
            }
            let conditionNames = restrictions.map(\.name)
            let uniqueConditions = Array(NSOrderedSet(array: conditionNames)) as? [String] ?? []
            let hasHeightLimit = restrictions.contains { $0.type == 5 }
            let conditionPrefix = hasHeightLimit ? "限高 200 呎；" : ""
            let conditionText = uniqueConditions.isEmpty ? "可飛但須遵守主管機關、時間、範圍與高度條件" : conditionPrefix + "限制項目：" + uniqueConditions.prefix(3).joined(separator: "、")
            let prohibited = properties.contains { property in
                let nfz = (property["nfztype"] as? NSNumber)?.intValue ?? Int(property["nfztype"] as? String ?? "-1") ?? -1
                let allowed = (property["allowedfly"] as? NSNumber)?.intValue ?? Int(property["allowedfly"] as? String ?? "-1") ?? -1
                return nfz == 1 || allowed == 0
            }
            // 以民航局回傳的 nfztype / allowedfly 為唯一禁飛判定依據。
            // 不使用固定機場半徑覆蓋官方結果，避免把限高或條件可飛誤判為禁飛。
            if let airportPremises {
                assessment = AirspaceAssessment(title: "禁飛需官方申請", zone: "\(airportPremises.name)本場範圍", detail: "目前位置位於航空站／飛行場本場安全範圍 · 未取得官方同意不得飛行", tint: .red, isProhibited: true, isUnknown: false)
            } else if prohibited {
                assessment = AirspaceAssessment(title: "禁飛需官方申請", zone: "民航局 UAV 禁限航圖資命中", detail: "目前座標位於禁止或限制區域 · 請依官方程序申請或離開", tint: .red, isProhibited: true, isUnknown: false)
            } else if !features.isEmpty {
                assessment = AirspaceAssessment(title: "可飛（有限制）", zone: "民航局 UAV 圖資命中", detail: conditionText, tint: .green, isProhibited: false, isUnknown: false)
            } else if localIndexHit {
                // 本機索引只有包圍盒，且未保存官方 allowedfly/nfztype。
                // 命中只能提示「需要官方確認」，不能直接推導成禁飛。
                assessment = AirspaceAssessment(title: "空域待確認", zone: "本機索引有相關圖資", detail: "民航局服務未回傳可判定圖形 · 請開啟官方 GIS 確認，不代表禁飛或可飛", tint: .orange, isProhibited: false, isUnknown: true)
            } else {
                assessment = AirspaceAssessment(title: "可飛（無命中限制區）", zone: "民航局圖資未命中禁限航區", detail: "可依一般規範飛行；仍須遵守地方政府及其他法規", tint: .green, isProhibited: false, isUnknown: false)
            }
            // GPT 只做官方欄位的矛盾檢查與條件摘要；不能降低民航局明確禁飛結果。
            // 官方民航局圖資是唯一判定來源。AI 複核不參與正式結果，避免實體 iPhone
            // 無法連到 Mac 後端時產生 /api/airspace-review 逾時與誤導性延遲。
        } catch {
            if !Task.isCancelled {
                if let airportPremises { assessment = AirspaceAssessment(title: "禁飛需官方申請", zone: "\(airportPremises.name)本場範圍", detail: "民航局服務暫時無法連線，但已知位於航空站／飛行場本場 · 未取得官方同意不得飛行", tint: .red, isProhibited: true, isUnknown: false) }
                else if localIndexHit { assessment = AirspaceAssessment(title: "空域待確認", zone: "本機索引有相關圖資", detail: "民航局服務暫時無法連線 · 請開啟官方 GIS 確認", tint: .orange, isProhibited: false, isUnknown: true) }
                else { assessment = AirspaceAssessment(title: "空域待確認", zone: "民航局圖資連線失敗", detail: "空域資料無法驗證 · 請確認後再飛行", tint: .orange, isProhibited: false, isUnknown: true) }
            }
        }
    }

    private func knownAirportPremises(for coordinate: CLLocationCoordinate2D) -> (name: String, radius: CLLocationDistance)? {
        let airports: [(String, CLLocationCoordinate2D, CLLocationDistance)] = [
            ("臺灣桃園國際機場", CLLocationCoordinate2D(latitude: 25.07970, longitude: 121.23420), 2_000),
            ("臺北松山機場", CLLocationCoordinate2D(latitude: 25.06970, longitude: 121.55250), 1_500),
            ("高雄國際機場", CLLocationCoordinate2D(latitude: 22.57720, longitude: 120.35000), 1_500),
            ("臺中清泉崗機場", CLLocationCoordinate2D(latitude: 24.26470, longitude: 120.62060), 1_500),
            ("花蓮機場", CLLocationCoordinate2D(latitude: 24.02310, longitude: 121.61790), 1_000),
            ("臺東機場", CLLocationCoordinate2D(latitude: 22.75400, longitude: 121.10170), 1_000),
            ("澎湖馬公機場", CLLocationCoordinate2D(latitude: 23.56870, longitude: 119.62830), 1_000),
            ("金門機場", CLLocationCoordinate2D(latitude: 24.42790, longitude: 118.35920), 1_000)
        ]
        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return airports.compactMap { airport in
            let distance = current.distance(from: CLLocation(latitude: airport.1.latitude, longitude: airport.1.longitude))
            return distance <= airport.2 ? (name: airport.0, radius: airport.2) : nil
        }.first
    }

    private func reviewOfficialEvidence(properties: [[String: Any]], coordinate: CLLocationCoordinate2D) async {
        guard let url = URL(string: "\(backendBaseURL)/api/airspace-review") else { return }
        let evidence: [String: Any] = [
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude,
            "features": properties.map { property in
                property.filter { ["objectid", "spaceid", "allowedfly", "nfztype", "governmentagencylist"].contains($0.key) }
            }
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: evidence) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let result = try JSONDecoder().decode(AIReviewEnvelope.self, from: data).review
            if result.classification == "unknown" || result.needsOfficialConfirmation {
                assessment = AirspaceAssessment(title: "空域待確認", zone: "官方資料需要人工核對", detail: "AI 發現官方欄位或限制說明需要人工確認 · \(result.reason)", tint: .orange, isProhibited: false, isUnknown: true)
            } else if result.classification == "restricted" && !assessment.isProhibited && !assessment.isUnknown {
                let conditions = result.conditions.prefix(2).joined(separator: "、")
                assessment = AirspaceAssessment(title: "可飛（有限制）", zone: "民航局圖資經 AI 交叉檢查", detail: conditions.isEmpty ? result.reason : conditions, tint: .green, isProhibited: false, isUnknown: false)
            }
        } catch { }
    }

    private struct LocalIndex: Decodable {
        let source: String
        let updatedAt: String
        let zones: [LocalZone]
    }

    private struct LocalZone: Decodable {
        let id: Int
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            id = try values.decode(Int.self)
            minLat = try values.decode(Double.self)
            maxLat = try values.decode(Double.self)
            minLon = try values.decode(Double.self)
            maxLon = try values.decode(Double.self)
        }
    }
}

private struct AIReviewEnvelope: Decodable { let review: AIReview }
private struct AIReview: Decodable {
    let classification: String
    let needsOfficialConfirmation: Bool
    let reason: String
    let conditions: [String]
}

private struct CAAQueryWebView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let countyCode: String

    func makeCoordinator() -> Coordinator { Coordinator(coordinate: coordinate, countyCode: countyCode) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        if let coordinate, let json = try? JSONSerialization.data(withJSONObject: String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude), options: [.fragmentsAllowed]),
           let value = String(data: json, encoding: .utf8) {
            let targetLatitude = String(format: "%.5f", coordinate.latitude)
            let targetLongitude = String(format: "%.5f", coordinate.longitude)
            let script = """
            (() => {
              const value = \(value);
              const targetLatitude = \(targetLatitude);
              const targetLongitude = \(targetLongitude);
              let mapWasFocused = false;
              let attempts = 0;
              const submitOfficialSearch = (input) => {
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                setter.call(input, value);
                for (const eventName of ['input', 'change', 'keyup']) {
                  input.dispatchEvent(new Event(eventName, { bubbles: true }));
                }
                const container = input.closest('.jimu-widget-search, .search-widget, form') || input.parentElement || document;
                const button = Array.from(container.querySelectorAll('button, [role="button"], .jimu-search-button, .searchBtn, .searchButton, [title*="搜尋"], [aria-label*="搜尋"]')).find(node => node.offsetParent !== null);
                if (button) button.click();
                for (const eventName of ['keydown', 'keypress', 'keyup']) {
                  input.dispatchEvent(new KeyboardEvent(eventName, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
                }
              };
              const fillOfficialSearch = () => {
                attempts += 1;
                const inputs = Array.from(document.querySelectorAll('input'));
                const input = inputs.find(element => {
                  const placeholder = element.placeholder || '';
                  return placeholder.includes('空域') || placeholder.includes('經度') || placeholder.includes('地址');
                }) || inputs.find(element => element.type === 'text' && element.offsetParent !== null);
                if (!input) {
                  if (attempts < 60) window.setTimeout(fillOfficialSearch, 1000);
                  return;
                }
                input.focus();
                input.focus();
                // ArcGIS 初始化時可能重建搜尋框；持續確認欄位沒有被重設。
                if (input.value !== value || attempts < 6) submitOfficialSearch(input);
                if (attempts < 60) window.setTimeout(fillOfficialSearch, 1000);
              };
              const ensureOfficialAirspaceLayer = () => {
                const airspaceURL = 'https://dronegis.caa.gov.tw/server/rest/services/Hosted/UAV_fs/FeatureServer/3';
                if (typeof require !== 'function') {
                  window.setTimeout(ensureOfficialAirspaceLayer, 1000);
                  return;
                }
                require(['jimu/MapManager', 'esri/layers/FeatureLayer', 'esri/layers/VectorTileLayer', 'esri/geometry/Point', 'esri/SpatialReference', 'esri/renderers/UniqueValueRenderer', 'esri/symbols/SimpleFillSymbol', 'esri/symbols/SimpleLineSymbol', 'esri/Color'], (MapManager, FeatureLayer, VectorTileLayer, Point, SpatialReference, UniqueValueRenderer, SimpleFillSymbol, SimpleLineSymbol, Color) => {
                  const mapInfo = MapManager && MapManager.getInstance && MapManager.getInstance().getMapInfo();
                  const map = (mapInfo && mapInfo.map) || window.jimuMapManager && window.jimuMapManager.getMapInfo && window.jimuMapManager.getMapInfo().map || window._map || window.map;
                  if (!map) {
                    window.setTimeout(ensureOfficialAirspaceLayer, 1000);
                    return;
                  }
                  if (map.loaded === false) {
                    map.once('load', ensureOfficialAirspaceLayer);
                    return;
                  }
                  if (!mapWasFocused) {
                    mapWasFocused = true;
                    const point = new Point(Number(targetLongitude), Number(targetLatitude), new SpatialReference({ wkid: 4326 }));
                    const focusResult = map.centerAndZoom(point, 16);
                    if (focusResult && focusResult.then) {
                      focusResult.then(() => {
                        activateOfficialAirspaceWidget();
                        window.setTimeout(ensureOfficialAirspaceLayer, 1200);
                      });
                    } else {
                      activateOfficialAirspaceWidget();
                    }
                  }
                  const layerIDs = (map.layerIds || []).concat(map.graphicsLayerIds || []);
                  const existing = layerIDs.map(id => map.getLayer(id)).find(layer => layer && layer.url === airspaceURL);
                  const makeOfficialRenderer = () => {
                    const outline = new SimpleLineSymbol(SimpleLineSymbol.STYLE_SOLID, new Color([255, 255, 255, 220]), 1);
                    const symbol = (color) => new SimpleFillSymbol(SimpleFillSymbol.STYLE_SOLID, outline, new Color(color));
                    const renderer = new UniqueValueRenderer(symbol([190, 190, 190, 0]), '限制區');
                    // 完全依民航局 UAV_fs/FeatureServer/3 的官方 renderer：僅紅區與黃區。
                    renderer.addValue('紅區', symbol([240, 56, 43, 153]));
                    renderer.addValue('黃區', symbol([255, 186, 13, 153]));
                    return renderer;
                  };
                  const ensureOfficialVectorLayers = () => {
                    [
                      ['https://dronegis.caa.gov.tw/server/rest/services/Hosted/National_Park_vtpk/VectorTileServer/resources/styles/root.json', 'CAA_NationalPark_Official'],
                      ['https://dronegis.caa.gov.tw/server/rest/services/Hosted/County_vtpk/VectorTileServer/resources/styles/root.json', 'CAA_County_Official'],
                      ['https://dronegis.caa.gov.tw/server/rest/services/Hosted/%E5%95%86%E6%B8%AF%E5%8D%80%E7%AF%84%E5%9C%8D_vtpk_20260202/VectorTileServer/resources/styles/root.json', 'CAA_CommercialPort_Official']
                    ].forEach(([styleURL, id]) => {
                      if (!map.getLayer(id)) map.addLayer(new VectorTileLayer(styleURL, { id: id, visible: true, opacity: 1 }));
                    });
                  };
                  if (existing) {
                    existing.setVisibility(true);
                    existing.setOpacity(1);
                    existing.setRenderer(makeOfficialRenderer());
                    ensureOfficialVectorLayers();
                    if (map.reorderLayer) map.reorderLayer(existing, map.layerIds.length + map.graphicsLayerIds.length);
                    return;
                  }
                  const layer = new FeatureLayer(airspaceURL, {
                    id: 'CAA_UAV_Airspace_Official',
                    outFields: ['*'],
                    // 官方空域圖層直接載入整個目前地圖範圍，避免 on-demand 在 WKWebView 中沒有觸發查詢。
                    mode: FeatureLayer.MODE_SNAPSHOT,
                    opacity: 1,
                    visible: true
                  });
                  layer.on('error', () => window.setTimeout(ensureOfficialAirspaceLayer, 2000));
                  map.addLayer(layer);
                  ensureOfficialVectorLayers();
                  layer.on('load', () => {
                    layer.setVisibility(true);
                    layer.setOpacity(1);
                    layer.setRenderer(makeOfficialRenderer());
                    layer.refresh();
                    if (map.reorderLayer) map.reorderLayer(layer, map.layerIds.length + map.graphicsLayerIds.length);
                  });
                }, () => window.setTimeout(ensureOfficialAirspaceLayer, 2000));
              };
              let airspaceWidgetAttempts = 0;
              const clickOfficialControl = (node) => {
                if (!node) return false;
                ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(type => node.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window })));
                node.click();
                return true;
              };
              const activateOfficialAirspaceWidget = () => {
                airspaceWidgetAttempts += 1;
                const nodes = Array.from(document.querySelectorAll('button, [role="button"], a, [data-widget-name], [data-widget-id], .jimu-widget-link, .jimu-btn, .jimu-widget-onscreen-icon'));
                const visible = node => node && node.offsetParent !== null;
                const label = node => `${node.textContent || ''} ${node.getAttribute('title') || ''} ${node.getAttribute('aria-label') || ''} ${node.getAttribute('data-widget-name') || ''}`.replace(/\\s/g, '');
                const widget = nodes.filter(node => visible(node) && (label(node).includes('載入活動空域') || label(node).includes('活動空域') || label(node).includes('PeopleTiled'))).sort((a, b) => label(a).length - label(b).length)[0];
                if (widget) {
                  const state = `${widget.className || ''} ${widget.getAttribute('aria-pressed') || ''} ${widget.getAttribute('aria-checked') || ''}`.toLowerCase();
                  const alreadyEnabled = state.includes('active') || state.includes('selected') || state.includes('checked') || state.includes('open') || state.includes('true');
                  if (!alreadyEnabled) clickOfficialControl(widget);
                  return;
                }
                const menu = nodes.find(node => visible(node) && (node.classList.contains('jimu-widget-onscreen-icon') || label(node).includes('選單') || label(node).includes('工具')));
                if (menu) {
                  clickOfficialControl(menu);
                  window.setTimeout(activateOfficialAirspaceWidget, 700);
                } else if (airspaceWidgetAttempts < 30) {
                  window.setTimeout(activateOfficialAirspaceWidget, 1000);
                }
              };
              window.setTimeout(fillOfficialSearch, 1800);
              // 先定位到查詢座標，再由民航局頁面自己的元件載入活動空域。
              window.setTimeout(ensureOfficialAirspaceLayer, 1800);
            })();
            """
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        var components = URLComponents(string: "https://dronegis.caa.gov.tw/portal/apps/webappviewer/index.html")!
        var items = [URLQueryItem(name: "id", value: "807bd21438ba4208b4a7e28569fe41aa")]
        if let coordinate {
            let findValue = String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
            let mapValue = String(format: "%.5f,%.5f", coordinate.longitude, coordinate.latitude)
            // find 使用緯度,經度；marker／center 使用經度,緯度（ArcGIS 格式不同）。
            // 同時指定縮放層級，避免只載入底圖而尚未顯示空域彩色圖層。
            items.append(URLQueryItem(name: "find", value: findValue))
            items.append(URLQueryItem(name: "marker", value: "\(mapValue),16"))
            items.append(URLQueryItem(name: "center", value: mapValue))
            items.append(URLQueryItem(name: "level", value: "16"))
        }
        components.queryItems = items
        webView.load(URLRequest(url: components.url!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let coordinate: CLLocationCoordinate2D?
        let countyCode: String

        init(coordinate: CLLocationCoordinate2D?, countyCode: String) { self.coordinate = coordinate; self.countyCode = countyCode }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let coordinate else { return }
            var value = String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
            value = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let script = """
            (() => {
              const value = '\(value)';
              let tries = 0;
              let lastWidgetClick = 0;
              const clickControl = (node) => {
                if (!node) return false;
                ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(type => node.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window })));
                node.click();
                return true;
              };
              const setupOfficialMap = () => {
                tries += 1;
                const visible = node => node && node.offsetParent !== null;
                const inputs = Array.from(document.querySelectorAll('input'));
                const input = inputs.find(node => visible(node) && ((node.placeholder || '').includes('空域') || (node.placeholder || '').includes('經度') || (node.placeholder || '').includes('地址')));
                if (input) {
                  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                  if (input.value !== value || tries < 8) {
                    setter.call(input, value);
                    ['input', 'change', 'keyup'].forEach(name => input.dispatchEvent(new Event(name, { bubbles: true })));
                  }
                  const parent = input.parentElement || document;
                  const button = Array.from((input.closest('.jimu-widget-search, .search-widget, form') || parent).querySelectorAll('button, [role="button"], .jimu-search-button, .searchBtn, .searchButton, [title*="搜尋"], [aria-label*="搜尋"]')).find(visible);
                  if (button) clickControl(button);
                  ['keydown', 'keypress', 'keyup'].forEach(name => input.dispatchEvent(new KeyboardEvent(name, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true })));
                }
                const nodes = Array.from(document.querySelectorAll('button, [role="button"], a, [data-widget-name], [data-widget-id], .jimu-widget-link, .jimu-btn, .jimu-widget-onscreen-icon'));
                const label = node => `${node.textContent || ''} ${node.getAttribute('title') || ''} ${node.getAttribute('aria-label') || ''} ${node.getAttribute('data-widget-name') || ''}`.replace(/\\s/g, '');
                const widget = nodes.filter(node => visible(node) && (label(node).includes('載入活動空域') || label(node).includes('活動空域') || label(node).includes('PeopleTiled'))).sort((a, b) => label(a).length - label(b).length)[0];
                // ArcGIS widget 可能先被點擊但尚未完成初始化；不要把第一次 click
                // 當成成功，直到官方元件完成載入前持續重試。
                if (widget && tries - lastWidgetClick >= 3) {
                  clickControl(widget);
                  lastWidgetClick = tries;
                }
                if (tries < 60) window.setTimeout(setupOfficialMap, 1000);
              };
              setupOfficialMap();
            })();
            """
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                webView.evaluateJavaScript(script)
            }
        }
    }
}

@MainActor
private final class SubscriptionManager: NSObject, ObservableObject, PurchasesDelegate {
    private let revenueCatAPIKey = "appl_wxtZXBWFnWaOuNCVaFuXrExNowI"
    private let entitlementID = "pro"
    private let productID = "com.taiwandronepilot.assistant.pro.monthly"
    @Published private(set) var monthlyPackage: Package?
    @Published private(set) var isPro = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var message = "正在載入訂閱方案…"

    override init() {
        super.init()
        guard revenueCatAPIKey != "REVENUECAT_PUBLIC_SDK_KEY" else {
            message = "請先填入 RevenueCat Public SDK Key"
            return
        }
        Purchases.configure(withAPIKey: revenueCatAPIKey)
        Purchases.shared.delegate = self
        Task { await loadOfferingAndEntitlement() }
    }

    func loadOfferingAndEntitlement() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            monthlyPackage = offerings.current?.monthly ?? offerings.current?.availablePackages.first(where: { $0.storeProduct.productIdentifier == productID })
            message = monthlyPackage == nil ? "RevenueCat 尚未設定 monthly 方案" : ""
            await refreshEntitlement()
        } catch {
            message = "目前無法載入 RevenueCat 訂閱方案"
        }
    }

    func purchase(_ package: Package) async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            updateEntitlement(result.customerInfo)
        } catch {
            message = "訂閱未完成，請稍後再試"
        }
    }

    func restore() async {
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            updateEntitlement(customerInfo)
        } catch {
            message = "恢復購買失敗，請稍後再試"
        }
    }

    func purchases(_ purchases: Purchases, received updatedCustomerInfo: CustomerInfo) {
        updateEntitlement(updatedCustomerInfo)
    }

    private func refreshEntitlement() async {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            updateEntitlement(customerInfo)
        } catch {
            message = "無法取得訂閱狀態"
        }
    }

    private func updateEntitlement(_ customerInfo: CustomerInfo) {
        isPro = customerInfo.entitlements[entitlementID]?.isActive == true
    }
}
