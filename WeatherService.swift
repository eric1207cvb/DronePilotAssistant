import Foundation
import CoreLocation
import MapKit
import Combine

struct WeatherSnapshot {
    var condition = "多雲"
    var temperature = "−1°C"
    var windSpeed = "8 km/h"
    var windMetersPerSecond = "2.2 m/s"
    var windLevel = "蒲福風級 2級"
    var kp = "—"
    var sunrise = "—"
    var sunset = "—"
    var visibility = "—"
    var windDirection = "南"
    var rainChance = "10%"
    var lastUpdated = "示範資料"
}

struct ForecastDay: Identifiable {
    let id: String
    let day: String
    let icon: String?
    let temperature: String?
    let rain: String?
    let hourly: [ForecastHour]
}

struct ForecastHour: Identifiable {
    let id: String
    let time: String
    let temperature: String?
    let wind: String?
    let windLevel: String?
    let rain: String?
}

struct WindForecastPoint: Identifiable {
    let id: String
    let time: String
    let speed: Int
}

@MainActor
final class WeatherService: ObservableObject {
    @Published private(set) var snapshot = WeatherSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var isResolvingLocation = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var forecast: [ForecastDay] = []
    @Published private(set) var windForecast: [WindForecastPoint] = []
    @Published private(set) var queriedCoordinate: CLLocationCoordinate2D?
    // 每次查詢都遞增，包含命中快取的查詢；避免第二次相同地點沒有 UI 更新事件。
    @Published private(set) var queryID = 0

    // 開發測試用；正式上線請改由你的後端代理呼叫 CWA，勿把授權碼放在 App。
    private let authorization = "CWA-64CB9B73-8F58-444D-AA26-12D0EA03A244"
    private var lastRequest: Date?
    private var lastCoordinate: CLLocationCoordinate2D?
    private var task: Task<Void, Never>?

    var isBusy: Bool { isResolvingLocation || isLoading }

    private var backendBaseURL: String {
        return "http://127.0.0.1:8000"
    }

    func load(coordinate: CLLocationCoordinate2D) {
        queriedCoordinate = coordinate
        queryID += 1
        if let lastRequest, Date().timeIntervalSince(lastRequest) < 600, let lastCoordinate, CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 1000 {
            errorMessage = nil
            return
        }
        task?.cancel()
        isLoading = true
        task = Task { await request(coordinate: coordinate) }
    }

