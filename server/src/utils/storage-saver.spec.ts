import { getStorageSaverResources, getStorageSaverVideoPreset } from 'src/utils/storage-saver';

describe('Storage Saver resource budgets', () => {
  const GiB = 1024 ** 3;

  it('limits a small machine to one video while leaving workers for photos', () => {
    expect(getStorageSaverResources(4, 4 * GiB, {})).toEqual({
      imageConcurrency: 2,
      videoConcurrency: 1,
      videoThreads: 3,
    });
  });

  it('allows a compression preset override but never injects arbitrary FFmpeg arguments', () => {
    expect(getStorageSaverVideoPreset('medium')).toBe('medium');
    expect(getStorageSaverVideoPreset('fast -crf 50')).toBe('ultrafast');
  });

  it('uses larger machines without an unbounded number of encoders', () => {
    expect(getStorageSaverResources(32, 32 * GiB, {})).toEqual({
      imageConcurrency: 8,
      videoConcurrency: 2,
      videoThreads: 4,
    });
  });

  it('bounds overrides by memory and rejects malformed settings', () => {
    expect(
      getStorageSaverResources(16, 2 * GiB, {
        INHOUSE_STORAGE_SAVER_CONCURRENCY: '100',
        INHOUSE_STORAGE_SAVER_VIDEO_CONCURRENCY: '100',
      }),
    ).toEqual({ imageConcurrency: 2, videoConcurrency: 1, videoThreads: 4 });
    expect(
      getStorageSaverResources(4, 4 * GiB, {
        INHOUSE_STORAGE_SAVER_CONCURRENCY: '3oops',
        INHOUSE_STORAGE_SAVER_VIDEO_CONCURRENCY: '-2',
      }),
    ).toEqual(getStorageSaverResources(4, 4 * GiB, {}));
  });
});
