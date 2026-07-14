import { z } from "zod";

export const ISODateTimeSchema = z.iso.datetime({ offset: true });

export const RequestIdSchema = z.string().min(1).max(128);
export const IdempotencyKeySchema = z.string().min(1).max(256);
export const WebUrlSchema = z
  .string()
  .url()
  .max(8_192)
  .refine((value) => {
    const protocol = new URL(value).protocol;
    return protocol === "http:" || protocol === "https:";
  }, "URL must use the http or https protocol");

const prefixedId = (prefix: string) =>
  z.string().regex(new RegExp(`^${prefix}_[A-Za-z0-9]+$`));

export const TaskIdSchema = prefixedId("task");
export const SnapshotIdSchema = prefixedId("snapshot");
export const RunIdSchema = prefixedId("run");
export const ArtifactIdSchema = prefixedId("artifact");
export const UserIdSchema = prefixedId("user");
export const DeviceIdSchema = prefixedId("device");
export const SyncManifestIdSchema = prefixedId("sync");
export const BlobIdSchema = prefixedId("blob");
export const LedgerIdSchema = prefixedId("ledger");
export const ManagedJobIdSchema = prefixedId("job");

export const MessageMetaSchema = z
  .object({
    version: z.number().int().positive(),
    requestId: RequestIdSchema,
    createdAt: ISODateTimeSchema,
    idempotencyKey: IdempotencyKeySchema.optional(),
  })
  .strict();

export const AppErrorCategorySchema = z.enum([
  "extraction",
  "permission",
  "auth",
  "rate_limit",
  "network",
  "tls",
  "protocol",
  "storage",
  "sync",
  "entitlement",
  "provider",
  "unknown",
]);

export const AppErrorActionSchema = z.enum([
  "retry",
  "open_in_browser",
  "grant_permission",
  "reauthenticate",
  "update_credentials",
  "switch_provider",
  "free_space",
  "upgrade_app",
  "export_data",
  "contact_support",
  "none",
]);

export const AppErrorSchema = z
  .object({
    version: z.literal(1),
    requestId: RequestIdSchema,
    createdAt: ISODateTimeSchema,
    category: AppErrorCategorySchema,
    code: z.string().regex(/^[A-Z][A-Z0-9_]{2,63}$/),
    retryable: z.boolean(),
    action: AppErrorActionSchema,
    safeDetail: z.string().max(2_000).optional(),
  })
  .strict();

export type MessageMeta = z.infer<typeof MessageMetaSchema>;
export type AppError = z.infer<typeof AppErrorSchema>;
