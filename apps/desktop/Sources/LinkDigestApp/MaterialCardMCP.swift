import Foundation
import LinkDigestCore

/// `jizuo_get_record` 的 `material_card` 字段：没有素材卡时是 null；老调用方忽略这个新键即可。
enum MaterialCardMCP {
  static func payload(_ record: TaskMaterialCardRecord?) -> Any {
    guard let record else { return NSNull() }
    let card = record.card
    return [
      "speaker": card.speaker,
      "viewpoints": card.viewpoints,
      "hook": card.hook,
      "quotes": card.quotes,
      "is_live_speaker": card.isLiveSpeaker,
      "live_speaker_reason": card.liveSpeakerReason,
      "generated_at_ms": record.updatedAtMilliseconds,
    ] as [String: Any]
  }
}
