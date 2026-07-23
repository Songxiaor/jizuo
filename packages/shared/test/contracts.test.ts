import { describe, expect, it } from "vitest";

import {
  AppErrorSchema,
  ArtifactSchema,
  CaptureEnvelopeV1Schema,
  ContentSnapshotSchema,
  DeviceSchema,
  EncryptedBlobSchema,
  EntitlementSchema,
  RunSchema,
  SyncManifestSchema,
  TaskSchema,
  UsageLedgerSchema,
  UserSchema,
} from "../src/index.js";
import { readFileSync } from "node:fs";
import { fixturePath, validateCaptureEnvelope } from "../src/index.js";

const now = "2026-07-13T20:00:00Z";

const validCapture = {
  version: 1,
  requestId: "request-capture-1",
  createdAt: now,
  idempotencyKey: "capture:tab-1:revision-1",
  source: {
    kind: "browser_capture",
    url: "https://example.com/article",
    title: "A local-first article",
    platform: "generic",
  },
  capture: {
    method: "rendered_dom",
    text: "Readable content",
    characterCount: 16,
    completeness: "full_article",
    capturedAt: now,
  },
  evidence: {
    sourceLabel: "Current page DOM",
    usedCookie: false,
  },
} as const;

describe("local contracts", () => {
  it("validates the language-neutral fixture manifest and semantic invariants", () => {
    const manifest = JSON.parse(readFileSync(fixturePath("fixture-manifest.json"), "utf8")) as { schema: string; fixtures: Array<{ file: string; schema?: string; expect: string; mutation?: { field: string; repeat: number; unit: string }}> };
    for (const fixture of manifest.fixtures) {
      const value = JSON.parse(readFileSync(fixturePath(fixture.file), "utf8")) as Record<string, unknown>;
      if (fixture.mutation) (value.capture as Record<string, unknown>).text = fixture.mutation.unit.repeat(fixture.mutation.repeat);
      const result = validateCaptureEnvelope(value, fixture.schema ?? manifest.schema);
      expect(result.ok, fixture.file).toBe(fixture.expect === "valid");
    }
  });
  it("enforces V2 media selection fields and candidate-count bounds", () => {
    const value = JSON.parse(readFileSync(fixturePath("v2-direct-file.json"), "utf8")) as Record<string, unknown>;
    const media = value.media as Record<string, unknown>;
    Object.assign(media, { candidateCount: 1000, selectionReason: "playing", playbackState: "playing" });
    expect(validateCaptureEnvelope(value, "../capture-envelope-v2.schema.json").ok).toBe(true);
    media.candidateCount = 1001;
    expect(validateCaptureEnvelope(value, "../capture-envelope-v2.schema.json").ok).toBe(false);
    media.candidateCount = 1;
    media.selectionReason = "firstInDOM";
    expect(validateCaptureEnvelope(value, "../capture-envelope-v2.schema.json").ok).toBe(false);
  });
  it("keeps V1 cookie evidence false while V2 accepts explicit false and true", () => {
    expect(validateCaptureEnvelope({
      ...validCapture,
      evidence: { ...validCapture.evidence, usedCookie: true },
    }).ok).toBe(false);
    const value = JSON.parse(readFileSync(fixturePath("v2-direct-file.json"), "utf8")) as Record<string, unknown>;
    value.evidence = { sourceLabel: "Current page DOM", usedCookie: false };
    expect(validateCaptureEnvelope(value, "../capture-envelope-v2.schema.json").ok).toBe(true);
    value.evidence = { sourceLabel: "Current page DOM + same-origin session detail", usedCookie: true };
    expect(validateCaptureEnvelope(value, "../capture-envelope-v2.schema.json").ok).toBe(true);
  });
  it("accepts a valid CaptureEnvelopeV1", () => {
    expect(CaptureEnvelopeV1Schema.parse(validCapture)).toEqual(validCapture);
  });

  it("rejects an unsupported capture protocol version", () => {
    expect(() =>
      CaptureEnvelopeV1Schema.parse({ ...validCapture, version: 2 }),
    ).toThrow();
  });

  it("rejects non-web URL schemes at the capture boundary", () => {
    expect(() =>
      CaptureEnvelopeV1Schema.parse({
        ...validCapture,
        source: { ...validCapture.source, url: "file:///etc/passwd" },
      }),
    ).toThrow();
  });

  it("rejects a mismatched character count", () => {
    expect(() =>
      CaptureEnvelopeV1Schema.parse({
        ...validCapture,
        capture: { ...validCapture.capture, characterCount: 99 },
      }),
    ).toThrow();
  });

  it("rejects undeclared secret-looking fields in AppError", () => {
    expect(() =>
      AppErrorSchema.parse({
        version: 1,
        requestId: "request-error-1",
        createdAt: now,
        category: "auth",
        code: "MODEL_HTTP_401",
        retryable: false,
        action: "update_credentials",
        apiKey: "not-a-real-secret",
      }),
    ).toThrow();
  });

  it("accepts the persisted local domain models", () => {
    const task = TaskSchema.parse({
      version: 1,
      id: "task_01J",
      createdAt: now,
      updatedAt: now,
      status: "completed",
      action: "summary",
      source: {
        kind: "browser_capture",
        url: "https://example.com/article",
        title: "A local-first article",
        platform: "generic",
      },
      currentSnapshotId: "snapshot_01J",
      currentArtifactId: "artifact_01J",
      tags: ["architecture"],
    });
    expect(task.id).toBe("task_01J");

    expect(
      ContentSnapshotSchema.parse({
        version: 1,
        id: "snapshot_01J",
        taskId: task.id,
        extractionMethod: "rendered_dom",
        completeness: "full_article",
        title: "A local-first article",
        author: null,
        language: "en",
        text: "Readable content",
        characterCount: 16,
        truncated: false,
        evidence: {
          usedCookie: false,
          sourceLabel: "Current page DOM",
          capturedAt: now,
        },
      }).taskId,
    ).toBe(task.id);

    expect(
      RunSchema.parse({
        version: 1,
        id: "run_01J",
        taskId: task.id,
        kind: "model",
        status: "succeeded",
        startedAt: now,
        endedAt: now,
        providerProfileId: "provider-local",
        model: "example-model",
        error: null,
      }).status,
    ).toBe("succeeded");

    expect(
      ArtifactSchema.parse({
        version: 1,
        id: "artifact_01J",
        taskId: task.id,
        runId: "run_01J",
        kind: "summary",
        format: "markdown",
        completeness: "complete",
        content: "# Summary",
        createdAt: now,
      }).format,
    ).toBe("markdown");
  });

  it("rejects a persisted snapshot with inconsistent text metadata", () => {
    expect(() =>
      ContentSnapshotSchema.parse({
        version: 1,
        id: "snapshot_01J",
        taskId: "task_01J",
        extractionMethod: "rendered_dom",
        completeness: "full_article",
        title: "A local-first article",
        author: null,
        language: "en",
        text: "Readable content",
        characterCount: 999,
        truncated: false,
        evidence: {
          usedCookie: false,
          sourceLabel: "Current page DOM",
          capturedAt: now,
        },
      }),
    ).toThrow();
  });
});

