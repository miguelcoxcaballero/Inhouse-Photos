import { availableParallelism, totalmem } from 'node:os';

const GiB = 1024 ** 3;

const boundedInteger = (value: string | undefined, fallback: number, maximum: number) => {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? Math.min(maximum, parsed) : fallback;
};

/** Separate CPU budgets keep long videos from taking every photo worker. */
export const getStorageSaverResources = (
  cpuCount = availableParallelism(),
  memoryBytes = process.constrainedMemory() || totalmem(),
  env: NodeJS.ProcessEnv = process.env,
) => {
  const cpus = Math.max(1, cpuCount);
  // A decoded 16 MP photo plus its encoder buffers can occupy hundreds of MB.
  const imageLimit = Math.min(8, Math.max(1, Math.floor((memoryBytes - GiB) / (GiB / 2))));
  const imageConcurrency = boundedInteger(
    env.INHOUSE_STORAGE_SAVER_CONCURRENCY,
    Math.min(imageLimit, Math.max(1, Math.floor(cpus / 2))),
    imageLimit,
  );
  const videoLimit = Math.min(2, Math.max(1, Math.floor(memoryBytes / (2 * GiB))));
  const videoConcurrency = boundedInteger(
    env.INHOUSE_STORAGE_SAVER_VIDEO_CONCURRENCY,
    Math.min(videoLimit, Math.max(1, Math.floor(cpus / 8))),
    videoLimit,
  );
  // Leave CPU time for accepting uploads, metadata and image workers.
  const videoThreads = Math.max(1, Math.min(4, Math.floor((cpus - 1) / videoConcurrency)));
  return { imageConcurrency, videoConcurrency, videoThreads };
};

/** Keep the quality target; administrators can trade speed for smaller files. */
export const getStorageSaverVideoPreset = (value = process.env.INHOUSE_STORAGE_SAVER_VIDEO_PRESET) =>
  ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'].includes(value ?? '')
    ? value!
    : 'ultrafast';
