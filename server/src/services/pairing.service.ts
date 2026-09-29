import { BadRequestException, ForbiddenException, HttpException, HttpStatus, Injectable } from '@nestjs/common';
import { timingSafeEqual } from 'node:crypto';
import { AuthDto, LoginResponseDto, mapLoginResponse } from 'src/dtos/auth.dto';
import { PairingClaimResponseDto, PairingStartResponseDto, PairingStatusResponseDto } from 'src/dtos/pairing.dto';
import { CryptoRepository } from 'src/repositories/crypto.repository';
import { SessionRepository } from 'src/repositories/session.repository';
import { UserRepository } from 'src/repositories/user.repository';
import { LoginDetails } from 'src/services/auth.service';

type PairingStatus = PairingStatusResponseDto['status'];

interface PairingInvite {
  userId: string;
  pcSessionId: string;
  pcDeviceName: string;
  expiresAt: number;
  status: PairingStatus;
  code?: string;
  claimTokenHash?: Buffer;
  deviceName?: string;
  pcConfirmed: boolean;
  phoneConfirmed: boolean;
}

interface RateBucket {
  count: number;
  expiresAt: number;
}

/**
 * Pairing state deliberately lives only in this API process. A server restart
 * invalidates every outstanding invite; deployments with multiple API replicas
 * must replace this store with shared atomic storage before enabling pairing.
 */
@Injectable()
export class PairingService {
  private static readonly ttlMs = 3 * 60 * 1000;
  private static readonly maxInvites = 1000;
  private static readonly maxRateBuckets = 10_000;
  private readonly invites = new Map<string, PairingInvite>();
  private readonly rateBuckets = new Map<string, RateBucket>();

  constructor(
    private cryptoRepository: CryptoRepository,
    private sessionRepository: SessionRepository,
    private userRepository: UserRepository,
  ) {}

  start(auth: AuthDto, details: LoginDetails): PairingStartResponseDto {
    const pcSessionId = this.requireAdminSession(auth);
    this.sweep();
    this.limit(`start:${pcSessionId}`, 5);

    if (this.invites.size >= PairingService.maxInvites) {
      throw new HttpException('Too many pending pairing invites', HttpStatus.TOO_MANY_REQUESTS);
    }

    let activeCount = 0;
    for (const item of this.invites.values()) {
      if (item.pcSessionId === pcSessionId && item.expiresAt > Date.now() && !this.isTerminal(item.status)) {
        activeCount++;
      }
    }
    if (activeCount >= 3) {
      throw new HttpException('Too many pending pairing invites for this session', HttpStatus.TOO_MANY_REQUESTS);
    }

    const invite = this.newSecret();
    const expiresAt = Date.now() + PairingService.ttlMs;
    this.invites.set(this.key(invite), {
      userId: auth.user.id,
      pcSessionId,
      pcDeviceName: [details.deviceType, details.deviceOS].filter(Boolean).join(' on ') || 'Computer',
      expiresAt,
      status: 'pending',
      pcConfirmed: false,
      phoneConfirmed: false,
    });

    return { invite, expiresAt: new Date(expiresAt).toISOString() };
  }

  async claim(invite: string, deviceName: string | undefined, clientIp: string): Promise<PairingClaimResponseDto> {
    this.sweep();
    this.limit(`claim:${clientIp}`, 20);
    const item = this.get(invite);
    if (item.status !== 'pending') {
      throw new BadRequestException('Pairing invite is no longer available');
    }

    const pcSession = await this.sessionRepository.get(item.pcSessionId);
    const user = await this.userRepository.get(item.userId, {});
    if (!pcSession || (pcSession.expiresAt && pcSession.expiresAt <= new Date()) || !user?.isAdmin) {
      item.status = 'failed';
      throw new BadRequestException('Pairing invite is no longer available');
    }
    // Two simultaneous claims may both wait for the user lookup. Only the
    // first one to resume is allowed to bind this invite to a phone.
    if (item.status !== 'pending' || item.expiresAt <= Date.now()) {
      throw new BadRequestException('Pairing invite is no longer available');
    }

    const claimToken = this.newSecret();
    const code = String(this.cryptoRepository.randomBytes(4).readUInt32BE(0) % 1_000_000).padStart(6, '0');
    item.claimTokenHash = this.cryptoRepository.hashSha256(claimToken);
    item.code = code;
    item.deviceName = deviceName || 'Mobile device';
    item.status = 'claimed';

    return {
      claimToken,
      code,
      accountName: user.name,
      accountEmail: user.email,
      pcDeviceName: item.pcDeviceName,
      expiresAt: new Date(item.expiresAt).toISOString(),
    };
  }

  status(auth: AuthDto, invite: string): PairingStatusResponseDto {
    const item = this.get(invite, true);
    this.requireOwner(auth, item);
    return this.mapStatus(item);
  }

  phoneStatus(invite: string, claimToken: string, clientIp: string): PairingStatusResponseDto {
    this.sweep();
    this.limit(`poll:${clientIp}`, 120);
    const item = this.get(invite, true);
    this.requireClaim(item, claimToken);
    return this.mapStatus(item);
  }

  confirmPhone(invite: string, claimToken: string, code: string, clientIp: string): PairingStatusResponseDto {
    this.sweep();
    this.limit(`confirm:${clientIp}`, 20);
    const item = this.get(invite);
    this.requireClaim(item, claimToken);
    if (this.isTerminal(item.status) || item.status === 'pending' || code !== item.code) {
      throw new BadRequestException('Pairing confirmation failed');
    }

    item.phoneConfirmed = true;
    this.updateStatus(item);
    return this.mapStatus(item);
  }

