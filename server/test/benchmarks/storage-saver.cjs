/*
 * Reproducible CPU benchmark against the pre-optimization implementation.
 * Build first, then run from server/: node test/benchmarks/storage-saver.cjs [output-directory]
 * Requires ffmpeg/ffprobe. Synthetic textures and moving test patterns are
 * intentionally explicit: these results are not measurements of a user's PC.
 */
const { execFileSync } = require('node:child_process');
const fs = require('node:fs/promises');
const Module = require('node:module');
const os = require('node:os');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const sharp = require('sharp');
const { exiftool } = require('exiftool-vendored');

const serverRoot = process.env.BENCHMARK_SERVER_ROOT || path.resolve(__dirname, '../..');
const { MediaRepository } = require(path.join(serverRoot, 'dist/repositories/media.repository'));
const baseRef = process.env.BENCHMARK_BASE_REF || '67b8d77eb710211b13dc7a7ef469054b98962657';
const directory = path.resolve(process.argv[2] || path.join(os.tmpdir(), 'inhouse-storage-saver-benchmark'));
const repetitions = 3;
const logger = { setContext() {}, debug() {}, warn: console.warn };
const median = (values) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];

function loadBaseline() {
  if (process.env.BENCHMARK_BASELINE_MODULE) {
    return new (require(process.env.BENCHMARK_BASELINE_MODULE).MediaRepository)(logger);
  }
  const swc = require('@swc/core');
  const source = execFileSync('git', ['show', `${baseRef}:server/src/repositories/media.repository.ts`], {
    cwd: serverRoot,
    encoding: 'utf8',
  }).replaceAll(/from 'src\/([^']+)'/g, (_, name) => `from '${path.join(serverRoot, 'dist', name)}'`);
  const { code } = swc.transformSync(source, {
    jsc: {
      parser: { syntax: 'typescript', decorators: true },
      transform: { legacyDecorator: true, decoratorMetadata: true },
      target: 'es2022',
    },
    module: { type: 'commonjs' },
  });
  const baseline = new Module(path.join(serverRoot, 'baseline-benchmark.cjs'), module);
  baseline.filename = baseline.id;
  baseline.paths = module.paths;
  baseline._compile(code, baseline.filename);
  return new baseline.exports.MediaRepository(logger);
}

async function createPhoto(filename, width, height, orientation) {
  let seed = 12345;
  const pixels = Buffer.alloc(width * height * 3);
  for (let index = 0; index < pixels.length; index++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    pixels[index] = seed >>> 24;
  }
  await sharp(pixels, { raw: { width, height, channels: 3 } })
    .blur(1.1)
    .jpeg({ quality: 96 })
    .withMetadata({ orientation })
    .withExifMerge({ IFD0: { Make: 'Benchmark Camera' }, IFD2: { DateTimeOriginal: '2026:01:02 03:04:05' } })
    .toFile(filename);
}

function createVideo(filename, width, height, crf) {
  execFileSync('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    `testsrc2=size=${width}x${height}:rate=30`,
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=1000:sample_rate=48000',
    '-t',
    '6',
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-crf',
    String(crf),
    '-threads',
    '2',
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-metadata',
    'creation_time=2026-01-02T03:04:05Z',
    '-y',
    filename,
  ]);
}

async function measure(repository, sample, label) {
  const times = [];
  let encoded;
  const output = path.join(directory, `${sample.name}-${label}${sample.image ? '.jpg' : '.mp4'}`);
  for (let iteration = 0; iteration <= repetitions; iteration++) {
    const start = performance.now();
    encoded = sample.image
      ? await repository.compressStorageSaverImage(sample.input, output, sample.bytes)
      : await repository.compressStorageSaverVideo(sample.input, output);
    // Warm each implementation before recording steady-state timings.
    if (iteration > 0) times.push(performance.now() - start);
  }
  return {
    milliseconds: median(times),
    samples: times,
    encoded: encoded !== false,
    bytes: encoded === false ? sample.bytes : (await fs.stat(output)).size,
    output: encoded === false ? sample.input : output,
  };
}