    func search(text: String) {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) {
            load(coordinate: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]))
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = "請輸入地址或地標"
            return
        }
        task?.cancel()
        isResolvingLocation = true
        task = Task {
            defer { isResolvingLocation = false }
            do {
                // 文字地點先由 iPhone 本機 MapKit 定位，避免實體裝置依賴
                // 區網 Mac 的 /api/assistant-query；GPT 僅保留為非必要的手動備援。
                let assistant: AssistantQuery? = nil
                let assistantQuery = assistant?.normalizedQuery.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let canonicalPlaceName = assistant?.canonicalPlaceName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let routedQuery = canonicalPlaceName.isEmpty ? (assistantQuery.isEmpty ? query : assistantQuery) : canonicalPlaceName

                // 先處理高辨識度官方地標，避免「總統府」被模糊解析到其他縣市。
                if routedQuery.replacingOccurrences(of: "臺", with: "台").contains("總統府") {
                    load(coordinate: CLLocationCoordinate2D(latitude: 25.04006, longitude: 121.51980))
                    return
                }
                // 機場是高風險地標，不能接受 MapKit 將查詢詞配到附近里鄰的結果。
                // 使用官方地標中心附近座標，再交由民航局圖資判定禁限航狀態。
                let airportCoordinates: [(String, CLLocationCoordinate2D)] = [
                    ("桃園機場", CLLocationCoordinate2D(latitude: 25.07970, longitude: 121.23420)),
                    ("桃園國際機場", CLLocationCoordinate2D(latitude: 25.07970, longitude: 121.23420)),
                    ("臺灣桃園國際機場", CLLocationCoordinate2D(latitude: 25.07970, longitude: 121.23420)),
                    ("松山機場", CLLocationCoordinate2D(latitude: 25.06970, longitude: 121.55250)),
                    ("高雄機場", CLLocationCoordinate2D(latitude: 22.57720, longitude: 120.35000)),
                    ("台中機場", CLLocationCoordinate2D(latitude: 24.26470, longitude: 120.62060)),
                    ("臺中機場", CLLocationCoordinate2D(latitude: 24.26470, longitude: 120.62060)),
                    ("清泉崗機場", CLLocationCoordinate2D(latitude: 24.26470, longitude: 120.62060)),
                    ("花蓮機場", CLLocationCoordinate2D(latitude: 24.02310, longitude: 121.61790)),
                    ("臺東機場", CLLocationCoordinate2D(latitude: 22.75400, longitude: 121.10170)),
                    ("台東機場", CLLocationCoordinate2D(latitude: 22.75400, longitude: 121.10170)),
                    ("豐年機場", CLLocationCoordinate2D(latitude: 22.75400, longitude: 121.10170)),
                    ("澎湖機場", CLLocationCoordinate2D(latitude: 23.56870, longitude: 119.62830)),
                    ("馬公機場", CLLocationCoordinate2D(latitude: 23.56870, longitude: 119.62830)),
                    ("金門尚義機場", CLLocationCoordinate2D(latitude: 24.42790, longitude: 118.35920)),
                    ("尚義機場", CLLocationCoordinate2D(latitude: 24.42790, longitude: 118.35920)),
                    ("金門機場", CLLocationCoordinate2D(latitude: 24.42790, longitude: 118.35920))
                ]
                let normalizedAirportQuery = routedQuery.replacingOccurrences(of: "臺", with: "台")
                if let match = airportCoordinates.first(where: { normalizedAirportQuery.contains($0.0.replacingOccurrences(of: "臺", with: "台")) }) {
                    load(coordinate: match.1)
                    return
                }
                let taiwan = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.95),
                    span: MKCoordinateSpan(latitudeDelta: 4.5, longitudeDelta: 6.5)
                )
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = routedQuery
                request.region = taiwan
                request.resultTypes = [.address, .pointOfInterest]
                let response = try await MKLocalSearch(request: request).start()
                let normalized = routedQuery.replacingOccurrences(of: "臺", with: "台")
                let item = response.mapItems.first(where: { item in
                    let name = (item.name ?? "").replacingOccurrences(of: "臺", with: "台")
                    return name.localizedCaseInsensitiveContains(normalized)
                }) ?? response.mapItems.first
                if let coordinate = item?.placemark.coordinate,
                   (21...26).contains(coordinate.latitude), (117...123).contains(coordinate.longitude) {
                    load(coordinate: coordinate)
                } else {
                    await braveFallback(query: routedQuery)
                }
            } catch {
                if !Task.isCancelled { await braveFallback(query: query) }
            }
        }
    }

    private func assistantNormalize(_ query: String) async -> AssistantQuery? {
        guard let url = URL(string: "\(backendBaseURL)/api/assistant-query"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(AssistantQueryEnvelope.self, from: data).assistant
        } catch {
            return nil
        }
    }

    private func braveFallback(query: String) async {
        guard var components = URLComponents(string: "\(backendBaseURL)/api/place-search") else {
            errorMessage = "找不到這個地點"
            return
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let result = try JSONDecoder().decode(BravePlaceResponse.self, from: data)
            guard let candidate = result.results.first else { throw URLError(.cannotParseResponse) }
            let placemarks = try await CLGeocoder().geocodeAddressString("\(candidate.title) \(candidate.description)")
            guard let coordinate = placemarks.first?.location?.coordinate,
                  (21...26).contains(coordinate.latitude), (117...123).contains(coordinate.longitude) else { throw URLError(.cannotFindHost) }
            load(coordinate: coordinate)
        } catch {
            if !Task.isCancelled { errorMessage = "找不到台灣境內的這個地點" }
        }
    }

    private func request(coordinate: CLLocationCoordinate2D) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        // F-D0047-089 是 CWA「鄉鎮天氣預報－台灣未來 3 天」全台資料集。
        // 全台統一使用它，避免桃園機場等台北以外位置誤用不相容的資料集。
        let resourceID = "F-D0047-089"
        var components = URLComponents(string: "https://opendata.cwa.gov.tw/api/v1/rest/datastore/\(resourceID)")!
        components.queryItems = [URLQueryItem(name: "format", value: "JSON")]
        do {
            var request = URLRequest(url: components.url!)
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "CWA", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
            }
            let decoded = try JSONDecoder().decode(CWAResponse.self, from: data)
            let locations = decoded.records.locations.flatMap(\.location)
            guard let matched = locations.min(by: { distance(from: coordinate, to: $0) < distance(from: coordinate, to: $1) }) else { throw URLError(.cannotParseResponse) }
            let values = matched.weatherElement
            let metersPerSecond = Double(weatherValue(values, names: ["風速"]) ?? "") ?? 0
            let kmh = (metersPerSecond * 3.6).formatted(.number.precision(.fractionLength(0)))
            let beaufort = weatherValue(values, names: ["蒲福風級"]) ?? "—"
            snapshot = WeatherSnapshot(condition: weatherValue(values, names: ["天氣現象", "天氣預報綜合描述"]) ?? "—", temperature: (weatherValue(values, names: ["平均溫度", "溫度"]) ?? "—") + "°C", windSpeed: kmh + " km/h", windMetersPerSecond: metersPerSecond.formatted(.number.precision(.fractionLength(1))) + " m/s", windLevel: "蒲福風級 \(beaufort)級", windDirection: weatherValue(values, names: ["風向"]) ?? "—", rainChance: (weatherValue(values, names: ["降雨機率", "3小時降雨機率", "12小時降雨機率"]) ?? "—") + "%", lastUpdated: "CWA 全台 · 剛剛")
            forecast = makeForecast(values)
            windForecast = makeWindForecast(values)
            let sunTimes = await fetchSunTimes(coordinate: coordinate, authorization: authorization)
            snapshot.sunrise = sunTimes.sunrise
            snapshot.sunset = sunTimes.sunset
            snapshot.visibility = await fetchVisibility(coordinate: coordinate, authorization: authorization)
            snapshot.kp = await fetchKp()
            if forecast.isEmpty { errorMessage = "CWA 已回應，但沒有可用的預報時段" }
            lastRequest = Date(); lastCoordinate = coordinate
        } catch {
            if !Task.isCancelled { errorMessage = "CWA 暫時無法取得：\(error.localizedDescription)" }
        }
    }
}

