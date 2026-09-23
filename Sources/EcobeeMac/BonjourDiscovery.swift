import Foundation
import Darwin
import LocalCore

/// Use mDNSResponder on macOS rather than opening a second multicast stack.
@MainActor final class BonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var devices: [String: DiscoveredDevice] = [:]
    private var completion: CheckedContinuation<[DiscoveredDevice], Error>?
    private var timer: Task<Void, Never>?

    func discover() async throws -> [DiscoveredDevice] {
        guard completion == nil else { throw AppFailure("Discovery is already running.") }
        devices = [:]; services = []
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_hap._tcp.", inDomain: "local.")
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(7)) } catch { return }
                self?.finish()
            }
        }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(error: AppFailure("Bonjour discovery could not start. Allow Local Network access for Ecobee Local in System Settings and retry."))
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        guard let txt = service.txtRecordData() else { return }
        let attributes = NetService.dictionary(fromTXTRecord: txt)
        func field(_ name: String) -> String { attributes[name].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        guard !field("id").isEmpty, Int(field("ci")) == 9 || (field("md") + service.name).lowercased().contains("ecobee") else { return }
        var addresses: [(Int32, String)] = []
        for data in service.addresses ?? [] {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else { return }
                let addr = base.assumingMemoryBound(to: sockaddr.self)
                let family = Int32(addr.pointee.sa_family)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append((family, String(cString: host)))
                }
            }
        }
        guard let address = addresses.first(where: { $0.0 == AF_INET })?.1 ?? addresses.first?.1 else { return }
        let flags = Int(field("sf")) ?? 0
        let object: [String: Any] = ["id": field("id").lowercased(), "name": service.name, "model": field("md"),
            "address": address, "port": service.port, "available": flags & 1 != 0, "statusFlags": flags,
            "featureFlags": Int(field("ff")) ?? 0, "configNumber": Int(field("c#")) ?? 1]
        if let data = try? JSONSerialization.data(withJSONObject: object), let device = try? JSONDecoder().decode(DiscoveredDevice.self, from: data) {
            devices[device.id] = device
        }
    }
    private func finish(error: Error? = nil) {
        timer?.cancel(); timer = nil; browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services { service.stop(); service.delegate = nil }; services = []
        let callback = completion; completion = nil
        if let error { callback?.resume(throwing: error) }
        else { callback?.resume(returning: devices.values.sorted { $0.name < $1.name }) }
    }
}
