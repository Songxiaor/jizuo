import { z } from "zod";

import {
  AppErrorSchema,
  ArtifactIdSchema,
  ISODateTimeSchema,
  IdempotencyKeySchema,
  RequestIdSchema,
  RunIdSchema,
  SnapshotIdSchema,
  TaskIdSchema,
  WebUrlSchema,
} from "./common.js";

export const SourcePlatformSchema = z.enum([
  "generic",
  "x",
  "youtube",
  "wechat",
  "xiaohongshu",
  "douyin",
  "bilibili",
]);

export const CaptureEnvelopeV1Schema = z
  .object({
    version: z.literal(1),
    requestId: RequestIdSchema,
    createdAt: ISODateTimeSchema,
    idempotencyKey: IdempotencyKeySchema.optional(),
    source: z
      .object({
        kind: z.literal("browser_capture"),
        url: WebUrlSchema,
        title: z.string().max(1_024).nullable(),
        platform: SourcePlatformSchema,
      })
      .strict(),
    capture: z
      .object({
        method: z.enum(["rendered_dom", "selection"]),
        text: z.string().min(1).max(2_000_000),
        characterCount: z.number().int().positive().max(2_000_000),
        completeness: z.enum([
          "full_article",
          "visible_only",
          "selection_only",
          "unknown",
        ]),
        capturedAt: ISODateTimeSchema,
      })
      .strict(),
    evidence: z
      .object({
        sourceLabel: z.string().min(1).max(128),
        usedCookie: z.boolean(),
      })
      .strict(),
  })
  .strict()
  .superRefine((value, context) => {
    if ([...value.capture.text].length !== value.capture.characterCount) {
      context.addIssue({
        code: "custom",
        path: ["capture", "characterCount"],
        message: "characterCount must match the Unicode character count of text",
      });
    }
  });

export const TaskSchema = z
  .object({
    version: z.literal(1),
    id: TaskIdSchema,
    createdAt: ISODateTimeSchema,
    updatedAt: ISODateTimeSchema,
    status: z.enum([
      "queued",
      "extracting",
      "ready",
      "generating",
      "completed",
      "failed",
      "cancelled",
    ]),
    action: z.enum(["extract", "summary", "translate"]),
    source: z
      .object({
        kind: z.enum(["url", "browser_capture", "selection", "pasted_text"]),
        url: WebUrlSchema.nullable(),
        title: z.string().max(1_024).nullable(),
        platform: SourcePlatformSchema,
      })
      .strict(),
    currentSnapshotId: SnapshotIdSchema.nullable(),
    currentArtifactId: ArtifactIdSchema.nullable(),
    tags: z.array(z.string().min(1).max(64)).max(100),
  })
  .strict();

export const ContentSnapshotSchema = z
  .object({
    version: z.literal(1),
    id: SnapshotIdSchema,
    taskId: TaskIdSchema,
    extractionMethod: z.enum([
      "rendered_dom",
      "readability",
      "adapter",
      "subtitle",
      "transcript",
      "pasted",
    ]),
    completeness: z.enum([
      "full_article",
      "visible_only",
      "metadata_only",
      "unknown",
    ]),
    title: z.string().max(1_024).nullable(),
    author: z.string().max(512).nullable(),
    language: z.string().min(2).max(35),
    text: z.string().min(1).max(2_000_000),
    characterCount: z.number().int().positive().max(2_000_000),
    truncated: z.boolean(),
    evidence: z
      .object({
        usedCookie: z.boolean(),
        sourceLabel: z.string().min(1).max(128),
        capturedAt: ISODateTimeSchema,
      })
      .strict(),
  })
  .strict()
  .superRefine((value, context) => {
    if ([...value.text].length !== value.characterCount) {
      context.addIssue({
        code: "custom",
        path: ["characterCount"],
        message: "characterCount must match the Unicode character count of text",
      });
    }
  });

export const RunSchema = z
  .object({
    version: z.literal(1),
    id: RunIdSchema,
    taskId: TaskIdSchema,
    kind: z.enum(["extraction", "model", "export"]),
    status: z.enum(["running", "succeeded", "failed", "cancelled"]),
    startedAt: ISODateTimeSchema,
    endedAt: ISODateTimeSchema.nullable(),
    providerProfileId: z.string().min(1).max(128).nullable(),
    model: z.string().min(1).max(512).nullable(),
    error: AppErrorSchema.nullable(),
  })
  .strict();

export const ArtifactSchema = z
  .object({
    version: z.literal(1),
    id: ArtifactIdSchema,
    taskId: TaskIdSchema,
    runId: RunIdSchema,
    kind: z.enum(["summary", "translation", "source", "export"]),
    format: z.enum(["markdown", "text", "json"]),
    completeness: z.enum(["complete", "partial"]),
    content: z.string().min(1).max(5_000_000),
    createdAt: ISODateTimeSchema,
  })
  .strict();

export type CaptureEnvelopeV1 = z.infer<typeof CaptureEnvelopeV1Schema>;
export type Task = z.infer<typeof TaskSchema>;
export type ContentSnapshot = z.infer<typeof ContentSnapshotSchema>;
export type Run = z.infer<typeof RunSchema>;
export type Artifact = z.infer<typeof ArtifactSchema>;
