import { SemVer } from 'semver';
import { defaults } from 'src/config';
import { DatabaseLock, JobStatus } from 'src/enum';
import { VersionService } from 'src/services/version.service';
import { factory } from 'test/small.factory';
import { newTestService, ServiceMocks } from 'test/utils';

describe(VersionService.name, () => {
  let sut: VersionService;
  let mocks: ServiceMocks;

  beforeEach(() => {
    ({ sut, mocks } = newTestService(VersionService));
  });

  vitest.mock(import('src/constants.js'), async (importOriginal) => ({
    ...(await importOriginal()),
    serverVersion: new SemVer('v3.0.0'),
  }));

  it('disables upstream version checks by default', () => {
    expect(defaults.newVersionCheck.enabled).toBe(false);
  });

  describe('onBootstrap', () => {
    it('should record a new version', async () => {
      mocks.versionHistory.getAll.mockResolvedValue([]);
      mocks.versionHistory.getLatest.mockResolvedValue(void 0);
      mocks.versionHistory.create.mockResolvedValue(factory.versionHistory());

      await expect(sut.onBootstrap()).resolves.toBeUndefined();

      expect(mocks.versionHistory.create).toHaveBeenCalledWith({ version: expect.any(String) });
    });

    it('should skip a duplicate version', async () => {
      mocks.versionHistory.getLatest.mockResolvedValue({
        id: 'version-1',
        createdAt: new Date(),
        version: '3.0.0',
      });
      await expect(sut.onBootstrap()).resolves.toBeUndefined();
      expect(mocks.versionHistory.create).not.toHaveBeenCalled();
    });

    it('should keep version history without scheduling an upstream check', async () => {
      mocks.versionHistory.getLatest.mockResolvedValue({
        id: 'version-1',
        createdAt: new Date(),
        version: '3.0.0',
      });

      await sut.onBootstrap();

      expect(mocks.database.withLock).toHaveBeenCalledWith(DatabaseLock.VersionHistory, expect.any(Function));
      expect(mocks.database.tryLock).not.toHaveBeenCalled();
      expect(mocks.cron.create).not.toHaveBeenCalled();
      expect(mocks.job.queue).not.toHaveBeenCalled();
    });
  });

  describe('getVersion', () => {
    it('should respond the server version', () => {
      expect(sut.getVersion()).toEqual({
        major: 3,
        minor: 0,
        patch: 0,
        prerelease: null,
      });
    });
  });

  describe('getVersionHistory', () => {
    it('should respond the server version history', async () => {
      const upgrade = { id: 'upgrade-1', createdAt: new Date(), version: '1.0.0' };
      mocks.versionHistory.getAll.mockResolvedValue([upgrade]);
      await expect(sut.getVersionHistory()).resolves.toEqual([upgrade]);
    });
  });

  describe('handleVersionCheck', () => {
    it('should skip queued checks without reading persisted enabled config or releasing notices', async () => {
      mocks.systemMetadata.get.mockResolvedValue({
        newVersionCheck: { enabled: true },
        checkedAt: '2024-01-01',
        releaseVersion: 'v100.0.0',
      });

      await expect(sut.handleVersionCheck()).resolves.toEqual(JobStatus.Skipped);

      expect(mocks.systemMetadata.get).not.toHaveBeenCalled();
      expect(mocks.systemMetadata.set).not.toHaveBeenCalled();
      expect(mocks.websocket.clientBroadcast).not.toHaveBeenCalled();
    });
  });

  describe('onWebsocketConnection', () => {
    it('should send only the server version, even when stale release metadata exists', async () => {
      mocks.systemMetadata.get.mockResolvedValue({ checkedAt: '2024-01-01', releaseVersion: 'v100.0.0' });

      await sut.onWebsocketConnection({ userId: '42' });

      expect(mocks.websocket.clientSend).toHaveBeenCalledWith('on_server_version', '42', {
        major: 3,
        minor: 0,
        patch: 0,
        prerelease: null,
      });
      expect(mocks.websocket.clientSend).toHaveBeenCalledTimes(1);
      expect(mocks.systemMetadata.get).not.toHaveBeenCalled();
    });
  });
});
