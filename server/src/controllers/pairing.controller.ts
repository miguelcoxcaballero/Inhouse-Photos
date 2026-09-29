import { Body, Controller, Header, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Endpoint, HistoryBuilder } from 'src/decorators';
import { AuthDto, LoginResponseDto } from 'src/dtos/auth.dto';
import {
  PairingClaimDto,
  PairingClaimResponseDto,
  PairingInviteDto,
  PairingPcConfirmDto,
  PairingPhoneActionDto,
  PairingRedeemDto,
  PairingStartResponseDto,
  PairingStatusResponseDto,
} from 'src/dtos/pairing.dto';
import { ApiTag } from 'src/enum';
import { Auth, Authenticated, GetLoginDetails } from 'src/middleware/auth.guard';
import { LoginDetails } from 'src/services/auth.service';
import { PairingService } from 'src/services/pairing.service';

@ApiTags(ApiTag.Authentication)
@Controller('auth/pairing')
export class PairingController {
  constructor(private service: PairingService) {}

  @Post('start')
  @Authenticated({ admin: true })
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Start phone pairing', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  start(@Auth() auth: AuthDto, @GetLoginDetails() details: LoginDetails): PairingStartResponseDto {
    return this.service.start(auth, details);
  }

  @Post('claim')
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Claim phone pairing invite', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  claim(@Body() dto: PairingClaimDto, @GetLoginDetails() details: LoginDetails): Promise<PairingClaimResponseDto> {
    return this.service.claim(dto.invite, dto.deviceName, details.clientIp);
  }

  @Post('status')
  @Authenticated({ admin: true })
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Get PC pairing status', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  status(@Auth() auth: AuthDto, @Body() dto: PairingInviteDto): PairingStatusResponseDto {
    return this.service.status(auth, dto.invite);
  }

  @Post('phone-status')
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Get phone pairing status', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  phoneStatus(@Body() dto: PairingRedeemDto, @GetLoginDetails() details: LoginDetails): PairingStatusResponseDto {
    return this.service.phoneStatus(dto.invite, dto.claimToken, details.clientIp);
  }

  @Post('phone-confirm')
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Confirm pairing on phone', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  phoneConfirm(@Body() dto: PairingPhoneActionDto, @GetLoginDetails() details: LoginDetails): PairingStatusResponseDto {
    return this.service.confirmPhone(dto.invite, dto.claimToken, dto.code, details.clientIp);
  }

  @Post('pc-confirm')
  @Authenticated({ admin: true })
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Confirm pairing on PC', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  pcConfirm(@Auth() auth: AuthDto, @Body() dto: PairingPcConfirmDto): PairingStatusResponseDto {
    return this.service.confirmPc(auth, dto.invite, dto.code);
  }

  @Post('redeem')
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.OK)
  @Endpoint({ summary: 'Redeem phone pairing invite', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  redeem(@Body() dto: PairingRedeemDto, @GetLoginDetails() details: LoginDetails): Promise<LoginResponseDto> {
    return this.service.redeem(dto.invite, dto.claimToken, details);
  }

  @Post('cancel')
  @Authenticated({ admin: true })
  @Header('Cache-Control', 'no-store')
  @HttpCode(HttpStatus.NO_CONTENT)
  @Endpoint({ summary: 'Cancel phone pairing invite', history: new HistoryBuilder().added('v3.1.0').alpha('v3.1.0') })
  cancel(@Auth() auth: AuthDto, @Body() dto: PairingInviteDto): void {
    this.service.cancel(auth, dto.invite);
  }
}