private struct NOAAKpRow: Decodable {
    let kpIndex: Double?
    let estimatedKp: Double?

    enum CodingKeys: String, CodingKey {
        case kpIndex = "kp_index"
        case estimatedKp = "estimated_kp"
    }
}

private func fetchKp() async -> String {
    guard let url = URL(string: "https://services.swpc.noaa.gov/json/planetary_k_index_1m.json") else { return "—" }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return "—" }

        let rows = try JSONDecoder().decode([NOAAKpRow].self, from: data)
        for row in rows.reversed() {
            if let kpIndex = row.kpIndex {
                return kpIndex.formatted(.number.precision(.fractionLength(0)))
            }
            if let estimatedKp = row.estimatedKp {
                return estimatedKp.formatted(.number.precision(.fractionLength(1)))
            }
        }
    } catch { }
    return "—"
}

private struct CWAResponse: Decodable { let records: Records }

private struct SunResponse: Decodable { let records: SunRecords }
private struct SunRecords: Decodable { let locations: SunLocations; enum CodingKeys: String, CodingKey { case locations = "locations" } }
private struct SunLocations: Decodable { let location: [SunLocation]; enum CodingKeys: String, CodingKey { case location = "location" } }
private struct SunLocation: Decodable { let countyName: String; let time: [SunTime]; enum CodingKeys: String, CodingKey { case countyName = "CountyName"; case time = "time" } }
private struct SunTime: Decodable { let date: String; let sunrise: String; let sunset: String; enum CodingKeys: String, CodingKey { case date = "Date"; case sunrise = "SunRiseTime"; case sunset = "SunSetTime" } }

private struct VisibilityResponse: Decodable { let records: VisibilityRecords }
private struct VisibilityRecords: Decodable { let stations: [VisibilityStation]; enum CodingKeys: String, CodingKey { case stations = "Station" } }
private struct VisibilityStation: Decodable { let geoInfo: VisibilityGeoInfo; let weather: VisibilityWeather; enum CodingKeys: String, CodingKey { case geoInfo = "GeoInfo"; case weather = "WeatherElement" } }
private struct VisibilityGeoInfo: Decodable { let coordinates: [VisibilityCoordinate]; enum CodingKeys: String, CodingKey { case coordinates = "Coordinates" } }
private struct VisibilityCoordinate: Decodable { let name: String?; let latitude: String?; let longitude: String?; enum CodingKeys: String, CodingKey { case name = "CoordinateName"; case latitude = "StationLatitude"; case longitude = "StationLongitude" } }
private struct VisibilityWeather: Decodable { let description: String?; enum CodingKeys: String, CodingKey { case description = "VisibilityDescription" } }