async function validateOutput(sample, output) {
  if (sample.image) {
    const metadata = await sharp(output).metadata();
    if (metadata.orientation !== 1 || metadata.width * metadata.height > 16_000_000) {
      throw new Error(`Invalid orientation or pixel budget for ${sample.name}`);
    }
    const tags = await exiftool.read(output);
    if (tags.Make !== 'Benchmark Camera' || !tags.DateTimeOriginal) throw new Error('Capture metadata was lost');
    return { width: metadata.width, height: metadata.height, orientation: metadata.orientation };
  }
  const info = JSON.parse(
    execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output], {
      encoding: 'utf8',
    }),
  );
  const video = info.streams.find((stream) => stream.codec_type === 'video');
  const audio = info.streams.find((stream) => stream.codec_type === 'audio');
  if (
    video.width > sample.width ||
    video.height > sample.height ||
    video.codec_name !== 'h264' ||
    audio?.codec_name !== 'aac'
  ) {
    throw new Error(`Incompatible or enlarged video for ${sample.name}`);
  }
  if (!info.format.tags?.creation_time) throw new Error('Video capture metadata was lost');
  return { width: video.width, height: video.height, codec: video.codec_name, duration: Number(info.format.duration) };
}

async function main() {
  await fs.mkdir(directory, { recursive: true });
  const samples = [
    { name: 'jpeg-12mp', image: true, width: 4032, height: 3024, orientation: 6 },
    { name: 'jpeg-24mp', image: true, width: 6000, height: 4000, orientation: 1 },
    { name: 'jpeg-24mp-rotated', image: true, width: 6000, height: 4000, orientation: 6 },
    { name: 'video-1080p', image: false, width: 1920, height: 1080, crf: 17 },
    { name: 'video-720p', image: false, width: 1280, height: 720, crf: 17 },
    { name: 'video-efficient-720p', image: false, width: 1280, height: 720, crf: 38 },
  ];
  const baseline = loadBaseline();
  const candidate = new MediaRepository(logger);
  const results = [];
  for (const sample of samples) {
    sample.input = path.join(directory, `${sample.name}${sample.image ? '.jpg' : '.mp4'}`);
    if (sample.image) await createPhoto(sample.input, sample.width, sample.height, sample.orientation);
    else createVideo(sample.input, sample.width, sample.height, sample.crf);
    sample.bytes = (await fs.stat(sample.input)).size;
    const old = await measure(baseline, sample, 'baseline');
    const current = await measure(candidate, sample, 'candidate');
    const dimensions = await validateOutput(sample, current.output);
    const result = {
      name: sample.name,
      inputBytes: sample.bytes,
      baseline: old,
      candidate: current,
      speedup: old.milliseconds / current.milliseconds,
      dimensions,
      baselineDimensions: sample.image
        ? (({ width, height }) => ({ width, height }))(await sharp(old.output).metadata())
        : undefined,
    };
    results.push(result);
    console.log(
      `${sample.name}: ${result.speedup.toFixed(2)}x (${old.milliseconds.toFixed(0)} -> ${current.milliseconds.toFixed(0)} ms), ${current.encoded ? 'encoded' : 'kept original'}`,
    );
  }
  const encoded = results.filter((result) => result.candidate.encoded);
  const sumTime = (items, key) => items.reduce((sum, result) => sum + result[key].milliseconds, 0);
  const report = {
    baselineRef: baseRef,
    cpus: os.availableParallelism(),
    sharp: sharp.versions,
    repetitions,
    // One of each synthetic file, measured serially with warmed encoders.
    batchSpeedup: sumTime(results, 'baseline') / sumTime(results, 'candidate'),
    encodedBatchSpeedup: sumTime(encoded, 'baseline') / sumTime(encoded, 'candidate'),
    results,
  };
  await fs.writeFile(path.join(directory, 'results.json'), JSON.stringify(report, null, 2));
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => exiftool.end());
