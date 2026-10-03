import { Readable } from 'node:stream';
import { AssetType, JobName, JobStatus } from 'src/enum';
import { MediaService } from 'src/services/media.service';
import { ASSET_CHECKSUM_CONSTRAINT } from 'src/utils/database';
import { AssetFactory } from 'test/factories/asset.factory';
import { getForAsset } from 'test/mappers';
import { newTestService, ServiceMocks } from 'test/utils';

describe('Storage Saver commit safety', () => {
  let sut: MediaService;
  let mocks: ServiceMocks;
  const asset = AssetFactory.create({ originalPath: '/data/original.jpg', originalFileName: 'original.jpg' });
  const outputPath = '/data/original.jpg.storage-saver.jpg';

  beforeEach(() => {
    ({ sut, mocks } = newTestService(MediaService));
    mocks.asset.getById.mockResolvedValue(getForAsset(asset));
    mocks.storage.stat.mockImplementation((path) =>
      Promise.resolve({
        size: path === outputPath ? 60 : 100,
        mtime: new Date(),
      } as Awaited<ReturnType<typeof mocks.storage.stat>>),
    );
    mocks.storage.createPlainReadStream.mockReturnValue(Readable.from([Buffer.from('encoded')]));
    mocks.storage.checkFileExists.mockResolvedValue(true);
  });

  it('preserves the committed output if cleanup scheduling fails', async () => {
    mocks.job.queue.mockRejectedValueOnce(new Error('cleanup unavailable'));

    expect(await sut.handleStorageSaverCompression({ id: asset.id })).toBe(JobStatus.Success);
    expect(mocks.asset.commitStorageSaver).toHaveBeenCalledWith(expect.objectContaining({ outputPath }));
    expect(mocks.storage.unlink).not.toHaveBeenCalled();
    expect(mocks.job.queue).toHaveBeenCalledWith({ name: JobName.UserSyncUsage });
    expect(mocks.websocket.serverSend).toHaveBeenCalledWith(
      'StorageSaverProgress',
      expect.objectContaining({ state: 'completed' }),
    );
  });

  it('repairs post-commit bookkeeping on retry without recompressing', async () => {
    mocks.asset.getById.mockResolvedValue(getForAsset({ ...asset, originalPath: outputPath }));

    expect(await sut.handleStorageSaverCompression({ id: asset.id })).toBe(JobStatus.Success);
    expect(mocks.media.compressStorageSaverImage).not.toHaveBeenCalled();
    expect(mocks.job.queue).toHaveBeenCalledWith({ name: JobName.UserSyncUsage });
    expect(mocks.job.queue).toHaveBeenCalledWith({ name: JobName.FileDelete, data: { files: ['/data/original.jpg'] } });
  });

  it('preserves the output if the database acknowledgment is lost after commit', async () => {
    mocks.asset.commitStorageSaver.mockRejectedValue(new Error('connection lost'));
    mocks.asset.getById
      .mockResolvedValueOnce(getForAsset(asset))
      .mockResolvedValueOnce(getForAsset({ ...asset, originalPath: outputPath }));

    expect(await sut.handleStorageSaverCompression({ id: asset.id })).toBe(JobStatus.Success);
    expect(mocks.storage.unlink).not.toHaveBeenCalled();
  });

  it('removes only an uncommitted temporary output after encoding fails', async () => {
    mocks.media.compressStorageSaverImage.mockRejectedValue(new Error('encoder failed'));

    expect(await sut.handleStorageSaverCompression({ id: asset.id })).toBe(JobStatus.Failed);
    expect(mocks.storage.unlink).toHaveBeenCalledWith(outputPath);
    expect(mocks.asset.commitStorageSaver).not.toHaveBeenCalled();
    expect(mocks.job.queue).not.toHaveBeenCalledWith({
      name: JobName.AssetExtractMetadata,
      data: { id: asset.id, source: 'upload' },
    });
  });

  it('preserves both files when a lost commit acknowledgment cannot be verified', async () => {
    mocks.asset.commitStorageSaver.mockRejectedValue(new Error('connection lost'));
    mocks.asset.getById.mockResolvedValueOnce(getForAsset(asset)).mockRejectedValueOnce(new Error('database offline'));

    expect(await sut.handleStorageSaverCompression({ id: asset.id, durableUpload: true })).toBe(JobStatus.Failed);
    expect(mocks.storage.unlink).not.toHaveBeenCalled();
    expect(mocks.job.queue).not.toHaveBeenCalled();
  });

  it('keeps the original when flushing the encoded output fails', async () => {
    mocks.storage.syncFile.mockRejectedValue(new Error('disk flush failed'));

    expect(await sut.handleStorageSaverCompression({ id: asset.id, durableUpload: true })).toBe(JobStatus.Failed);
    expect(mocks.asset.commitStorageSaver).not.toHaveBeenCalled();
    expect(mocks.storage.unlink).toHaveBeenCalledExactlyOnceWith(outputPath);
    expect(mocks.job.queue).not.toHaveBeenCalled();
  });

  it('keeps the original and skips optimization when compressed bytes conflict with another asset', async () => {
    const conflict = Object.assign(new Error('canonical checksum already exists'), {
      constraint_name: ASSET_CHECKSUM_CONSTRAINT,
    });
    mocks.asset.commitStorageSaver.mockRejectedValue(conflict);

    expect(await sut.handleStorageSaverCompression({ id: asset.id, durableUpload: true })).toBe(JobStatus.Skipped);
    expect(mocks.storage.unlink).toHaveBeenCalledExactlyOnceWith(outputPath);
    expect(mocks.job.queue).not.toHaveBeenCalled();
    expect(mocks.websocket.serverSend).toHaveBeenCalledWith(
      'StorageSaverProgress',
      expect.objectContaining({ state: 'skipped' }),
    );
  });

  it('lets the durable scheduler admit metadata after efficient media is skipped', async () => {
    mocks.media.compressStorageSaverImage.mockResolvedValue(false);

    expect(await sut.handleStorageSaverCompression({ id: asset.id, durableUpload: true })).toBe(JobStatus.Skipped);
    expect(mocks.job.queue).not.toHaveBeenCalled();
  });

  it('moves an old queued video out of the photo workers without scheduling premature metadata', async () => {
    mocks.asset.getById.mockResolvedValue(getForAsset({ ...asset, type: AssetType.Video }));

    expect(await sut.handleStorageSaverCompression({ id: asset.id })).toBe(JobStatus.Success);
    expect(mocks.job.queue).toHaveBeenCalledExactlyOnceWith({
      name: JobName.AssetCompressStorageSaverVideo,
      data: { id: asset.id },
    });
    expect(mocks.media.compressStorageSaverVideo).not.toHaveBeenCalled();
    expect(mocks.storage.stat).not.toHaveBeenCalled();
  });

  it('keeps an efficient video unchanged and continues metadata extraction', async () => {
    mocks.asset.getById.mockResolvedValue(getForAsset({ ...asset, type: AssetType.Video }));
    mocks.media.compressStorageSaverVideo.mockResolvedValue(false);

    expect(await sut.handleStorageSaverVideoCompression({ id: asset.id })).toBe(JobStatus.Skipped);
    expect(mocks.asset.commitStorageSaver).not.toHaveBeenCalled();
    expect(mocks.storage.unlink).not.toHaveBeenCalled();
    expect(mocks.job.queue).toHaveBeenCalledWith({
      name: JobName.AssetExtractMetadata,
      data: { id: asset.id, source: 'upload' },
    });
    expect(mocks.websocket.serverSend).toHaveBeenCalledWith(
      'StorageSaverProgress',
      expect.objectContaining({ state: 'skipped', progress: 1 }),
    );
  });
});
