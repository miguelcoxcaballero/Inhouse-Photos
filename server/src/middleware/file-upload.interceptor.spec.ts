import { Reflector } from '@nestjs/core';
import { createHash } from 'node:crypto';
import { PassThrough, Writable } from 'node:stream';
import { UploadFieldName } from 'src/dtos/asset-media.dto';
import { AuthRequest } from 'src/middleware/auth.guard';
import { FileUploadInterceptor } from 'src/middleware/file-upload.interceptor';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { StorageRepository } from 'src/repositories/storage.repository';
import { AssetMediaService } from 'src/services/asset-media.service';
import { ImmichFile } from 'src/types';
import { authStub } from 'test/fixtures/auth.stub';
import { automock, mockBaseService } from 'test/utils';

describe(FileUploadInterceptor.name, () => {
  const logger = automock(LoggingRepository, { strict: false });
  const assetService = mockBaseService(AssetMediaService);
  const storage = automock(StorageRepository, { args: [logger] });
  let sut: FileUploadInterceptor;
  let request: AuthRequest;
  let file: Express.Multer.File & { stream: PassThrough };

  beforeEach(() => {
    assetService.resetAllMocks();
    storage.resetAllMocks();
    logger.resetAllMocks();
    assetService.getUploadFolder.mockReturnValue('/data/upload');
    assetService.getUploadFilename.mockReturnValue('image.jpg');
    assetService.onUploadError.mockResolvedValue(undefined);
    request = Object.assign(new PassThrough(), { user: authStub.admin, body: {} }) as unknown as AuthRequest;
    // Express continues to own request errors after the upload interceptor
    // removes its own listener.
    request.on('error', vi.fn());
    file = {
      fieldname: UploadFieldName.ASSET_DATA,
      originalname: 'image.jpg',
      stream: new PassThrough(),
      encoding: '7bit',
      mimetype: 'image/jpeg',
      size: 0,
      destination: '',
      filename: '',
      path: '',
      buffer: Buffer.alloc(0),
    };
    sut = new FileUploadInterceptor(new Reflector(), assetService, storage, logger);
  });

  const receive = (sut: FileUploadInterceptor, request: AuthRequest, file: Express.Multer.File) =>
    new Promise<{ error: Error | null; result?: Partial<ImmichFile> }>((resolve) => {
      sut['handleFile'](request, file, (error: Error | null, result?: Partial<ImmichFile>) =>
        resolve({ error, result }),
      );
    });

  it('preserves a completed upload when the phone disconnects after receipt', async () => {
    const chunks: Buffer[] = [];
    storage.createWriteStream.mockReturnValue(
      new Writable({
        write(chunk: Buffer, _encoding, callback) {
          chunks.push(chunk);
          callback();
        },
      }),
    );
    const original = Buffer.from('the uploaded original');
    const received = receive(sut, request, file);
    file.stream.end(original);
    const { error, result } = await received;

    expect(error).toBeNull();
    expect(Buffer.concat(chunks)).toEqual(original);
    expect(result).toMatchObject({
      path: '/data/upload/image.jpg',
      size: original.length,
      checksum: createHash('sha1').update(original).digest(),
    });
    expect(request.listenerCount('error')).toBe(1);

    request.emit('error', Object.assign(new Error('Phone disconnected'), { code: 'ECONNRESET' }));
    await Promise.resolve();

    expect(assetService.onUploadError).not.toHaveBeenCalled();
  });

  it('cleans an interrupted partial upload after closing its stream', async () => {
    const target = new PassThrough();
    storage.createWriteStream.mockReturnValue(target);
    const received = receive(sut, request, file);
    file.stream.write(Buffer.from('partial original'));
    const error = Object.assign(new Error('Phone disconnected'), { code: 'ECONNRESET' });

    request.emit('error', error);

    const result = await received;
    expect(result.error).toBe(error);
    expect(target.destroyed).toBe(true);
    expect(assetService.onUploadError).toHaveBeenCalledExactlyOnceWith(request, file);
    expect(request.listenerCount('error')).toBe(1);
  });

  it('does not acknowledge or retain a partial file when server storage is full', async () => {
    const error = Object.assign(new Error('No space left on device'), { code: 'ENOSPC' });
    storage.createWriteStream.mockReturnValue(
      new Writable({
        write(_chunk, _encoding, callback) {
          callback(error);
        },
      }),
    );
    const received = receive(sut, request, file);
    file.stream.end(Buffer.from('original'));

    const result = await received;
    expect(result.error).toBe(error);
    expect(assetService.onUploadError).toHaveBeenCalledExactlyOnceWith(request, file);
    expect(request.listenerCount('error')).toBe(1);
  });

  it('cleans and rejects empty uploads', async () => {
    storage.createWriteStream.mockReturnValue(new PassThrough());
    const received = receive(sut, request, file);
    file.stream.end();

    const result = await received;
    expect(result.error?.message).toBe('File is empty');
    expect(assetService.onUploadError).toHaveBeenCalledExactlyOnceWith(request, file);
    expect(request.listenerCount('error')).toBe(1);
  });
});
