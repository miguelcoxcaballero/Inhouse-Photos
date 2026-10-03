import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`
    CREATE TABLE "asset_upload_receipt" (
      "assetId" uuid NOT NULL,
      "ownerId" uuid NOT NULL,
      "checksum" bytea NOT NULL,
      "originalPath" character varying NOT NULL,
      CONSTRAINT "asset_upload_receipt_pkey" PRIMARY KEY ("assetId"),
      CONSTRAINT "asset_upload_receipt_assetId_fkey" FOREIGN KEY ("assetId")
        REFERENCES "asset" ("id") ON UPDATE CASCADE ON DELETE CASCADE,
      CONSTRAINT "asset_upload_receipt_ownerId_fkey" FOREIGN KEY ("ownerId")
        REFERENCES "user" ("id") ON UPDATE CASCADE ON DELETE CASCADE
    )
  `.execute(db);
  await sql`CREATE UNIQUE INDEX "UQ_upload_receipt_owner_checksum"
    ON "asset_upload_receipt" ("ownerId", "checksum")`.execute(db);
  await sql`
    CREATE TABLE "asset_upload_processing" (
      "assetId" uuid NOT NULL,
      "jobName" character varying NOT NULL,
      "availableAt" timestamp with time zone NOT NULL DEFAULT now(),
      CONSTRAINT "asset_upload_processing_pkey" PRIMARY KEY ("assetId"),
      CONSTRAINT "asset_upload_processing_assetId_fkey" FOREIGN KEY ("assetId")
        REFERENCES "asset" ("id") ON UPDATE CASCADE ON DELETE CASCADE
    )
  `.execute(db);
  await sql`
    CREATE INDEX "asset_upload_processing_pending_idx"
      ON "asset_upload_processing" ("jobName", "availableAt", "assetId")
  `.execute(db);
}

export function down(): Promise<void> {
  // Pending uploads must not be discarded by a runtime rollback.
  return Promise.reject(new Error('Drain the durable upload backlog before reverting this migration'));
}
