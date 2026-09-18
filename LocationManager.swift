import CoreLocation
import Combine
import Foundation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var horizontalAccuracy: CLLocationAccuracy?
    @Published var statusMessage = "尚未定位"
    @Published private(set) var isRequesting = false
    @Published private(set) var updateID = 0

    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func requestLocation() {
        if authorization == .notDetermined {
            isRequesting = true
            statusMessage = "等待定位權限…"
            manager.requestWhenInUseAuthorization()
            return
        }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            isRequesting = false
            statusMessage = "尚未允許定位權限"
            return
        }
        isRequesting = true
        statusMessage = "定位中（GPS／Wi‑Fi／基地台由 iOS 自動選擇）"
        manager.requestLocation()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authorization = status
        if status == .authorizedWhenInUse || status == .authorizedAlways { requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        horizontalAccuracy = location.horizontalAccuracy
        updateID += 1
        isRequesting = false
        statusMessage = "定位成功（iPhone Core Location）"
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isRequesting = false
        statusMessage = "定位暫時失敗：請確認 GPS／Wi‑Fi／行動網路"
    }
}