private struct BravePlaceResponse: Decodable { let results: [BravePlaceResult] }
private struct BravePlaceResult: Decodable { let title: String; let description: String }
private struct AssistantQueryEnvelope: Decodable { let assistant: AssistantQuery }
private struct AssistantQuery: Decodable {
    let normalizedQuery: String
    let canonicalPlaceName: String
    let queryType: String
    let highRiskPlace: Bool
    let confidence: String
    let requiresOfficialAirspaceCheck: Bool
    let note: String
}
private struct Records: Decodable { let locations: [Locations]; enum CodingKeys: String, CodingKey { case locations = "Locations" } }
private struct Locations: Decodable { let location: [Location]; enum CodingKeys: String, CodingKey { case location = "Location" } }
private struct Location: Decodable { let latitude: String?; let longitude: String?; let weatherElement: [Element]; enum CodingKeys: String, CodingKey { case latitude = "Latitude"; case longitude = "Longitude"; case weatherElement = "WeatherElement" } }
private struct Element: Decodable { let elementName: String; let time: [TimeValue]; enum CodingKeys: String, CodingKey { case elementName = "ElementName"; case time = "Time" } }
private struct TimeValue: Decodable { let dataTime: String?; let startTime: String?; let elementValue: [ElementValue]; enum CodingKeys: String, CodingKey { case dataTime = "DataTime"; case startTime = "StartTime"; case elementValue = "ElementValue" } }
private struct ElementValue: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        value = container.allKeys.lazy.compactMap { try? container.decode(String.self, forKey: $0) }.first
    }
}
private struct AnyCodingKey: CodingKey {
    let stringValue: String; let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func weatherValue(_ elements: [Element], names: [String]) -> String? { for name in names { if let element = elements.first(where: { $0.elementName == name }), let value = element.time.first?.elementValue.first?.value, !value.isEmpty { return value } }; return nil }

private func fetchSunTimes(coordinate: CLLocationCoordinate2D, authorization: String) async -> (sunrise: String, sunset: String) {
    let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
    guard var county = placemark?.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines), !county.isEmpty else { return ("—", "—") }
    county = county.replacingOccurrences(of: "台", with: "臺")

    var components = URLComponents(string: "https://opendata.cwa.gov.tw/api/v1/rest/datastore/A-B0062-001")!
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
    formatter.dateFormat = "yyyy-MM-dd"
    components.queryItems = [
        URLQueryItem(name: "format", value: "JSON"),
        URLQueryItem(name: "CountyName", value: county),
        URLQueryItem(name: "Date", value: formatter.string(from: Date()))
    ]

    do {
        var request = URLRequest(url: components.url!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return ("—", "—") }
        let decoded = try JSONDecoder().decode(SunResponse.self, from: data)
        guard let row = decoded.records.locations.location.first else { return ("—", "—") }
        return (row.time.first?.sunrise ?? "—", row.time.first?.sunset ?? "—")
    } catch {
        return ("—", "—")
    }
}

private func fetchVisibility(coordinate: CLLocationCoordinate2D, authorization: String) async -> String {
    var components = URLComponents(string: "https://opendata.cwa.gov.tw/api/v1/rest/datastore/O-A0003-001")!
    components.queryItems = [URLQueryItem(name: "format", value: "JSON")]
    do {
        var request = URLRequest(url: components.url!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return "—" }
        let decoded = try JSONDecoder().decode(VisibilityResponse.self, from: data)
        let nearest = decoded.records.stations.min { lhs, rhs in
            stationDistance(lhs, from: coordinate) < stationDistance(rhs, from: coordinate)
        }
        guard let raw = nearest?.weather.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "-99", raw != "X" else { return "—" }
        return raw.hasSuffix("km") ? raw : "\(raw) km"
    } catch {
        return "—"
    }
}

private func stationDistance(_ station: VisibilityStation, from coordinate: CLLocationCoordinate2D) -> Double {
    let position = station.geoInfo.coordinates.first(where: { $0.name == "WGS84" }) ?? station.geoInfo.coordinates.first
    guard let latitude = position?.latitude.flatMap(Double.init), let longitude = position?.longitude.flatMap(Double.init) else { return .greatestFiniteMagnitude }
    let lat = (coordinate.latitude - latitude) * 111_000
    let lon = (coordinate.longitude - longitude) * 102_000
    return (lat * lat + lon * lon).squareRoot()
}

private func distance(from coordinate: CLLocationCoordinate2D, to location: Location) -> Double {
    guard let latitude = location.latitude.flatMap(Double.init), let longitude = location.longitude.flatMap(Double.init) else { return .greatestFiniteMagnitude }
    let lat = (coordinate.latitude - latitude) * 111_000
    let lon = (coordinate.longitude - longitude) * 102_000
    return (lat * lat + lon * lon).squareRoot()
}

