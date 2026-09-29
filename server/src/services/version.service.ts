import { Injectable } from '@nestjs/common';
import semver, { SemVer } from 'semver';
import { serverVersion } from 'src/constants';
import { OnEvent, OnJob } from 'src/decorators';
import { ServerVersionResponseDto } from 'src/dtos/server.dto';
import { DatabaseLock, ImmichWorker, JobName, JobStatus, QueueName } from 'src/enum';
import { ArgOf } from 'src/repositories/event.repository';
import { BaseService } from 'src/services/base.service';

@Injectable()
export class VersionService extends BaseService {
  @OnEvent({ name: 'AppBootstrap', workers: [ImmichWorker.Microservices] })
  async onBootstrap(): Promise<void> {
    await this.databaseRepository.withLock(DatabaseLock.VersionHistory, async () => {
      const previous = await this.versionRepository.getLatest();
      const current = serverVersion.toString();

      if (!previous) {
        await this.versionRepository.create({ version: current });
        return;
      }

      if (previous.version !== current) {
        const previousVersion = new SemVer(previous.version);

        this.logger.log(`Adding ${current} to upgrade history`);
        await this.versionRepository.create({ version: current });

        const isNeedsNewMemories = semver.lt(previousVersion, '1.129.0');
        if (isNeedsNewMemories) {
          await this.jobRepository.queue({ name: JobName.MemoryGenerate });
        }
      }
    });
  }

  getVersion() {
    return ServerVersionResponseDto.fromSemVer(serverVersion);
  }

  getVersionHistory() {
    return this.versionRepository.getAll();
  }

  // Keep the job handler so version-check jobs left in the queue by earlier builds are safely consumed.
  @OnJob({ name: JobName.VersionCheck, queue: QueueName.BackgroundTask })
  async handleVersionCheck(): Promise<JobStatus> {
    return JobStatus.Skipped;
  }

  @OnEvent({ name: 'WebsocketConnect' })
  async onWebsocketConnection({ userId }: ArgOf<'WebsocketConnect'>) {
    this.websocketRepository.clientSend(
      'on_server_version',
      userId,
      ServerVersionResponseDto.fromSemVer(serverVersion),
    );
  }
}
