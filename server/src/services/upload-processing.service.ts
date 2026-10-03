import { Injectable } from '@nestjs/common';
import { OnEvent } from 'src/decorators';
import { ImmichWorker, JobName, JobStatus, QueueName } from 'src/enum';
import { ArgOf, ArgsOf } from 'src/repositories/event.repository';
import { UploadProcessingJob } from 'src/schema/tables/asset-upload-processing.table';
import { BaseService } from 'src/services/base.service';
import { JobItem } from 'src/types';
import { handlePromiseError } from 'src/utils/misc';

const RECOVERY_CRON = 'durable-upload-processing';
const REDIS_WINDOW = 100;
const RETRY_DELAY_MS = 60_000;
const stages: Array<{ jobName: UploadProcessingJob; queue: QueueName; next?: UploadProcessingJob }> = [
  {
    jobName: JobName.AssetCompressStorageSaver,
    queue: QueueName.StorageSaverCompression,
    next: JobName.AssetExtractMetadata,
  },
  {
    jobName: JobName.AssetCompressStorageSaverVideo,
    queue: QueueName.StorageSaverVideoCompression,
    next: JobName.AssetExtractMetadata,
  },
  {
    jobName: JobName.AssetExtractMetadata,
    queue: QueueName.MetadataExtraction,
    next: JobName.StorageTemplateMigrationSingle,
  },
  {
    jobName: JobName.StorageTemplateMigrationSingle,
    queue: QueueName.StorageTemplateMigration,
    next: JobName.AssetGenerateThumbnails,
  },
  { jobName: JobName.AssetGenerateThumbnails, queue: QueueName.ThumbnailGeneration },
];

const asUploadJob = (name: UploadProcessingJob, id: string): JobItem =>
  name === JobName.AssetCompressStorageSaver || name === JobName.AssetCompressStorageSaverVideo
    ? { name, data: { id, durableUpload: true } }
    : { name, data: { id, source: 'upload', durableUpload: true } };

/** PostgreSQL owns the unlimited backlog; Redis contains only a small execution window. */
@Injectable()
export class UploadProcessingService extends BaseService {
  private recovery?: Promise<void>;

  @OnEvent({ name: 'AppBootstrap', workers: [ImmichWorker.Microservices] })
  async onBootstrap() {
    this.cronRepository.create({
      name: RECOVERY_CRON,
      expression: '*/10 * * * * *',
      start: true,
      onTick: () => handlePromiseError(this.recover(), this.logger),
    });
    await this.recover();
  }

  @OnEvent({ name: 'AppShutdown', workers: [ImmichWorker.Microservices] })
  onShutdown() {
    this.cronRepository.update({ name: RECOVERY_CRON, start: false });
  }

  @OnEvent({ name: 'JobSuccess', workers: [ImmichWorker.Microservices] })
  async onJobSuccess({ job, response }: ArgOf<'JobSuccess'>) {
    const stage = stages.find(({ jobName }) => jobName === job.name);
    if (!stage || !job.data || !('id' in job.data)) {
      return;
    }
    const { id } = job.data;
    if (response === JobStatus.Failed) {
      await this.assetRepository.deferUploadProcessing([id], stage.jobName, new Date(Date.now() + RETRY_DELAY_MS));
      return;
    }
    // Metadata extraction intentionally returns void after persisting the metadata.
    if (response === JobStatus.Success || response === JobStatus.Skipped || job.name === JobName.AssetExtractMetadata) {
      await this.assetRepository.advanceUploadProcessing(id, stage.jobName, stage.next);
    }
  }

  @OnEvent({ name: 'JobError', workers: [ImmichWorker.Microservices] })
  async onJobError({ job }: ArgOf<'JobError'>) {
    const stage = stages.find(({ jobName }) => jobName === job.name);
    if (stage && job.data && 'id' in job.data) {
      await this.assetRepository.deferUploadProcessing(
        [job.data.id],
        stage.jobName,
        new Date(Date.now() + RETRY_DELAY_MS),
      );
    }
  }

  @OnEvent({ name: 'JobComplete', workers: [ImmichWorker.Microservices] })
  onJobComplete(...[, job]: ArgsOf<'JobComplete'>) {
    if (stages.some(({ jobName }) => jobName === job.name)) {
      // Refill promptly without keeping the completed BullMQ job active while scheduling.
      handlePromiseError(this.recover(), this.logger);
    }
  }

  recover(): Promise<void> {
    if (!this.recovery) {
      this.recovery = this.recoverPending().finally(() => {
        this.recovery = undefined;
      });
    }
    return this.recovery;
  }

  private async recoverPending() {
    for (const { jobName, queue } of stages) {
      const counts = await this.jobRepository.getJobCounts(queue);
      const pending = counts.active + counts.waiting + counts.paused + counts.delayed;
      const slots = Math.max(0, REDIS_WINDOW - pending);
      if (slots === 0) {
        continue;
      }
      const rows = await this.assetRepository.getPendingUploadProcessing(jobName, slots);
      if (rows.length === 0) {
        continue;
      }
      await this.jobRepository.queueAll(rows.map(({ assetId }) => asUploadJob(jobName, assetId)));
      // Never mark work before enqueue succeeds. Rows stay durable until the final thumbnail commits.
      await this.assetRepository.deferUploadProcessing(
        rows.map(({ assetId }) => assetId),
        jobName,
        new Date(Date.now() + RETRY_DELAY_MS),
      );
    }
  }
}