describe("cloud contracts", () => {
  it("accepts account, entitlement, sync, blob and ledger models", () => {
    expect(
      UserSchema.parse({
        version: 1,
        id: "user_01J",
        primaryIdentityRef: "oidc://provider/subject",
        region: "global-primary",
        status: "active",
        createdAt: now,
      }).status,
    ).toBe("active");

    expect(
      DeviceSchema.parse({
        version: 1,
        id: "device_01J",
        userId: "user_01J",
        platform: "macos",
        appVersion: "0.1.0",
        lastSeenAt: now,
        revokedAt: null,
      }).platform,
    ).toBe("macos");

    expect(
      EntitlementSchema.parse({
        version: 1,
        userId: "user_01J",
        plan: "free",
        features: { encryptedSync: true, managedAi: true },
        managedAiRemaining: 48,
        periodEndsAt: now,
      }).managedAiRemaining,
    ).toBe(48);

    expect(
      SyncManifestSchema.parse({
        version: 1,
        id: "sync_01J",
        userId: "user_01J",
        deviceId: "device_01J",
        logicalItemId: "task_01J",
        revision: 7,
        blobId: "blob_01J",
        deletedAt: null,
        updatedAt: now,
      }).revision,
    ).toBe(7);

    expect(
      EncryptedBlobSchema.parse({
        version: 1,
        id: "blob_01J",
        ownerUserId: "user_01J",
        storageKey: "users/user_01J/blobs/blob_01J",
        cipherSuiteVersion: 1,
        sha256: "0123456789abcdef0123456789abcdef",
        sizeBytes: 48_210,
        deleteState: "active",
      }).deleteState,
    ).toBe("active");

    expect(
      UsageLedgerSchema.parse({
        version: 1,
        id: "ledger_01J",
        userId: "user_01J",
        idempotencyKey: "managed-run:task_01J:run_01J",
        kind: "reserve",
        units: 1,
        relatedJobId: "job_01J",
        createdAt: now,
      }).units,
    ).toBe(1);
  });

  it("rejects an encrypted blob path owned by another user", () => {
    expect(() =>
      EncryptedBlobSchema.parse({
        version: 1,
        id: "blob_01J",
        ownerUserId: "user_01J",
        storageKey: "users/user_OTHER/blobs/blob_01J",
        cipherSuiteVersion: 1,
        sha256: "0123456789abcdef0123456789abcdef",
        sizeBytes: 48_210,
        deleteState: "active",
      }),
    ).toThrow();
  });
});
