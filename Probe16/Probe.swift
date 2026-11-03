import Foundation

/// Sensor probe for running MiniWatts' readers on iOS 16, before anything is ported.
///
/// It reads what the app reads — the HID sensors on usage pages 0xff08 and 0xff00, the
/// IOKit registry and powerd — the same way `HIDSensors` and `IOKitBattery` do, and
/// writes all of it out unedited as JSON: no catalog, no plausibility filter, no merging
/// of copies. The point is to find out what an iPhone 12 on iOS 16.5 actually returns.
///
/// Every call runs on `Probe.queue`. A process gets one working HID client, and it is
/// never used from two threads at once.
final class Probe {
    static let queue = DispatchQueue(label: "org.zhaohe.MiniWattsProbe16.probe")

    private static let powerPage = 0xff08
    private static let vendorPage = 0xff00
    private static let powerEvent: Int64 = 25       // kIOHIDEventTypePower
    private static let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature

    /// Dumped whole. The first two are the battery; the rest are what `AccessoryProbe`
    /// looks at for the charger and cable, all property-filtered on iOS 27.
    private static let registryClasses = [
        "IOPMPowerSource", "AppleSmartBattery", "AppleARMPMUCharger",
        "IOAccessoryManager", "IOAccessoryPort",
        "IOPortTransportStateCC", "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
    ]

    private typealias ServiceMatchingFn = @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias GetMatchingServicesFn =
        @convention(c) (mach_port_t, CFDictionary?, UnsafeMutablePointer<UInt32>) -> kern_return_t
    private typealias IteratorNextFn = @convention(c) (UInt32) -> UInt32
    private typealias CreatePropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> kern_return_t
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> kern_return_t
    private typealias GetNameFn = @convention(c) (UInt32, UnsafeMutablePointer<CChar>) -> kern_return_t
    private typealias CopyPowerSourcesInfoFn = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyPowerSourcesListFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias GetPowerSourceDescriptionFn =
        @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
    private typealias CopyAdapterDetailsFn = @convention(c) () -> Unmanaged<CFDictionary>?
    private typealias CopyChargeStatusFn = @convention(c) (UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32
    private typealias CopyBatteryInfoFn =
        @convention(c) (mach_port_t, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> Int32

    private typealias HIDCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let key: String
        let location: UInt32
        let page: Int
        let usage: Int
        /// 0 for a service on neither sensor page: nothing is read from it.
        let eventType: Int64
    }

    private let serviceMatching: ServiceMatchingFn?
    private let getMatchingServices: GetMatchingServicesFn?
    private let iteratorNext: IteratorNextFn?
    private let createProperties: CreatePropertiesFn?
    private let objectRelease: ObjectReleaseFn?
    private let registryEntryName: GetNameFn?
    private let objectClass: GetNameFn?
    private let copyPowerSourcesInfo: CopyPowerSourcesInfoFn?
    private let copyPowerSourcesList: CopyPowerSourcesListFn?
    private let powerSourceDescription: GetPowerSourceDescriptionFn?
    private let copyAdapterDetails: CopyAdapterDetailsFn?
    private let copyChargeStatus: CopyChargeStatusFn?
    private let copyBatteryInfo: CopyBatteryInfoFn?
    private let setMatching: SetMatchingFn?
    private let copyServices: CopyServicesFn?
    private let copyProperty: CopyPropertyFn?
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    private let hidClient: CFTypeRef?
    private let missingSymbols: [String]

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        var missing: [String] = []
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else {
                missing.append(name)
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }
        serviceMatching = sym("IOServiceMatching", ServiceMatchingFn.self)
        getMatchingServices = sym("IOServiceGetMatchingServices", GetMatchingServicesFn.self)
        iteratorNext = sym("IOIteratorNext", IteratorNextFn.self)
        createProperties = sym("IORegistryEntryCreateCFProperties", CreatePropertiesFn.self)
        objectRelease = sym("IOObjectRelease", ObjectReleaseFn.self)
        registryEntryName = sym("IORegistryEntryGetName", GetNameFn.self)
        objectClass = sym("IOObjectGetClass", GetNameFn.self)
        copyPowerSourcesInfo = sym("IOPSCopyPowerSourcesInfo", CopyPowerSourcesInfoFn.self)
        copyPowerSourcesList = sym("IOPSCopyPowerSourcesList", CopyPowerSourcesListFn.self)
        powerSourceDescription = sym("IOPSGetPowerSourceDescription", GetPowerSourceDescriptionFn.self)
        copyAdapterDetails = sym("IOPSCopyExternalPowerAdapterDetails", CopyAdapterDetailsFn.self)
        copyChargeStatus = sym("IOPSCopyChargeStatus", CopyChargeStatusFn.self)
        copyBatteryInfo = sym("IOPMCopyBatteryInfo", CopyBatteryInfoFn.self)
        setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        hidClient = sym("IOHIDEventSystemClientCreate", HIDCreateFn.self)?(kCFAllocatorDefault)?.takeRetainedValue()
        missingSymbols = missing
    }

