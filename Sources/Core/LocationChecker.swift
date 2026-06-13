import Foundation
import CoreLocation

/// 定位检测模块 — 检测当前位置是否在福州大学晋江校区附近
public final class LocationChecker: NSObject, CLLocationManagerDelegate {
    private let config: Config
    private let manager = CLLocationManager()
    private var _continuation: CheckedContinuation<LocationResult, Never>?
    private let continuationLock = NSLock()  // 防 delegate/超时竞速

    public enum LocationResult {
        case inRange(distance: Double)
        case outOfRange(distance: Double)
        case failed(String)
    }

    public init(config: Config) {
        self.config = config
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 原子地取走并清空 continuation，防止 delegate 和超时同时 resume
    private func takeContinuation() -> CheckedContinuation<LocationResult, Never>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let c = _continuation
        _continuation = nil
        return c
    }

    /// 检查当前位置是否在校园范围内
    public func checkIfNearCampus() async -> LocationResult {
        // 检查定位权限
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // 等待权限弹窗响应（用户操作需要时间）
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        case .denied, .restricted:
            return .failed("定位权限被拒绝，请在系统设置中允许定位")
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            continuationLock.lock()
            self._continuation = continuation
            continuationLock.unlock()
            manager.startUpdatingLocation()

            // 超时处理
            Task {
                try? await Task.sleep(nanoseconds: UInt64(config.locationTimeout * 1_000_000_000))
                if let c = self.takeContinuation() {
                    manager.stopUpdatingLocation()
                    c.resume(returning: .failed("超时"))
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }

        // 忽略缓存的位置（超过 5 分钟的旧数据）
        if -location.timestamp.timeIntervalSinceNow > 300 { return }

        // 精度太差，继续等待
        if location.horizontalAccuracy > 100 { return }

        manager.stopUpdatingLocation()

        let distance = haversineDistance(
            lat1: location.coordinate.latitude,
            lon1: location.coordinate.longitude,
            lat2: config.campusLatitude,
            lon2: config.campusLongitude
        )

        let result: LocationResult
        if distance <= config.radiusMeters {
            result = .inRange(distance: distance)
            Logger.success("定位成功: 距离校区 \(String(format: "%.0f", distance)) 米，在范围内")
        } else {
            result = .outOfRange(distance: distance)
            Logger.info("定位成功: 距离校区 \(String(format: "%.0f", distance)) 米，不在范围内")
        }

        if let c = takeContinuation() { c.resume(returning: result) }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        Logger.error("定位失败: \(error.localizedDescription)")
        if let c = takeContinuation() { c.resume(returning: .failed("定位失败")) }
    }

    // MARK: - Haversine 公式计算两点间距离

    /// 使用 Haversine 公式计算地球表面两点间距离（米）
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0 // 米
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
