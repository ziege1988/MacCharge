import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - CPU

/// CPU-Gesamtauslastung aus den Mach-Tick-Zählern (Differenz zweier Messungen).
final class CPUSensor {
    private var previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    func sample() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = (user: load.cpu_ticks.0, system: load.cpu_ticks.1, idle: load.cpu_ticks.2, nice: load.cpu_ticks.3)
        defer { previous = current }
        guard let prev = previous else { return nil }

        let user = Double(current.user &- prev.user)
        let system = Double(current.system &- prev.system)
        let idle = Double(current.idle &- prev.idle)
        let nice = Double(current.nice &- prev.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return min(100, max(0, (user + system + nice) / total * 100))
    }
}

// MARK: - Arbeitsspeicher

struct MemoryReading {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var percent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
}

/// "Belegter Speicher" analog zur Aktivitätsanzeige: App-Speicher + Wired + Komprimiert.
enum MemorySensor {
    static func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appMemory = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (appMemory + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return MemoryReading(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

// MARK: - GPU

/// GPU-Auslastung aus der IORegistry (IOAccelerator → PerformanceStatistics).
/// Funktioniert ohne Root-Rechte auf Apple Silicon und den meisten Intel-Macs.
enum GPUSensor {
    static func sample() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any] {
                let value = (stats["Device Utilization %"] as? NSNumber)
                    ?? (stats["GPU Activity(%)"] as? NSNumber)
                    ?? (stats["Renderer Utilization %"] as? NSNumber)
                if let value { best = max(best ?? 0, value.doubleValue) }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best.map { min(100, max(0, $0)) }
    }
}

// MARK: - Akku

struct BatteryReading {
    var hasBattery = false
    var percent: Int = 0
    var isCharging = false
    var externalPower = false          // Netzteil liefert Strom (= Steckdose an & Kabel steckt)
    var fullyCharged = false
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var temperatureC: Double?
    var cycleCount: Int?
    var healthPercent: Double?         // aktuelle Maximalkapazität / Designkapazität
    var watts: Double?                 // + lädt, − entlädt
    var adapterWatts: Int?
}

enum BatterySensor {
    static func sample() -> BatteryReading {
        var reading = BatteryReading()

        // 1) Öffentliche Power-Sources-API (Prozent, Status, Restzeit)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      (desc["Type"] as? String) == "InternalBattery" else { continue }
                reading.hasBattery = true
                let current = (desc["Current Capacity"] as? Int) ?? 0
                let max = (desc["Max Capacity"] as? Int) ?? 100
                reading.percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
                reading.isCharging = (desc["Is Charging"] as? Bool) ?? false
                reading.externalPower = (desc["Power Source State"] as? String) == "AC Power"
                reading.fullyCharged = (desc["Is Charged"] as? Bool) ?? false
                if let t = desc["Time to Empty"] as? Int, t > 0 { reading.minutesToEmpty = t }
                if let t = desc["Time to Full Charge"] as? Int, t > 0 { reading.minutesToFull = t }
            }
        }

        // 2) Detailwerte aus AppleSmartBattery (Temperatur, Zyklen, Gesundheit, Leistung)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                if let t = dict["Temperature"] as? NSNumber { reading.temperatureC = t.doubleValue / 100 }
                if let c = dict["CycleCount"] as? NSNumber { reading.cycleCount = c.intValue }
                let design = (dict["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
                let rawMax = (dict["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
                    ?? (dict["NominalChargeCapacity"] as? NSNumber)?.doubleValue
                    ?? (dict["MaxCapacity"] as? NSNumber)?.doubleValue ?? 0
                if design > 0, rawMax > 100 { reading.healthPercent = min(100, rawMax / design * 100) }
                if let v = dict["Voltage"] as? NSNumber, let a = dict["Amperage"] as? NSNumber {
                    let amps = Double(Int32(truncatingIfNeeded: a.int64Value)) / 1000
                    reading.watts = v.doubleValue / 1000 * amps
                }
                if let ext = dict["ExternalConnected"] as? Bool, !reading.hasBattery { reading.externalPower = ext }
                if let adapter = dict["AdapterDetails"] as? [String: Any], let w = adapter["Watts"] as? NSNumber {
                    reading.adapterWatts = w.intValue
                }
            }
        }
        return reading
    }
}
