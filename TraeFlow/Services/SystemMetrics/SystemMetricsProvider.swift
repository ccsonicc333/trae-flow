import Foundation

/// 系统指标快照，用于通过 JS Bridge 推送到自定义 HTML 区域。
struct SystemMetrics: Encodable {
    /// CPU 使用率百分比 (0–100)
    let cpu: Double
    /// 内存使用率百分比 (0–100)
    let memoryPercent: Double
    /// 已用内存（字节）
    let memoryUsed: UInt64
    /// 总内存（字节）
    let memoryTotal: UInt64
    /// 1 分钟负载均值
    let loadOne: Double
    /// 5 分钟负载均值
    let loadFive: Double
    /// 15 分钟负载均值
    let loadFifteen: Double
    /// 逻辑 CPU 核心数
    let cores: Int

    enum CodingKeys: String, CodingKey {
        case cpu
        case memoryPercent
        case memoryUsed
        case memoryTotal
        case loadOne
        case loadFive
        case loadFifteen
        case cores
    }
}

/// 通过 macOS 原生 API 获取真实的 CPU、内存、负载指标。
///
/// CPU 使用率通过两次 `host_statistics(HOST_CPU_LOAD_INFO)` 采样求差值得出，
/// 因此调用方需保持同一实例以缓存上次的 CPU tick 快照。
@MainActor
final class SystemMetricsProvider {
    static let shared = SystemMetricsProvider()

    /// 上一次 CPU tick 快照（用于计算使用率差值）
    private var previousCPUTicks: CPUTicks?

    /// 逻辑 CPU 核心数（启动时缓存）
    private let processorCount: Int

    private init() {
        // 注：项目内 ProcessTreeBuilder.swift 定义了同名 `ProcessInfo` 类型，
        // 因此必须显式使用 `Foundation.ProcessInfo` 限定 Foundation 标准类型。
        processorCount = Foundation.ProcessInfo.processInfo.activeProcessorCount
    }

    // MARK: - CPU Ticks

    private typealias CPUTicks = (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)

    /// 通过 `host_statistics` 采样一次 CPU tick 计数器。
    private func sampleCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            user: UInt64(info.cpu_ticks.0),   // CPU_STATE_USER
            system: UInt64(info.cpu_ticks.1), // CPU_STATE_SYSTEM
            idle: UInt64(info.cpu_ticks.2),   // CPU_STATE_IDLE
            nice: UInt64(info.cpu_ticks.3)    // CPU_STATE_NICE
        )
    }

    /// 根据前后两次 CPU tick 采样计算使用率百分比。
    private func cpuUsage(between prev: CPUTicks, and curr: CPUTicks) -> Double {
        let prevTotal = prev.user + prev.system + prev.idle + prev.nice
        let currTotal = curr.user + curr.system + curr.idle + curr.nice
        let totalDelta = currTotal - prevTotal
        guard totalDelta > 0 else { return 0 }

        let prevUsed = prev.user + prev.system + prev.nice
        let currUsed = curr.user + curr.system + curr.nice
        let usedDelta = currUsed - prevUsed

        return Double(usedDelta) / Double(totalDelta) * 100.0
    }

    // MARK: - Memory

    /// 通过 `host_statistics64` 获取真实内存使用信息。
    private func memoryStats() -> (used: UInt64, total: UInt64, percent: Double) {
        let total = Foundation.ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageSizeU64 = UInt64(pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, total, 0)
        }

        // App Memory ≅ wired + active + compressed（macOS Activity Monitor 的 "Memory Used" 口径）
        let wired = UInt64(vmStats.wire_count) * pageSizeU64
        let active = UInt64(vmStats.active_count) * pageSizeU64
        let compressed = UInt64(vmStats.compressor_page_count) * pageSizeU64
        let used = wired + active + compressed

        let percent = Double(used) / Double(total) * 100.0
        return (used, total, min(percent, 100))
    }

    // MARK: - Load Average

    /// 通过 `getloadavg` 获取系统负载均值。
    private func loadAverage() -> (one: Double, five: Double, fifteen: Double) {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return (one: loads[0], five: loads[1], fifteen: loads[2])
    }

    // MARK: - Public API

    /// 采样当前系统指标。
    /// 首次调用时 CPU 使用率固定为 0（需要两次采样才能计算差值）。
    func sample() -> SystemMetrics {
        let mem = memoryStats()
        let load = loadAverage()

        var cpu: Double = 0
        if let currentTicks = sampleCPUTicks() {
            if let prev = previousCPUTicks {
                cpu = cpuUsage(between: prev, and: currentTicks)
            }
            previousCPUTicks = currentTicks
        }

        return SystemMetrics(
            cpu: cpu,
            memoryPercent: mem.percent,
            memoryUsed: mem.used,
            memoryTotal: mem.total,
            loadOne: load.one,
            loadFive: load.five,
            loadFifteen: load.fifteen,
            cores: processorCount
        )
    }

    /// 将指标编码为 JSON 字符串，供 `evaluateJavaScript` 注入。
    func sampleAsJSON() -> String {
        let metrics = sample()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(metrics),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
