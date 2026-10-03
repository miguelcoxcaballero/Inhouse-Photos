import { JobName, JobStatus, QueueName } from 'src/enum';
import { UploadProcessingService } from 'src/services/upload-processing.service';
import { newTestService, ServiceMocks } from 'test/utils';

const emptyCounts = { active: 0, waiting: 0, paused: 0, delayed: 0, completed: 0, failed: 0 };

describe(UploadProcessingService.name, () => {
  let sut: UploadProcessingService;
  let mocks: ServiceMocks;

  beforeEach(() => {
    ({ sut, mocks } = newTestService(UploadProcessingService));
    mocks.job.getJobCounts.mockResolvedValue(emptyCounts);
    mocks.cron.create.mockImplementation(() => {});
    mocks.cron.update.mockImplementation(() => {});
  });

  it('rebuilds lost Redis jobs from the persistent processing stage', async () => {
    mocks.asset.getPendingUploadProcessing.mockImplementation((name) =>
      Promise.resolve(name === JobName.AssetCompressStorageSaver ? [{ assetId: 'saved-original' }] : []),
    );

    await sut.recover();

    expect(mocks.asset.getPendingUploadProcessing).toHaveBeenCalledWith(JobName.AssetCompressStorageSaver, 100);
    expect(mocks.job.queueAll).toHaveBeenCalledExactlyOnceWith([
      { name: JobName.AssetCompressStorageSaver, data: { id: 'saved-original', durableUpload: true } },
    ]);
    expect(mocks.asset.deferUploadProcessing).toHaveBeenCalledWith(
      ['saved-original'],
      JobName.AssetCompressStorageSaver,
      expect.any(Date),
    );
    expect(mocks.asset.advanceUploadProcessing).not.toHaveBeenCalled();
  });

  it('leaves a large backlog in PostgreSQL when execution windows are full', async () => {
    mocks.job.getJobCounts.mockResolvedValue({ ...emptyCounts, waiting: 500_000 });

    await sut.recover();

    expect(mocks.asset.getPendingUploadProcessing).not.toHaveBeenCalled();
    expect(mocks.job.queueAll).not.toHaveBeenCalled();
    expect(mocks.asset.advanceUploadProcessing).not.toHaveBeenCalled();
  });

  it('counts active, paused and delayed work against the bounded Redis window', async () => {
    mocks.job.getJobCounts.mockResolvedValue({ ...emptyCounts, active: 4, paused: 80, delayed: 10, waiting: 3 });

    await sut.recover();

    expect(mocks.asset.getPendingUploadProcessing).toHaveBeenCalledWith(JobName.AssetCompressStorageSaver, 3);
    expect(mocks.asset.getPendingUploadProcessing).toHaveBeenCalledWith(JobName.AssetExtractMetadata, 3);
  });

  it('does not defer or acknowledge a durable row when Redis is unavailable', async () => {
    mocks.asset.getPendingUploadProcessing.mockResolvedValue([{ assetId: 'saved-original' }]);
    mocks.job.queueAll.mockRejectedValue(new Error('Redis is unavailable'));

    await expect(sut.recover()).rejects.toThrow('Redis is unavailable');

    expect(mocks.asset.deferUploadProcessing).not.toHaveBeenCalled();
    expect(mocks.asset.advanceUploadProcessing).not.toHaveBeenCalled();
  });

  it('coalesces simultaneous recovery requests', async () => {
    const first = sut.recover();
    const second = sut.recover();
    expect(second).toBe(first);
    await Promise.all([first, second]);
    expect(mocks.job.getJobCounts).toHaveBeenCalledTimes(5);
  });

  it('persists the next stage only after compression succeeds', async () => {
    await sut.onJobSuccess({
      job: { name: JobName.AssetCompressStorageSaverVideo, data: { id: 'video', durableUpload: true } },
      response: JobStatus.Success,
    });

    expect(mocks.asset.advanceUploadProcessing).toHaveBeenCalledExactlyOnceWith(
      'video',
      JobName.AssetCompressStorageSaverVideo,
      JobName.AssetExtractMetadata,
    );
  });

  it('retains failed compression for retry instead of admitting metadata', async () => {
    await sut.onJobSuccess({
      job: { name: JobName.AssetCompressStorageSaver, data: { id: 'image', durableUpload: true } },
      response: JobStatus.Failed,
    });

    expect(mocks.asset.advanceUploadProcessing).not.toHaveBeenCalled();
    expect(mocks.asset.deferUploadProcessing).toHaveBeenCalledWith(
      ['image'],
      JobName.AssetCompressStorageSaver,
      expect.any(Date),
    );
  });

  it('continues after the metadata handler persists data and returns void', async () => {
    await sut.onJobSuccess({
      job: { name: JobName.AssetExtractMetadata, data: { id: 'image', source: 'upload', durableUpload: true } },
    });

    expect(mocks.asset.advanceUploadProcessing).toHaveBeenCalledExactlyOnceWith(
      'image',
      JobName.AssetExtractMetadata,
      JobName.StorageTemplateMigrationSingle,
    );
  });

  it('removes the marker only after thumbnail completion', async () => {
    await sut.onJobSuccess({
      job: { name: JobName.AssetGenerateThumbnails, data: { id: 'image', source: 'upload', durableUpload: true } },
      response: JobStatus.Success,
    });

    expect(mocks.asset.advanceUploadProcessing).toHaveBeenCalledExactlyOnceWith(
      'image',
      JobName.AssetGenerateThumbnails,
      undefined,
    );
  });

  it('keeps an interrupted job durable and retries it later', async () => {
    await sut.onJobError({
      job: { name: JobName.AssetGenerateThumbnails, data: { id: 'image', source: 'upload', durableUpload: true } },
      error: new Error('worker interrupted'),
    });

    expect(mocks.asset.advanceUploadProcessing).not.toHaveBeenCalled();
    expect(mocks.asset.deferUploadProcessing).toHaveBeenCalledWith(
      ['image'],
      JobName.AssetGenerateThumbnails,
      expect.any(Date),
    );
  });

  it('starts automatic reconciliation at bootstrap and stops its timer on shutdown', async () => {
    await sut.onBootstrap();
    expect(mocks.cron.create).toHaveBeenCalledWith(
      expect.objectContaining({ expression: '*/10 * * * * *', start: true }),
    );
    expect(mocks.job.getJobCounts).toHaveBeenCalledWith(QueueName.StorageSaverCompression);
    sut.onShutdown();
    expect(mocks.cron.update).toHaveBeenCalledWith({ name: 'durable-upload-processing', start: false });
  });
});
