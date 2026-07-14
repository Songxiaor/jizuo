import { z } from "zod";

import {
  BlobIdSchema,
  DeviceIdSchema,
  ISODateTimeSchema,
  IdempotencyKeySchema,
  LedgerIdSchema,
  ManagedJobIdSchema,
  SyncManifestIdSchema,
  UserIdSchema,
} from "./common.js";

export const UserSchema = z
  .object({
    version: z.literal(1),
    id: UserIdSchema,
    primaryIdentityRef: z.string().min(1).max(512),
    region: z.string().min(1).max(64),
    status: z.enum(["active", "deletion_pending", "deleted"]),
    createdAt: ISODateTimeSchema,
  })
  .strict();

export const DeviceSchema = z
  .object({
    version: z.literal(1),
    id: DeviceIdSchema,
    userId: UserIdSchema,
    platform: z.enum(["macos", "windows"]),
    appVersion: z.string().regex(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/),
    lastSeenAt: ISODateTimeSchema,
    revokedAt: ISODateTimeSchema.nullable(),
  })
  .strict();

export const EntitlementSchema = z
  .object({
    version: z.literal(1),
    userId: UserIdSchema,
    plan: z.enum(["free", "paid", "internal"]),
    features: z
      .object({
        encryptedSync: z.boolean(),
        managedAi: z.boolean(),
      })
      .strict(),
    managedAiRemaining: z.number().int().nonnegative(),
    periodEndsAt: ISODateTimeSchema,
  })
  .strict();

export const SyncManifestSchema = z
  .object({
    version: z.literal(1),
    id: SyncManifestIdSchema,
    userId: UserIdSchema,
    deviceId: DeviceIdSchema,
    logicalItemId: z.string().min(1).max(128),
    revision: z.number().int().positive(),
    blobId: BlobIdSchema.nullable(),
    deletedAt: ISODateTimeSchema.nullable(),
    updatedAt: ISODateTimeSchema,
  })
  .strict();

export const EncryptedBlobSchema = z
  .object({
    version: z.literal(1),
    id: BlobIdSchema,
    ownerUserId: UserIdSchema,
    storageKey: z
      .string()
      .regex(/^users\/user_[A-Za-z0-9]+\/blobs\/blob_[A-Za-z0-9]+$/)
      .max(1_024),
    cipherSuiteVersion: z.number().int().positive(),
    sha256: z.string().min(16).max(128),
    sizeBytes: z.number().int().positive(),
    deleteState: z.enum(["active", "queued", "deleted"]),
  })
  .strict()
  .superRefine((value, context) => {
    const expectedStorageKey = `users/${value.ownerUserId}/blobs/${value.id}`;
    if (value.storageKey !== expectedStorageKey) {
      context.addIssue({
        code: "custom",
        path: ["storageKey"],
        message: "storageKey must match ownerUserId and blob id",
      });
    }
  });

export const UsageLedgerSchema = z
  .object({
    version: z.literal(1),
    id: LedgerIdSchema,
    userId: UserIdSchema,
    idempotencyKey: IdempotencyKeySchema,
    kind: z.enum(["reserve", "settle", "release", "refund", "adjustment"]),
    units: z.number().int().positive(),
    relatedJobId: ManagedJobIdSchema,
    createdAt: ISODateTimeSchema,
  })
  .strict();

export type User = z.infer<typeof UserSchema>;
export type Device = z.infer<typeof DeviceSchema>;
export type Entitlement = z.infer<typeof EntitlementSchema>;
export type SyncManifest = z.infer<typeof SyncManifestSchema>;
export type EncryptedBlob = z.infer<typeof EncryptedBlobSchema>;
export type UsageLedger = z.infer<typeof UsageLedgerSchema>;
