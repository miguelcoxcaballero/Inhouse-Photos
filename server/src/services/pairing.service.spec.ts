import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { AuthDto } from 'src/dtos/auth.dto';
import { CryptoRepository } from 'src/repositories/crypto.repository';
import { SessionRepository } from 'src/repositories/session.repository';
import { UserRepository } from 'src/repositories/user.repository';
import { LoginDetails } from 'src/services/auth.service';
import { PairingService } from 'src/services/pairing.service';
import { UserFactory } from 'test/factories/user.factory';
import { factory } from 'test/small.factory';
import { vi } from 'vitest';

const details: LoginDetails = {
  clientIp: '127.0.0.1',
  deviceType: 'Chrome',
  deviceOS: 'Windows',
  appVersion: null,
  isSecure: true,
};

describe(PairingService.name, () => {
  let service: PairingService;
  let auth: AuthDto;
  let userRepository: { get: ReturnType<typeof vi.fn> };
  let sessionRepository: { get: ReturnType<typeof vi.fn>; create: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    auth = factory.auth({ user: { isAdmin: true }, session: {} });
    userRepository = { get: vi.fn().mockResolvedValue(UserFactory.create({ id: auth.user.id, isAdmin: true })) };
    sessionRepository = {
      get: vi.fn().mockResolvedValue({ id: auth.session!.id, expiresAt: null }),
      create: vi.fn().mockResolvedValue({ id: 'new-session-id' }),
    };
    service = new PairingService(
      new CryptoRepository(),
      sessionRepository as unknown as SessionRepository,
      userRepository as unknown as UserRepository,
    );
  });

  it('requires a real admin session instead of an API key or non-admin session', () => {
    const apiKeyAuth = factory.auth({ user: { isAdmin: true }, apiKey: {} });
    const nonAdminAuth = factory.auth({ user: { isAdmin: false }, session: {} });

    expect(() => service.start(apiKeyAuth, details)).toThrow(ForbiddenException);
    expect(() => service.start(nonAdminAuth, details)).toThrow(ForbiddenException);
  });

  it('requires independent confirmations, binds the invite to the PC session, and redeems only once', async () => {
    const { invite } = service.start(auth, details);
    expect(invite).toMatch(/^[\w-]{43}$/);
    expect(service.status(auth, invite).status).toBe('pending');

    const claim = await service.claim(invite, 'Pixel 9', details.clientIp);
    expect(claim.claimToken).toMatch(/^[\w-]{43}$/);
    expect(claim.pcDeviceName).toBe('Chrome on Windows');
    expect(claim.code).toMatch(/^\d{6}$/);
    expect(service.status(auth, invite)).toMatchObject({ status: 'claimed', code: claim.code, deviceName: 'Pixel 9' });
    expect(() => service.phoneStatus(invite, 'x'.repeat(43), details.clientIp)).toThrow(BadRequestException);
    expect(() => service.confirmPc(factory.auth({ user: { isAdmin: true }, session: {} }), invite, claim.code)).toThrow(
      ForbiddenException,
    );

    await expect(service.redeem(invite, claim.claimToken, details)).rejects.toThrow('Pairing is not ready');
    expect(service.confirmPhone(invite, claim.claimToken, claim.code, details.clientIp).status).toBe('phone-confirmed');
    expect(service.confirmPc(auth, invite, claim.code).status).toBe('ready');
    expect(service.phoneStatus(invite, claim.claimToken, details.clientIp).status).toBe('ready');

    const first = service.redeem(invite, claim.claimToken, details);
    const second = service.redeem(invite, claim.claimToken, details);
    const response = await first;
    await expect(second).rejects.toThrow('Pairing is not ready');
    expect(response.accessToken).toMatch(/^[\w-]{43}$/);
    expect(response.userId).toBe(auth.user.id);
    expect(service.status(auth, invite).status).toBe('redeemed');
    expect(sessionRepository.create).toHaveBeenCalledTimes(1);
    expect(sessionRepository.create).toHaveBeenCalledWith(
      expect.objectContaining({ userId: auth.user.id, deviceType: 'Pixel 9' }),
    );
    expect(sessionRepository.create.mock.calls[0][0]).not.toHaveProperty('parentId');
  });

  it('expires a claimed invite after three minutes, even with both confirmations', async () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date('2026-09-29T12:00:00.000Z'));
      const { invite } = service.start(auth, details);
      const claim = await service.claim(invite, undefined, details.clientIp);
      service.confirmPhone(invite, claim.claimToken, claim.code, details.clientIp);
      service.confirmPc(auth, invite, claim.code);

      vi.setSystemTime(new Date('2026-09-29T12:03:00.000Z'));
      expect(service.status(auth, invite).status).toBe('expired');
      await expect(service.redeem(invite, claim.claimToken, details)).rejects.toThrow(
        'Invalid or expired pairing invite',
      );
      expect(sessionRepository.create).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it('invalidates the invite if the initiating PC session was revoked', async () => {
    const { invite } = service.start(auth, details);
    const claim = await service.claim(invite, undefined, details.clientIp);
    service.confirmPhone(invite, claim.claimToken, claim.code, details.clientIp);
    service.confirmPc(auth, invite, claim.code);
    sessionRepository.get.mockResolvedValue(undefined);

    await expect(service.redeem(invite, claim.claimToken, details)).rejects.toThrow(
      'Pairing invite is no longer available',
    );
    expect(service.status(auth, invite).status).toBe('failed');
    expect(sessionRepository.create).not.toHaveBeenCalled();
  });

  it('rejects a claim after the initiating PC session was revoked', async () => {
    const { invite } = service.start(auth, details);
    sessionRepository.get.mockResolvedValue(undefined);

    await expect(service.claim(invite, undefined, details.clientIp)).rejects.toThrow(
      'Pairing invite is no longer available',
    );
    expect(service.status(auth, invite).status).toBe('failed');
  });

  it('rejects mismatched confirmation codes', async () => {
    const { invite } = service.start(auth, details);
    const claim = await service.claim(invite, undefined, details.clientIp);
    const incorrect = claim.code === '000000' ? '000001' : '000000';

    expect(() => service.confirmPhone(invite, claim.claimToken, incorrect, details.clientIp)).toThrow(
      'Pairing confirmation failed',
    );
    expect(() => service.confirmPc(auth, invite, incorrect)).toThrow('Pairing confirmation failed');
    expect(service.status(auth, invite).status).toBe('claimed');
  });

  it('allows the initiating PC to cancel before redemption', async () => {
    const { invite } = service.start(auth, details);
    service.cancel(auth, invite);
    expect(service.status(auth, invite).status).toBe('cancelled');
    await expect(service.claim(invite, undefined, details.clientIp)).rejects.toThrow(
      'Pairing invite is no longer available',
    );
  });
});
