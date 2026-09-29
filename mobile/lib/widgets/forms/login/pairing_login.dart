import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/services/pairing.service.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class PairingLogin extends ConsumerStatefulWidget {
  const PairingLogin({super.key, required this.onManual, required this.onRedeemed});

  final VoidCallback onManual;
  final Future<void> Function(String accessToken, Uri origin) onRedeemed;

  @override
  ConsumerState<PairingLogin> createState() => _PairingLoginState();
}

class _PairingLoginState extends ConsumerState<PairingLogin> {
  PairingInvite? _invite;
  PairingClaim? _claim;
  String? _error;
  bool _busy = false;
  bool _phoneConfirmed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _acceptPendingLink(ref.read(pendingPairingInviteProvider));
      }
    });
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _acceptPendingLink(PairingInvite? invite) {
    if (invite == null) {
      return;
    }
    ref.read(pendingPairingInviteProvider.notifier).state = null;
    _selectInvite(invite);
  }

  void _selectInvite(PairingInvite invite) {
    _generation++;
    setState(() {
      _invite = invite;
      _claim = null;
      _error = null;
      _busy = false;
      _phoneConfirmed = false;
    });
  }

  void _startOver() {
    _generation++;
    setState(() {
      _invite = null;
      _claim = null;
      _error = null;
      _busy = false;
      _phoneConfirmed = false;
    });
  }

  Future<void> _scan() async {
    final invite = await showModalBottomSheet<PairingInvite>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.72, child: const _PairingScanner()),
    );
    if (mounted && invite != null) {
      _selectInvite(invite);
    }
  }

  Future<String> _deviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        return (await info.androidInfo).model;
      }
      if (Platform.isIOS) {
        return (await info.iosInfo).name;
      }
    } catch (_) {
      // A generic device label is sufficient for the PC confirmation screen.
    }
    return 'Phone';
  }

  Future<void> _claimInvite() async {
    final invite = _invite;
    if (invite == null || _busy) {
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deviceName = await _deviceName();
      final claim = await ref.read(pairingServiceProvider).claim(invite, deviceName: deviceName);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() => _claim = claim);
    } on PairingException catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.message);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmOnPhone() async {
    final invite = _invite;
    final claim = _claim;
    if (invite == null || claim == null || _busy) {
      return;
    }
    if (DateTime.now().toUtc().isAfter(claim.expiresAt)) {
      setState(() => _error = 'This QR code has expired. Start again on your computer.');
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await ref.read(pairingServiceProvider).confirm(invite, claim);
      if (!mounted || generation != _generation) {
        return;
      }
      if (status.isTerminal) {
        throw const PairingException('Pairing was cancelled or expired. Start again on your computer.');
      }
      setState(() {
        _phoneConfirmed = true;
        _busy = false;
      });
      unawaited(_pollAndRedeem(invite, claim, generation));
    } on PairingException catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  Future<void> _pollAndRedeem(PairingInvite invite, PairingClaim claim, int generation) async {
    try {
      while (mounted && generation == _generation) {
        if (DateTime.now().toUtc().isAfter(claim.expiresAt)) {
          throw const PairingException('This QR code has expired. Start again on your computer.');
        }
        final service = ref.read(pairingServiceProvider);
        final status = await service.status(invite, claim);
        if (!mounted || generation != _generation) {
          return;
        }
        if (status.isTerminal) {
          throw const PairingException('Pairing was cancelled or expired. Start again on your computer.');
        }
        if (status.status == 'ready') {
          final accessToken = await service.redeem(invite, claim);
          if (!mounted || generation != _generation) {
            return;
          }
          await widget.onRedeemed(accessToken, invite.origin);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } on PairingException catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _phoneConfirmed = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _phoneConfirmed = false;
          _error = 'Could not complete sign-in. Start again on your computer.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PairingInvite?>(pendingPairingInviteProvider, (_, invite) => _acceptPendingLink(invite));

    final invite = _invite;
    final claim = _claim;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Connect your phone', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          if (invite == null) ...[
            const Text(
              'On your computer, open Inhouse Photos and choose “Connect phone”.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
            ),
          ] else if (claim == null) ...[
            const Text('Connect to this server?', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            SelectableText(invite.origin.toString(), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _claimInvite, child: const Text('Continue')),
          ] else ...[
            Text('Server: ${invite.origin.host}', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Computer: ${claim.pcDeviceName}', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Account: ${claim.accountName} (${claim.accountEmail})', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text('Phone: this device', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(
              claim.code,
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(letterSpacing: 6),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              _phoneConfirmed
                  ? 'Waiting for approval on your computer…'
                  : 'Check that this code matches the one on your computer. Only approve if you started this pairing.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (!_phoneConfirmed)
              FilledButton(onPressed: _busy ? null : _confirmOnPhone, child: const Text('The codes match — approve')),
          ],
          if (_busy || _phoneConfirmed) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
          if (invite != null) ...[
            const SizedBox(height: 12),
            TextButton(onPressed: _startOver, child: const Text('Scan a different code')),
          ],
          TextButton(onPressed: widget.onManual, child: const Text('Use server address and password instead')),
        ],
      ),
    );
  }
}

class _PairingScanner extends StatefulWidget {
  const _PairingScanner();

  @override
  State<_PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<_PairingScanner> {
  bool _found = false;
  bool _invalid = false;

  void _onDetect(BarcodeCapture capture) {
    if (_found) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final invite = PairingInvite.parse(barcode.rawValue ?? '');
      if (invite != null) {
        _found = true;
        Navigator.of(context).pop(invite);
        return;
      }
    }
    if (!_invalid && capture.barcodes.isNotEmpty) {
      setState(() => _invalid = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 12),
          Text('Scan the code on your computer', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Expanded(child: MobileScanner(onDetect: _onDetect)),
          if (_invalid)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('That is not an Inhouse Photos pairing code. Try the code shown on your computer.'),
            ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ],
      ),
    );
  }
}
