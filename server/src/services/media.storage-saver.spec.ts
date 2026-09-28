import { Readable } from 'node:stream';
import { JobName, JobStatus } from 'src/enum';
import { MediaService } from 'src/services/media.service';
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
    mocks.storage.stat.mockImplementation(
      async (path) =>
        ({
          size: path === outputPath ? 60 : 100,
          mtime: new Date(),
        }) as Awaited<ReturnType<typeof mocks.storage.stat>>,
    );
    mocks.storage.createPlainReadStream.mockReturnValue(Readable.from([Buffer.from('encoded')]));
    mocks.storage.checkFileExists.mockResolvedValue(true);
  });

  it('preserves the file referenced by the database if usage accounting fails', async () => {
    mocks.user.updateUsage.mockRejectedValue(new Error('usage unavailable'));

    expect(await sut.handleStorageSaverCompression({ id: asset.id })).toBe(JobStatus.Success);
    expect(mocks.asset.update).toHaveBeenCalledWith(expect.objectContaining({ originalPath: outputPath }));
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
    mocks.asset.update.mockRejectedValue(new Error('connection lost'));
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
    expect(mocks.asset.update).not.toHaveBeenCalled();
  });
});
