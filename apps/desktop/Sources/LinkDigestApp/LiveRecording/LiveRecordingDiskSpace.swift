import Foundation
import LinkDigestCore

/// 录制前的空间门槛与「还能录多久」估算。
///
/// 直播录制一小时原画约 2–2.8 GB，空间见底时 ffmpeg 会写坏最后一个文件，
/// 所以在开录前和录制中各设一道线：少于 2 GB 不开始，少于 1 GB 自动收尾。
enum LiveRecordingDiskSpace {
  static let requiredFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
  static let stopFreeBytes: Int64 = 1 * 1024 * 1024 * 1024
  /// 合并是流复制：产物和分段一样大，还要再留一点给 moov / faststart 的第二遍写盘。
  static let mergeHeadroomBytes: Int64 = 512 * 1024 * 1024

  /// 合并一次需要的剩余空间：分段总量 + 余量。
  static func mergeRequiredBytes(recordedBytes: Int64) -> Int64 {
    max(0, recordedBytes) + mergeHeadroomBytes
  }

  /// 录制中的自动收尾阈值。
  ///
  /// 只按 1 GB 收尾并不够：收尾后要再写一份同样大的成品，磁盘不够时合并必然失败，
  /// 只剩 `.parts` 里的分段。所以阈值随已录大小抬高到「分段总量 + 余量」，保证停在
  /// 还有空间合并的位置。分段越多停得越早，这是为了换「能出一个完整成品」。
  static func stopThresholdBytes(recordedBytes: Int64) -> Int64 {
    max(stopFreeBytes, mergeRequiredBytes(recordedBytes: recordedBytes))
  }

  static func availableBytes(at url: URL) -> Int64 {
    // 目录还没创建时沿父目录往上找，卷容量对路径本身是否存不存在并不敏感，
    // 但某些文件系统会拒绝不存在的挂载点路径。
    var candidate = url
    while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
      candidate.deleteLastPathComponent()
    }
    // 必须用新的 URL 实例：`URL.resourceValues` 会把结果缓存在 URL 自身，
    // 同一个实例反复读永远拿到第一次的容量，录制中的空间检查就永远不会触发。
    let fresh = URL(fileURLWithPath: candidate.path)
    let values = try? fresh.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    )
    return values?.volumeAvailableCapacityForImportantUsage
      ?? Int64(values?.volumeAvailableCapacity ?? 0)
  }

  /// 各档的估算码率（bit/s）。只用来给用户一个量级，不参与录制。
  static func estimatedBitrate(_ quality: LiveQuality) -> Int64 {
    switch quality {
    case .origin: return 6_000_000
    case .hd: return 4_000_000
    case .sd: return 2_000_000
    case .ld: return 1_000_000
    }
  }

  static func estimatedHours(freeBytes: Int64, quality: LiveQuality) -> Double {
    guard freeBytes > 0 else { return 0 }
    let bytesPerSecond = Double(estimatedBitrate(quality)) / 8
    return Double(freeBytes) / bytesPerSecond / 3600
  }

  static func estimatedHoursText(freeBytes: Int64, quality: LiveQuality) -> String {
    let hours = estimatedHours(freeBytes: freeBytes, quality: quality)
    guard hours > 0 else { return "空间不足" }
    if hours >= 10 { return "约 \(Int(hours.rounded())) 小时" }
    return String(format: "约 %.1f 小时", hours)
  }
}
