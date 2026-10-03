import { Column, ForeignKeyColumn, Generated, Index, Table, Timestamp } from '@immich/sql-tools';
import { JobName } from 'src/enum';
import { AssetTable } from 'src/schema/tables/asset.table';

export type UploadProcessingJob =
  | JobName.AssetCompressStorageSaver
  | JobName.AssetCompressStorageSaverVideo
  | JobName.AssetExtractMetadata
  | JobName.StorageTemplateMigrationSingle
  | JobName.AssetGenerateThumbnails;

@Table('asset_upload_processing')
@Index({ name: 'asset_upload_processing_pending_idx', columns: ['jobName', 'availableAt', 'assetId'] })
export class AssetUploadProcessingTable {
  @ForeignKeyColumn(() => AssetTable, { onDelete: 'CASCADE', onUpdate: 'CASCADE', primary: true, index: false })
  assetId!: string;

  @Column({ type: 'character varying' })
  jobName!: UploadProcessingJob;

  @Column({ type: 'timestamp with time zone', default: () => 'now()' })
  availableAt!: Generated<Timestamp>;
}
