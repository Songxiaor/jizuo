import Foundation
import GRDB
import LinkDigestCore

// MARK: - 素材卡（Migration025）

extension GRDBHistoryRepository: MaterialCardStoring {
  public func saveMaterialCard(_ record: TaskMaterialCardRecord) throws {
    let cardJSON: String
    do {
      cardJSON = String(decoding: try JSONEncoder().encode(record.card), as: UTF8.self)
    } catch { throw RepositoryFailure.invalidInput }
    try database.write { db in
      guard let storedTask: String = try String.fetchOne(
        db, sql: "SELECT id FROM tasks WHERE id = ?", arguments: [record.taskID.rawValue]
      ), storedTask == record.taskID.rawValue else { throw RepositoryFailure.invalidInput }
      try db.execute(
        sql: """
          INSERT INTO task_material_cards
            (task_id, card_json, live_speaker, live_speaker_tag_applied, live_speaker_tag_suppressed,
             provider, model, prompt_tokens, completion_tokens, total_tokens, created_at_ms, updated_at_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(task_id) DO UPDATE SET
            card_json = excluded.card_json,
            live_speaker = excluded.live_speaker,
            live_speaker_tag_applied = excluded.live_speaker_tag_applied,
            live_speaker_tag_suppressed = excluded.live_speaker_tag_suppressed,
            provider = excluded.provider,
            model = excluded.model,
            prompt_tokens = excluded.prompt_tokens,
            completion_tokens = excluded.completion_tokens,
            total_tokens = excluded.total_tokens,
            updated_at_ms = excluded.updated_at_ms
          """,
        arguments: [
          record.taskID.rawValue, cardJSON, record.card.isLiveSpeaker ? 1 : 0,
          record.liveSpeakerTagApplied ? 1 : 0, record.liveSpeakerTagSuppressed ? 1 : 0,
          record.provider, record.model, record.promptTokens, record.completionTokens,
          record.totalTokens, record.createdAtMilliseconds, record.updatedAtMilliseconds,
        ]
      )
    }
  }

  public func loadMaterialCard(taskID: TaskID) throws -> TaskMaterialCardRecord? {
    try database.read { db in
      guard let row = try Row.fetchOne(
        db, sql: "SELECT * FROM task_material_cards WHERE task_id = ?", arguments: [taskID.rawValue]
      ) else { return nil }
      let cardJSON: String = row["card_json"]
      guard let card = try? JSONDecoder().decode(MaterialCard.self, from: Data(cardJSON.utf8)) else { return nil }
      return TaskMaterialCardRecord(
        taskID: taskID,
        card: card,
        liveSpeakerTagApplied: (row["live_speaker_tag_applied"] as Int64? ?? 0) == 1,
        liveSpeakerTagSuppressed: (row["live_speaker_tag_suppressed"] as Int64? ?? 0) == 1,
        provider: row["provider"],
        model: row["model"],
        promptTokens: (row["prompt_tokens"] as Int64?).map(Int.init),
        completionTokens: (row["completion_tokens"] as Int64?).map(Int.init),
        totalTokens: (row["total_tokens"] as Int64?).map(Int.init),
        createdAtMilliseconds: row["created_at_ms"],
        updatedAtMilliseconds: row["updated_at_ms"]
      )
    }
  }

  public func deleteMaterialCard(taskID: TaskID) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM task_material_cards WHERE task_id = ?", arguments: [taskID.rawValue])
    }
  }

  public func materialCardTaskIDs() throws -> Set<TaskID> {
    try database.read { db in
      Set(try String.fetchAll(db, sql: "SELECT task_id FROM task_material_cards").compactMap { TaskID($0) })
    }
  }

  public func materialCardCandidates() throws -> [MaterialCardCandidate] {
    try database.read { db in
      // 只看听写层（source_kind = local_transcription）；每条取最新一份转写稿的字数。
      let rows = try Row.fetchAll(db, sql: """
        SELECT t.id AS id,
          (SELECT LENGTH(s.body_text) FROM content_snapshots s
            WHERE s.task_id = t.id AND s.source_kind = 'local_transcription'
            ORDER BY s.sequence DESC LIMIT 1) AS characters
        FROM tasks t
        WHERE t.deleted_at_ms IS NULL
          AND t.content_kind <> '\(TaskClassificationSQL.draftKind)'
          AND EXISTS (SELECT 1 FROM content_snapshots s
            WHERE s.task_id = t.id AND s.source_kind = 'local_transcription')
          AND NOT EXISTS (SELECT 1 FROM task_material_cards c WHERE c.task_id = t.id)
        ORDER BY t.created_at_ms DESC
        """)
      return rows.compactMap { row in
        guard let id = TaskID(row["id"] as String) else { return nil }
        let characters: Int64 = row["characters"] ?? 0
        guard characters >= Int64(MaterialCardPrompt.minimumTranscriptCharacters) else { return nil }
        return MaterialCardCandidate(taskID: id, transcriptCharacters: Int(characters))
      }
    }
  }
}