    // MARK: - Collection

    /// One full run: inventory, registry and powerd once, then `seconds` samples a
    /// second apart, then powerd again. Blocks; call it on `queue`.
    func collect(note: String, seconds: Int, progress: @escaping (String) -> Void) -> [String: Any] {
        let started = Date()
        var root: [String: Any] = [:]
        root["probeVersion"] = 1
        root["note"] = note
        root["startedAt"] = ISO8601DateFormatter().string(from: started)
        root["device"] = [
            "model": Self.sysctl("hw.machine"),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "build": Self.sysctl("kern.osversion"),
            "bundle": Bundle.main.bundleIdentifier ?? "?",
            // Outside the sandbox the shared preferences folder is readable.
            "sandboxed": !FileManager.default.isReadableFile(atPath: "/var/mobile/Library/Preferences"),
        ] as [String: Any]
        root["missingSymbols"] = missingSymbols
        root["hidClientCreated"] = hidClient != nil

        // Every HID service, with a value where the service is on a sensor page. This is
        // the list the app's Raw data inventory shows, plus what each one reads.
        progress("HID：全部服务")
        let inventory = discover(nil)
        root["hidInventory"] = inventory.enumerated().map { index, service in
            describe(service, index: index, value: true)
        }

        // The two matchings `HIDSensors.rescan()` uses. These are what the app samples.
        progress("HID：传感器")
        let sensors = discover(["PrimaryUsagePage": Self.powerPage])
            + discover(["PrimaryUsagePage": Self.vendorPage, "PrimaryUsage": 5])
        root["sensors"] = sensors.enumerated().map { index, service in
            describe(service, index: index, value: false)
        }
        var copies: [String: Int] = [:]
        for service in sensors where !service.key.isEmpty { copies[service.key, default: 0] += 1 }
        root["sensorKeysWithCopies"] = copies.filter { $0.value > 1 }

        progress("IOKit 注册表")
        var registry: [String: Any] = [:]
        for name in Self.registryClasses { registry[name] = dumpRegistry(name) }
        root["registry"] = registry

        progress("powerd")
        root["powerd"] = powerd()

        // `hid` in each sample is in the order of `sensors` above.
        var samples: [[String: Any]] = []
        for n in 0..<seconds {
            progress("采样 \(n + 1)/\(seconds)")
            let tick = Date()
            var sample: [String: Any] = [:]
            sample["t"] = (tick.timeIntervalSince(started) * 1000).rounded() / 1000
            sample["hid"] = sensors.map { Self.number(readRaw($0)) }
            sample["battery"] = registryScalars("IOPMPowerSource")
            sample["powerd"] = JSONSafe.convert(powerSources().first ?? [:])
            sample["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
            samples.append(sample)
            if n + 1 < seconds {
                Thread.sleep(forTimeInterval: max(0, 1 - Date().timeIntervalSince(tick)))
            }
        }
        root["samples"] = samples

        progress("收尾")
        root["powerdEnd"] = powerd()
        root["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        return JSONSafe.convert(root) as? [String: Any] ?? [:]
    }

    // MARK: - HID

    private func discover(_ matching: [String: Any]?) -> [Service] {
        guard let hidClient, let setMatching, let copyServices, let copyProperty else { return [] }
        // nil, not an empty dictionary: an empty one matches nothing.
        setMatching(hidClient, matching as CFDictionary?)
        let refs = copyServices(hidClient)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            func number(_ key: String) -> Int {
                (copyProperty(ref, key as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            let location = (copyProperty(ref, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber)?
                .uint32Value ?? 0
            let page = number("PrimaryUsagePage")
            let usage = number("PrimaryUsage")
            let eventType: Int64
            if page == Self.powerPage {
                eventType = Self.powerEvent
            } else if page == Self.vendorPage && usage == 5 {
                eventType = Self.temperatureEvent
            } else {
                eventType = 0
            }
            return Service(ref: ref, name: name, key: Self.smcKey(location), location: location,
                           page: page, usage: usage, eventType: eventType)
        }
    }

    /// nil when there is no event at all; NaN is passed through, it is a different answer.
    private func readRaw(_ service: Service) -> Double? {
        guard service.eventType != 0, let copyEvent, let getFloat,
              let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue()
        else { return nil }
        return getFloat(event, Int32(service.eventType << 16))
    }

    private func describe(_ service: Service, index: Int, value: Bool) -> [String: Any] {
        var item: [String: Any] = [
            "i": index,
            "name": service.name,
            "page": String(format: "0x%04x", service.page),
            "usage": service.usage,
        ]
        if !service.key.isEmpty { item["key"] = service.key }
        if service.location != 0 { item["location"] = String(format: "0x%08x", service.location) }
        if value && service.eventType != 0 { item["value"] = Self.number(readRaw(service)) }
        return item
    }

    private static func smcKey(_ location: UInt32) -> String {
        let bytes = withUnsafeBytes(of: location.bigEndian) { Array($0) }
        guard location != 0, bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Registry

    private func dumpRegistry(_ className: String) -> [String: Any] {
        guard let serviceMatching, let getMatchingServices, let iteratorNext,
              let createProperties, let objectRelease
        else { return ["error": "symbols missing"] }
        guard let matching = serviceMatching(className) else { return ["error": "IOServiceMatching returned nil"] }
        var iterator: UInt32 = 0
        // Consumes the +1 reference IOServiceMatching returned.
        let result = getMatchingServices(0, matching.takeUnretainedValue(), &iterator)
        guard result == KERN_SUCCESS else { return ["error": Self.hex(result)] }
        defer { _ = objectRelease(iterator) }

        var entries: [[String: Any]] = []
        var entry = iteratorNext(iterator)
        while entry != 0 {
            var item: [String: Any] = [
                "name": Self.name(registryEntryName, entry),
                "class": Self.name(objectClass, entry),
            ]
            var properties: Unmanaged<CFDictionary>?
            let read = createProperties(entry, &properties, kCFAllocatorDefault, 0)
            item["result"] = Self.hex(read)
            if read == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                item["keyCount"] = dictionary.count
                item["properties"] = JSONSafe.convert(dictionary)
            }
            entries.append(item)
            _ = objectRelease(entry)
            entry = iteratorNext(iterator)
        }
        return ["matches": entries.count, "entries": entries]
    }

    /// Top-level numbers and flags of the first match. Small enough to take every second.
    private func registryScalars(_ className: String) -> [String: Any] {
        guard let serviceMatching, let getMatchingServices, let iteratorNext,
              let createProperties, let objectRelease,
              let matching = serviceMatching(className)
        else { return [:] }
        var iterator: UInt32 = 0
        guard getMatchingServices(0, matching.takeUnretainedValue(), &iterator) == KERN_SUCCESS else { return [:] }
        defer { _ = objectRelease(iterator) }
        let entry = iteratorNext(iterator)
        guard entry != 0 else { return [:] }
        defer { _ = objectRelease(entry) }
        var properties: Unmanaged<CFDictionary>?
        guard createProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return (JSONSafe.convert(dictionary.filter { $0.value is NSNumber }) as? [String: Any]) ?? [:]
    }

    private static func name(_ function: GetNameFn?, _ entry: UInt32) -> String {
        guard let function else { return "?" }
        var buffer = [CChar](repeating: 0, count: 128) // io_name_t
        guard function(entry, &buffer) == KERN_SUCCESS else { return "?" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: - powerd

    private func powerSources() -> [[String: Any]] {
        guard let copyPowerSourcesInfo, let copyPowerSourcesList, let powerSourceDescription,
              let blob = copyPowerSourcesInfo()?.takeRetainedValue(),
              let list = copyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { powerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    private func powerd() -> [String: Any] {
        var out: [String: Any] = [:]
        out["sources"] = JSONSafe.convert(powerSources())
        if let copyAdapterDetails {
            out["adapterDetails"] = copyAdapterDetails()?.takeRetainedValue() as Any? ?? NSNull()
        }
        if let copyChargeStatus {
            var value: Unmanaged<CFTypeRef>?
            let result = copyChargeStatus(&value)
            out["IOPSCopyChargeStatus"] = [
                "result": Self.hex(result),
                "value": value?.takeRetainedValue() as Any? ?? NSNull(),
            ] as [String: Any]
        }
        if let copyBatteryInfo {
            var value: Unmanaged<CFArray>?
            let result = copyBatteryInfo(0, &value)
            out["IOPMCopyBatteryInfo"] = [
                "result": Self.hex(result),
                "value": value?.takeRetainedValue() as Any? ?? NSNull(),
            ] as [String: Any]
        }
        return JSONSafe.convert(out) as? [String: Any] ?? [:]
    }

    // MARK: - Helpers

    private static func number(_ value: Double?) -> Any {
        guard let value else { return "no event" }
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        return value
    }

    private static func hex(_ value: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: value))
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// Turns whatever IOKit and powerd hand back into something `JSONSerialization` accepts,
/// and drops identifiers: a dump is meant to be passed around.
enum JSONSafe {
    private static let sensitive = try! NSRegularExpression(
        pattern: "serial|udid|imei|ecid|uuid|mlb", options: .caseInsensitive)

    static func convert(_ value: Any) -> Any {
        switch value {
        case is NSNull:
            return NSNull()
        case let string as String:
            return string
        case let dictionary as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in dictionary {
                let range = NSRange(key.startIndex..., in: key)
                out[key] = sensitive.firstMatch(in: key, range: range) == nil ? convert(item) : "<redacted>"
            }
            return out
        case let array as [Any]:
            return array.map(convert)
        case let data as Data:
            let bytes = data.prefix(64).map { String(format: "%02x", $0) }.joined()
            return "<data \(data.count) bytes: \(bytes)\(data.count > 64 ? "…" : "")>"
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number.doubleValue.isFinite ? number : String(describing: number)
        default:
            return String(describing: value)
        }
    }
}