private func makeWindForecast(_ elements: [Element]) -> [WindForecastPoint] {
    guard let element = elements.first(where: { $0.elementName == "風速" }) else { return [] }
    let parser = ISO8601DateFormatter()
    let display = DateFormatter(); display.locale = Locale(identifier: "zh_TW"); display.dateFormat = "MM/dd HH:mm"
    return element.time.compactMap { item in
        let rawTime = item.dataTime ?? item.startTime
        guard let rawTime, let date = parser.date(from: rawTime), let meters = Double(item.elementValue.first?.value ?? "") else { return nil }
        return WindForecastPoint(id: rawTime, time: display.string(from: date), speed: Int((meters * 3.6).rounded()))
    }.prefix(24).map { $0 }
}

private func makeForecast(_ elements: [Element]) -> [ForecastDay] {
    var buckets: [String: (date: Date, temps: [Double], rain: String?, weather: String?)] = [:]
    let formatter = ISO8601DateFormatter()
    for element in elements {
        for item in element.time {
            guard let dateTime = item.dataTime ?? item.startTime, let date = formatter.date(from: dateTime), let raw = item.elementValue.first?.value else { continue }
            let key = ISO8601DateFormatter().string(from: date).prefix(10).description
            var bucket = buckets[key] ?? (date, [], nil, nil)
            if let value = Double(raw), element.elementName.contains("溫度") { bucket.temps.append(value) }
            if element.elementName.contains("降雨機率") { bucket.rain = raw }
            if element.elementName.contains("天氣現象") || element.elementName.contains("天氣描述") { bucket.weather = raw }
            buckets[key] = bucket
        }
    }
    let hourly = makeHourlyForecast(elements)
    return buckets.values.sorted { $0.date < $1.date }.prefix(7).compactMap { bucket in
        let label = bucket.date.formatted(.dateTime.weekday(.abbreviated))
        let range = bucket.temps.isEmpty ? nil : "\(Int(bucket.temps.min()!.rounded()))° / \(Int(bucket.temps.max()!.rounded()))°C"
        let dayKey = ISO8601DateFormatter().string(from: bucket.date).prefix(10).description
        let hours = hourly.filter { $0.id.hasPrefix(dayKey) }
        guard range != nil || bucket.weather != nil || bucket.rain != nil || !hours.isEmpty else { return nil }
        return ForecastDay(id: bucket.date.ISO8601Format(), day: label, icon: forecastIcon(bucket.weather), temperature: range, rain: bucket.rain.map { "\($0)%" }, hourly: hours)
    }
}

private func forecastIcon(_ weather: String?) -> String? {
    guard let weather, !weather.isEmpty else { return nil }
    if weather.contains("雨") { return "🌧" }
    if weather.contains("晴") { return "☀" }
    return "☁"
}

private func makeHourlyForecast(_ elements: [Element]) -> [ForecastHour] {
    struct Bucket { var date: Date; var temperature: String?; var wind: Double?; var windLevel: String?; var rain: String? }
    var buckets: [String: Bucket] = [:]
    let formatter = ISO8601DateFormatter()
    let display = DateFormatter(); display.locale = Locale(identifier: "zh_TW"); display.dateFormat = "MM/dd HH:mm"
    for element in elements {
        for item in element.time {
            guard let raw = item.dataTime ?? item.startTime, let date = formatter.date(from: raw), let value = item.elementValue.first?.value, !value.isEmpty else { continue }
            var bucket = buckets[raw] ?? Bucket(date: date, temperature: nil, wind: nil, windLevel: nil, rain: nil)
            if element.elementName.contains("溫度") { bucket.temperature = "\(value)°C" }
            else if element.elementName == "風速", let number = Double(value) { bucket.wind = number }
            else if element.elementName.contains("蒲福") { bucket.windLevel = value }
            else if element.elementName.contains("降雨機率") { bucket.rain = "\(value)%" }
            buckets[raw] = bucket
        }
    }
    return buckets.values.sorted { $0.date < $1.date }.prefix(24).compactMap { bucket in
        guard bucket.temperature != nil || bucket.wind != nil || bucket.windLevel != nil || bucket.rain != nil else { return nil }
        let wind = bucket.wind.map { "\($0.formatted(.number.precision(.fractionLength(1)))) m/s · \(($0 * 3.6).formatted(.number.precision(.fractionLength(0)))) km/h" }
        return ForecastHour(id: ISO8601DateFormatter().string(from: bucket.date), time: display.string(from: bucket.date), temperature: bucket.temperature, wind: wind, windLevel: bucket.windLevel, rain: bucket.rain)
    }
}
