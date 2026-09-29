import { createZodDto } from 'nestjs-zod';
import z from 'zod';

const InviteSchema = z.string().regex(/^[\w-]{43}$/);
const ClaimTokenSchema = z.string().regex(/^[\w-]{43}$/);
const CodeSchema = z.string().regex(/^\d{6}$/);

const PairingInviteSchema = z.object({ invite: InviteSchema }).meta({ id: 'PairingInviteDto' });
const PairingClaimSchema = PairingInviteSchema.extend({
  deviceName: z.string().trim().min(1).max(120).optional(),
}).meta({ id: 'PairingClaimDto' });
const PairingPhoneActionSchema = PairingInviteSchema.extend({
  claimToken: ClaimTokenSchema,
  code: CodeSchema,
}).meta({ id: 'PairingPhoneActionDto' });
const PairingRedeemSchema = PairingInviteSchema.extend({
  claimToken: ClaimTokenSchema,
}).meta({ id: 'PairingRedeemDto' });
const PairingPcConfirmSchema = PairingInviteSchema.extend({
  code: CodeSchema,
}).meta({ id: 'PairingPcConfirmDto' });

const PairingStatusSchema = z.enum([
  'pending',
  'claimed',
  'phone-confirmed',
  'pc-confirmed',
  'ready',
  'redeemed',
  'cancelled',
  'failed',
  'expired',
]);

const PairingStartResponseSchema = z
  .object({ invite: InviteSchema, expiresAt: z.string() })
  .meta({ id: 'PairingStartResponseDto' });
const PairingClaimResponseSchema = z
  .object({
    claimToken: ClaimTokenSchema,
    code: CodeSchema,
    accountName: z.string(),
    accountEmail: z.string(),
    pcDeviceName: z.string(),
    expiresAt: z.string(),
  })
  .meta({ id: 'PairingClaimResponseDto' });
const PairingStatusResponseSchema = z
  .object({
    status: PairingStatusSchema,
    code: CodeSchema.optional(),
    deviceName: z.string().optional(),
    expiresAt: z.string(),
  })
  .meta({ id: 'PairingStatusResponseDto' });

export class PairingInviteDto extends createZodDto(PairingInviteSchema) {}
export class PairingClaimDto extends createZodDto(PairingClaimSchema) {}
export class PairingPhoneActionDto extends createZodDto(PairingPhoneActionSchema) {}
export class PairingRedeemDto extends createZodDto(PairingRedeemSchema) {}
export class PairingPcConfirmDto extends createZodDto(PairingPcConfirmSchema) {}
export class PairingStartResponseDto extends createZodDto(PairingStartResponseSchema) {}
export class PairingClaimResponseDto extends createZodDto(PairingClaimResponseSchema) {}
export class PairingStatusResponseDto extends createZodDto(PairingStatusResponseSchema) {}
