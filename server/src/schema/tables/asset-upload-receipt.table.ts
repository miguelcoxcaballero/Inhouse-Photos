import { Column, ForeignKeyColumn, Index, Table } from '@immich/sql-tools';
import { AssetTable } from 'src/schema/tables/asset.table';
import { UserTable } from 'src/schema/tables/user.table';
import { UPLOAD_RECEIPT_CHECKSUM_CONSTRAINT } from 'src/utils/database';

@Table('asset_upload_receipt')
@Index({ name: UPLOAD_RECEIPT_CHECKSUM_CONSTRAINT, columns: ['ownerId', 'checksum'], unique: true })
export class AssetUploadReceiptTable {
  @ForeignKeyColumn(() => AssetTable, { onDelete: 'CASCADE', onUpdate: 'CASCADE', primary: true, index: false })
  assetId!: string;

  @ForeignKeyColumn(() => UserTable, { onDelete: 'CASCADE', onUpdate: 'CASCADE', index: false })
  ownerId!: string;

  @Column({ type: 'bytea' })
  checksum!: Buffer;

  @Column({ type: 'character varying' })
  originalPath!: string;
}
