import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

const pairingServerOrigin = 'https://fotos.miguelcoxcaballero.com';
final _invitePattern = RegExp(r'^invite=([A-Za-z0-9_-]{43})$');
final _landingPattern = RegExp(r'^origin=([^&]+)&invite=([A-Za-z0-9_-]{43})$');
final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _codePattern = RegExp(r'^\d{6}$');
const _statuses = {
  'pending',
  'claimed',
  'phone-confirmed',
  'pc-confirmed',
  'ready',
  'redeemed',
  'cancelled',
  'failed',
  'expired',
};

final pendingPairingInviteProvider = StateProvider<PairingInvite?>((ref) => null);

final pairingServiceProvider = Provider<PairingService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return PairingService(client);
});

/// The invite is kept only in memory and POST bodies after parsing the QR URL.
class PairingInvite {
  const PairingInvite._(this.invite, this.origin);

  final String invite;
  final Uri origin;

  static PairingInvite? parse(String value) {
    if (value.length > 512 || value.trim() != value) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443)) {
      return null;
    }

    final isWebLink = uri.scheme == 'https' && uri.host.isNotEmpty && uri.path == '/vincular' && !uri.hasQuery;
    // The landing page uses a custom-scheme button when Universal Links are unavailable.
    final isAppLink =
        uri.scheme == 'inhousephotos' && uri.host == 'vincular' && !uri.hasPort && uri.path.isEmpty && !uri.hasFragment;
    if (isWebLink) {
      // Read the raw fragment: Uri.fragment can decode percent escapes, while
      // the landing page encodes the actual server origin as one value.
      final fragment = value.substring(value.indexOf('#') + 1);
      final directMatch = _invitePattern.firstMatch(fragment);
      if (directMatch != null) {
        return PairingInvite._(directMatch.group(1)!, Uri(scheme: 'https', host: uri.host));
      }
      if (uri.host != Uri.parse(pairingServerOrigin).host) {
        return null;
      }
      final landingMatch = _landingPattern.firstMatch(fragment);
      if (landingMatch == null) {
        return null;
      }
      try {
        final origin = _canonicalOrigin(Uri.decodeComponent(landingMatch.group(1)!));
        return origin == null ? null : PairingInvite._(landingMatch.group(2)!, origin);
      } catch (_) {
        return null;
      }
    }
    if (!isAppLink) {
      return null;
    }
    final params = uri.queryParametersAll;
    final inviteValues = params['invite'];
    if (inviteValues == null || inviteValues.length != 1 || !_tokenPattern.hasMatch(inviteValues.single)) {
      return null;
    }
    Uri? origin;
    if (params.length == 1) {
      // Legacy fallback links without an origin belong only to the original server.
      origin = Uri.parse(pairingServerOrigin);
    } else if (params.length == 2 && params['origin']?.length == 1) {
      origin = _canonicalOrigin(params['origin']!.single);
    }
    return origin == null ? null : PairingInvite._(inviteValues.single, origin);
  }

  static Uri? _canonicalOrigin(String value) {
    if (value.isEmpty || value.length > 256 || value.trim() != value) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return Uri(scheme: 'https', host: uri.host);
  }
}

class PairingClaim {
  const PairingClaim({
    required this.claimToken,
    required this.code,
    required this.accountName,
    required this.accountEmail,
    required this.pcDeviceName,
    required this.expiresAt,
  });

  final String claimToken;
  final String code;
  final String accountName;
  final String accountEmail;
  final String pcDeviceName;
  final DateTime expiresAt;
}

class PairingStatus {
  const PairingStatus({required this.status, required this.expiresAt});

  final String status;
  final DateTime expiresAt;

  bool get isTerminal => status == 'cancelled' || status == 'failed' || status == 'expired' || status == 'redeemed';
}

class PairingException implements Exception {
  const PairingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PairingService {
  const PairingService(this._client);

  final http.Client _client;

  Future<PairingClaim> claim(PairingInvite invite, {String? deviceName}) async {
    final response = await _post(invite, 'claim', {
      'invite': invite.invite,
      if (deviceName != null) 'deviceName': deviceName,
    });
    final claimToken = _string(response, 'claimToken');
    final code = _string(response, 'code');
    if (!_tokenPattern.hasMatch(claimToken) || !_codePattern.hasMatch(code)) {
      throw const PairingException('The pairing response was invalid.');
    }
    return PairingClaim(
      claimToken: claimToken,
      code: code,
      accountName: _string(response, 'accountName'),
      accountEmail: _string(response, 'accountEmail'),
      pcDeviceName: _string(response, 'pcDeviceName'),
      expiresAt: _expiresAt(response),
    );
  }

  Future<PairingStatus> confirm(PairingInvite invite, PairingClaim claim) async {
    final response = await _post(invite, 'phone-confirm', {
      'invite': invite.invite,
      'claimToken': claim.claimToken,
      'code': claim.code,
    });
    return _status(response);
  }

  Future<PairingStatus> status(PairingInvite invite, PairingClaim claim) async {
    final response = await _post(invite, 'phone-status', {'invite': invite.invite, 'claimToken': claim.claimToken});
    return _status(response);
  }

  Future<String> redeem(PairingInvite invite, PairingClaim claim) async {
    final response = await _post(invite, 'redeem', {'invite': invite.invite, 'claimToken': claim.claimToken});
    return _string(response, 'accessToken');
  }

  Future<Map<String, dynamic>> _post(PairingInvite invite, String action, Map<String, String> data) async {
    late http.Response response;
    try {
      response = await _client
          .post(
            invite.origin.replace(path: '/api/auth/pairing/$action'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(data),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const PairingException('Could not reach the server. Check your connection and try again.');
    }

    // Never surface or log a raw response body; it can contain one-time secrets.
    if (response.statusCode == 429) {
      throw const PairingException('Too many pairing attempts. Please start again on your computer.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const PairingException('Pairing expired or was declined. Start again on your computer.');
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Report a generic error without including the potentially sensitive body.
    }
    throw const PairingException('The pairing response was invalid.');
  }

  String _string(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw const PairingException('The pairing response was invalid.');
  }

  DateTime _expiresAt(Map<String, dynamic> data) {
    final value = DateTime.tryParse(_string(data, 'expiresAt'));
    if (value == null) {
      throw const PairingException('The pairing response was invalid.');
    }
    return value.toUtc();
  }

  PairingStatus _status(Map<String, dynamic> data) {
    final status = _string(data, 'status');
    if (!_statuses.contains(status)) {
      throw const PairingException('The pairing response was invalid.');
    }
    return PairingStatus(status: status, expiresAt: _expiresAt(data));
  }
}
