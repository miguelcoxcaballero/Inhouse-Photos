import ffmpeg, { FfprobeData } from 'fluent-ffmpeg';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { MediaRepository } from 'src/repositories/media.repository';
import { automock } from 'test/utils';

describe('Storage Saver encoders', () => {
  let sut: MediaRepository;
  let directory: string;

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), 'storage-saver-'));
    // eslint-disable-next-line no-sparse-arrays
    sut = new MediaRepository(automock(LoggingRepository, { args: [, { getEnv: () => ({}) }], strict: false }));
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await rm(directory, { recursive: true, force: true });
  });

  it('preserves capture metadata and normalizes orientation without rotating twice', async () => {
    const input = join(directory, 'rotated.jpg');
    const output = join(directory, 'output.jpg');
    const xmp =
      '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/></x:xmpmeta>';
    await sharp({ create: { width: 800, height: 1200, channels: 3, background: '#ae4523' } })
      .jpeg({ quality: 95 })
      .withMetadata({ orientation: 6 })
      .withExifMerge({ IFD0: { Make: 'Test Camera' }, IFD2: { DateTimeOriginal: '2026:01:02 03:04:05' } })
      .withXmp(xmp)
      .toFile(input);

    // Exercise encoding even though this uniform fixture has few compressed bytes.
    expect(await sut.compressStorageSaverImage(input, output, 300_000)).toBe(true);
    const before = await sharp(input).metadata();
    const after = await sharp(output).metadata();
    expect(before.orientation).toBe(6);
    expect(after).toMatchObject({ width: 1200, height: 800, orientation: 1, format: 'jpeg' });
    expect(after.exif?.includes(Buffer.from('Test Camera'))).toBe(true);
    expect(after.exif?.includes(Buffer.from('2026:01:02 03:04:05'))).toBe(true);
    expect(after.xmp).toEqual(before.xmp);
    expect(after.icc).toEqual(before.icc);
  });

  it('fits a rotated high-resolution photo into 16 MP without halving its dimensions', async () => {
    const input = join(directory, 'large.jpg');
    const output = join(directory, 'output.jpg');
    await sharp({ create: { width: 6000, height: 4000, channels: 3, background: '#227744' } })
      .jpeg()
      .withMetadata({ orientation: 6 })
      .toFile(input);
    const { size } = await stat(input);
    await sut.compressStorageSaverImage(input, output, size);
    const { width, height } = await sharp(output).metadata();
    expect(width! * height!).toBeLessThanOrEqual(16_000_000);
    expect(width! * height!).toBeGreaterThan(15_900_000);
    expect(width! / height!).toBeCloseTo(2 / 3, 3);
  });

  it('does not create an output for an already efficient JPEG', async () => {
    const input = join(directory, 'small.jpg');
    const output = join(directory, 'output.jpg');
    await sharp({ create: { width: 100, height: 100, channels: 3, background: '#227744' } })
      .jpeg()
      .toFile(input);
    const { size } = await stat(input);
    expect(await sut.compressStorageSaverImage(input, output, size)).toBe(false);
    await expect(stat(output)).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('does not re-encode an already efficient H.264/AAC video', async () => {
    vi.spyOn(ffmpeg, 'ffprobe').mockImplementation((...args: unknown[]) => {
      const callback = args.at(-1) as (error: Error | null, data: FfprobeData) => void;
      callback(null, {
        streams: [
          {
            index: 0,
            codec_type: 'video',
            codec_name: 'h264',
            pix_fmt: 'yuv420p',
            width: 1280,
            height: 720,
            bit_rate: '1500000',
          },
          { index: 1, codec_type: 'audio', codec_name: 'aac', bit_rate: '128000' },
        ],
        format: {},
        chapters: [],
      } as FfprobeData);
    });
    const output = join(directory, 'output.mp4');
    expect(await sut.compressStorageSaverVideo(join(directory, 'video.mp4'), output)).toBe(false);
    await expect(stat(output)).rejects.toMatchObject({ code: 'ENOENT' });
  });
});
