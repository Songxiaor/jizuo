import Foundation
import LinkDigestCore

/// ffmpeg 参数只在这里拼，录制和合并各一处，测试直接比对数组。
enum FFmpegCommand {
  /// 录制一段。`-c copy` 不转码，CPU 占用与画质都不受影响。
  static func record(
    inputURL: String,
    outputURL: URL,
    userAgent: String,
    referer: String,
    quality: LiveQuality,
    platform: LiveRecordingPlatform = .douyin
  ) -> [String] {
    var arguments = [
      "-hide_banner", "-nostdin", "-y",
      // 错误日志会原样带上输入地址（含签名），而地址不允许落盘。这里彻底静音，
      // 失败与否由进程退出码判断，界面只解释「在重连 / 已停止」。
      "-loglevel", "quiet",
      "-user_agent", userAgent,
      "-headers", "Referer: \(referer)\r\n",
      "-reconnect", "1",
      "-reconnect_streamed", "1",
      "-reconnect_at_eof", "0",
      "-reconnect_delay_max", "5",
      // 网络读超时（微秒）：CDN 卡死时不让 ffmpeg 无限挂住。
      "-rw_timeout", "15000000",
      "-i", inputURL,
    ]
    // 显式只取画面和可选音轨：小红书 EF5 流里混着 text/subtitle，抖音 HLS
    // 也可能带数据流，不指定会一起写进中间文件。
    arguments.append(contentsOf: ["-map", "0:v:0", "-map", "0:a:0?"])
    arguments.append(contentsOf: [
      "-c", "copy",
    ])
    // 这里不打 hvc1：同一个「原画」档，有的房间是 H.264、有的是 H.265，
    // 标签打错 ffmpeg 直接写不出文件。编码在合并前用 ffprobe 探明后再打。
    // 中间段用 MPEG-TS：分段时间戳不连续时，TS 直接拼接不会像 MP4 那样被
    // 截短；最终合并时再转成 MP4。
    if outputURL.pathExtension.lowercased() != "ts" {
      arguments.append(contentsOf: ["-movflags", "+faststart"])
    }
    arguments.append(outputURL.path)
    return arguments
  }

  /// 分段合并：concat demuxer + 流复制。各段来自同一档流，参数一致才能直接拼。
  static func concat(listFile: URL, outputURL: URL, tagHVC1: Bool) -> [String] {
    var arguments = [
      "-hide_banner", "-nostdin", "-y",
      "-loglevel", "quiet",
      "-f", "concat",
      "-safe", "0",
      "-i", listFile.path,
      "-c", "copy",
    ]
    if tagHVC1 {
      arguments.append(contentsOf: ["-tag:v", "hvc1"])
    }
    arguments.append(contentsOf: ["-movflags", "+faststart", outputURL.path])
    return arguments
  }

  /// concat 清单里的一行。单引号是分隔符，路径里的单引号要写成 `'\''`。
  static func concatListLine(fileURL: URL) -> String {
    let escaped = fileURL.path.replacingOccurrences(of: "'", with: "'\\''")
    return "file '\(escaped)'\n"
  }

  /// 只有 HEVC 才打 hvc1；H.264 打上会报
  /// `Tag hvc1 incompatible with output codec id '27' (avc1)`，文件是 0 字节。
  static func shouldTagHVC1(codecName: String?) -> Bool {
    guard let codecName else { return false }
    return ["hevc", "h265", "h.265"].contains(codecName.lowercased())
  }
}