  confirmPc(auth: AuthDto, invite: string, code: string): PairingStatusResponseDto {
    const item = this.get(invite);
    this.requireOwner(auth, item);
    if (this.isTerminal(item.status) || item.status === 'pending' || code !== item.code) {
      throw new BadRequestException('Pairing confirmation failed');
    }

    item.pcConfirmed = true;
    this.updateStatus(item);
    return this.mapStatus(item);
  }

  async redeem(invite: string, claimToken: string, details: LoginDetails): Promise<LoginResponseDto> {
    this.sweep();
    this.limit(`redeem:${details.clientIp}`, 20);
    const item = this.get(invite);
    this.requireClaim(item, claimToken);
    if (item.status !== 'ready') {
      throw new BadRequestException('Pairing is not ready');
    }

    // Claim the one-use invite synchronously, before the first await. Another
    // request cannot mint a second session while database work is in flight.
    item.status = 'redeemed';
    try {
      const pcSession = await this.sessionRepository.get(item.pcSessionId);
      const user = await this.userRepository.get(item.userId, {});
      if (
        item.expiresAt <= Date.now() ||
        !pcSession ||
        (pcSession.expiresAt && pcSession.expiresAt <= new Date()) ||
        !user?.isAdmin
      ) {
        throw new BadRequestException('Pairing invite is no longer available');
      }

      const token = this.newSecret();
      await this.sessionRepository.create({
        token: this.cryptoRepository.hashSha256(token),
        userId: item.userId,
        deviceType: item.deviceName || details.deviceType,
        deviceOS: details.deviceOS,
        appVersion: details.appVersion,
      });
      return mapLoginResponse(user, token);
    } catch (error: Error | any) {
      item.status = 'failed';
      throw error;
    }
  }

  cancel(auth: AuthDto, invite: string): void {
    const item = this.get(invite);
    this.requireOwner(auth, item);
    if (item.status === 'redeemed') {
      throw new BadRequestException('Pairing has already been redeemed');
    }
    item.status = 'cancelled';
  }

  private requireAdminSession(auth: AuthDto): string {
    if (!auth.session || !auth.user.isAdmin) {
      throw new ForbiddenException('An admin session is required');
    }
    return auth.session.id;
  }

  private requireOwner(auth: AuthDto, item: PairingInvite): void {
    const sessionId = this.requireAdminSession(auth);
    if (sessionId !== item.pcSessionId || auth.user.id !== item.userId) {
      throw new ForbiddenException('Pairing invite belongs to another session');
    }
  }

  private requireClaim(item: PairingInvite, claimToken: string): void {
    const providedHash = this.cryptoRepository.hashSha256(claimToken);
    if (!item.claimTokenHash || !timingSafeEqual(item.claimTokenHash, providedHash)) {
      throw new BadRequestException('Invalid pairing claim');
    }
  }

  private key(invite: string): string {
    return this.cryptoRepository.hashSha256(invite).toString('hex');
  }

  private newSecret(): string {
    return this.cryptoRepository.randomBytes(32).toString('base64url');
  }

  private get(invite: string, allowExpired = false): PairingInvite {
    const item = this.invites.get(this.key(invite));
    if (!item) {
      throw new BadRequestException('Invalid or expired pairing invite');
    }
    if (item.expiresAt <= Date.now() && !this.isTerminal(item.status)) {
      item.status = 'expired';
    }
    if (!allowExpired && item.status === 'expired') {
      throw new BadRequestException('Invalid or expired pairing invite');
    }
    return item;
  }

  private updateStatus(item: PairingInvite): void {
    item.status =
      item.phoneConfirmed && item.pcConfirmed ? 'ready' : item.phoneConfirmed ? 'phone-confirmed' : 'pc-confirmed';
  }

  private mapStatus(item: PairingInvite): PairingStatusResponseDto {
    return {
      status: item.status,
      code: item.code,
      deviceName: item.deviceName,
      expiresAt: new Date(item.expiresAt).toISOString(),
    };
  }

  private isTerminal(status: PairingStatus): boolean {
    return ['redeemed', 'cancelled', 'failed', 'expired'].includes(status);
  }

  private limit(key: string, maximum: number): void {
    const now = Date.now();
    const bucket = this.rateBuckets.get(key);
    if (!bucket || bucket.expiresAt <= now) {
      if (this.rateBuckets.size >= PairingService.maxRateBuckets) {
        throw new HttpException('Too many pairing attempts', HttpStatus.TOO_MANY_REQUESTS);
      }
      this.rateBuckets.set(key, { count: 1, expiresAt: now + PairingService.ttlMs });
      return;
    }
    if (bucket.count >= maximum) {
      throw new HttpException('Too many pairing attempts', HttpStatus.TOO_MANY_REQUESTS);
    }
    bucket.count++;
  }

  private sweep(): void {
    const now = Date.now();
    for (const [key, invite] of this.invites) {
      if (invite.expiresAt + PairingService.ttlMs <= now) {
        this.invites.delete(key);
      }
    }
    for (const [key, bucket] of this.rateBuckets) {
      if (bucket.expiresAt <= now) {
        this.rateBuckets.delete(key);
      }
    }
  }
}
