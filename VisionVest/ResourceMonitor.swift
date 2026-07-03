import Combine
import Darwin
import Foundation
import MachO

final class ResourceMonitor: ObservableObject {
    @Published private(set) var cpuUsageText = "CPU --"
    @Published private(set) var memoryUsageText = "RAM --"
    @Published private(set) var statusText = "Resource monitor idle"

    private var timer: Timer?
    private var previousCPULoadInfo: host_cpu_load_info_data_t?

    func startMonitoring() {
        guard timer == nil else {
            return
        }

        updateMetrics()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
        RunLoop.main.add(timer!, forMode: .common)
        statusText = "Monitoring device resources"
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        statusText = "Resource monitor idle"
    }

    private func updateMetrics() {
        cpuUsageText = currentCPUUsageText() ?? "CPU unavailable"
        memoryUsageText = currentMemoryUsageText() ?? "RAM unavailable"
    }

    private func currentCPUUsageText() -> String? {
        var cpuLoadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, integerPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        defer {
            previousCPULoadInfo = cpuLoadInfo
        }

        guard let previousCPULoadInfo else {
            return "CPU warming up"
        }

        let currentTicks = cpuLoadInfo.cpu_ticks
        let previousTicks = previousCPULoadInfo.cpu_ticks

        let userDelta = Double(currentTicks.0 - previousTicks.0)
        let systemDelta = Double(currentTicks.1 - previousTicks.1)
        let idleDelta = Double(currentTicks.2 - previousTicks.2)
        let niceDelta = Double(currentTicks.3 - previousTicks.3)

        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard totalDelta > 0 else {
            return nil
        }

        let usage = ((userDelta + systemDelta + niceDelta) / totalDelta) * 100
        return String(format: "%.0f%%", usage)
    }

    private func currentMemoryUsageText() -> String? {
        let pageSize = vm_kernel_page_size

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, integerPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        let usedPageCount = UInt64(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)
        let freePageCount = UInt64(stats.free_count + stats.speculative_count)
        let totalPageCount = usedPageCount + freePageCount

        guard totalPageCount > 0 else {
            return nil
        }

        let usedBytes = usedPageCount * UInt64(pageSize)
        let totalBytes = totalPageCount * UInt64(pageSize)
        let usage = (Double(usedBytes) / Double(totalBytes)) * 100

        return String(
            format: "%.0f%% (%.1f / %.1f GB)",
            usage,
            bytesToGigabytes(usedBytes),
            bytesToGigabytes(totalBytes)
        )
    }

    private func bytesToGigabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_073_741_824
    }
}
