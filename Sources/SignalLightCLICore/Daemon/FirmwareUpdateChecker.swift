import Foundation
import SignalLightKit

/// Result of checking whether newer firmware is published for a given board.
enum FirmwareUpdateAvailability {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, notes: String?)
}

enum FirmwareCheckError: Error, CustomStringConvertible {
    case malformedManifest
    case unreadableDeviceVersion(String)
    case network(String)

    var description: String {
        switch self {
        case .malformedManifest: "更新信息格式不正确。"
        case let .unreadableDeviceVersion(raw): "无法识别这个版本号：“\(raw)”（需要 major.minor.patch 格式）。"
        case let .network(detail): "连不上更新服务器：\(detail)"
        }
    }
}

private struct FirmwareManifest: Decodable {
    let version: String
    let notes: String?
    let history: [String]?
    let binary: String?
}

/// Fetches the per-hardware `version.json` manifest and downloads the named
/// binary — no BLE, no UI, so the comparison result and the local file are
/// all a caller gets.
///
/// The manifest comes from `raw.githubusercontent.com` while the binary goes
/// through jsDelivr: raw serves small JSON promptly but its 12-hour edge
/// cache makes a freshly published manifest slow to appear, and jsDelivr
/// reliably serves the large binary that raw sometimes stalls on mid-transfer.
/// Both are keyed by the hardware id the device reports over BLE, so a new
/// board publishes under its own path with no code change.
struct FirmwareUpdateChecker {
    private static let maxAttempts = 3

    private static func manifestURL(hardware: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/\(hardware)/firmware/version.json")!
    }

    private static func binaryURL(hardware: String, binary: String) -> URL {
        URL(string: "https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/\(hardware)/firmware/\(binary)")!
    }

    private static let fallbackBinaryName = "signal-light.bin"

    func check(hardware: String, currentVersion: String) async throws -> FirmwareUpdateAvailability {
        guard let current = SignalLightFirmwareVersion(currentVersion) else {
            // What the device (or `--current`) reported isn't a version at all;
            // blaming the manifest would send the user looking in the wrong
            // place.
            throw FirmwareCheckError.unreadableDeviceVersion(currentVersion)
        }
        let manifest = try await fetchManifest(hardware: hardware)
        guard let latest = SignalLightFirmwareVersion(manifest.version) else {
            throw FirmwareCheckError.malformedManifest
        }
        if latest > current {
            return .updateAvailable(current: currentVersion, latest: manifest.version, notes: manifest.notes)
        }
        return .upToDate(current: currentVersion)
    }

    /// Downloads the latest binary for `hardware` to a temp file, returning
    /// its URL and the version string it corresponds to.
    func downloadLatest(hardware: String) async throws -> (url: URL, version: String) {
        let manifest = try await fetchManifest(hardware: hardware)
        let binaryName = manifest.binary ?? Self.fallbackBinaryName
        let data = try await fetchWithRetry(url: Self.binaryURL(hardware: hardware, binary: binaryName), timeout: 20)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-light-firmware-\(manifest.version).bin")
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        return (destination, manifest.version)
    }

    private func fetchManifest(hardware: String) async throws -> FirmwareManifest {
        let data = try await fetchWithRetry(url: Self.manifestURL(hardware: hardware), timeout: 8)
        guard let manifest = try? JSONDecoder().decode(FirmwareManifest.self, from: data) else {
            throw FirmwareCheckError.malformedManifest
        }
        return manifest
    }

    private func fetchWithRetry(url: URL, timeout: TimeInterval) async throws -> Data {
        var lastDetail = "未知错误"
        for attempt in 1...Self.maxAttempts {
            do {
                var request = URLRequest(url: appendingCacheBuster(to: url))
                request.timeoutInterval = timeout
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw FirmwareCheckError.network("响应无效")
                }
                if http.statusCode == 200 {
                    return data
                }
                // 404/other 4xx won't be fixed by retrying; fail fast.
                if !(http.statusCode == 429 || (500...599).contains(http.statusCode)) {
                    throw FirmwareCheckError.network("HTTP \(http.statusCode)")
                }
                lastDetail = "HTTP \(http.statusCode)"
            } catch let error as FirmwareCheckError {
                throw error
            } catch is CancellationError {
                // The user asked to stop; a retry would ignore them.
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastDetail = error.localizedDescription
            }
            if attempt < Self.maxAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw FirmwareCheckError.network(lastDetail)
    }

    /// A per-call query item defeats the local `URLCache` so a fresh check
    /// never sees a stale client-side copy (does not affect the CDN edge).
    private func appendingCacheBuster(to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "_t", value: UUID().uuidString)]
        return components.url ?? url
    }
}
