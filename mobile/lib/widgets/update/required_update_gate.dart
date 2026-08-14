import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _updateManifestUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/android-update.json';
const _updateChannel = MethodChannel('com.inhousesoftware.photos/updates');

int compareInhouseVersions(String left, String right) {
  final leftParts = left.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final rightParts = right.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final length = leftParts.length > rightParts.length ? leftParts.length : rightParts.length;

  for (var index = 0; index < length; index++) {
    final leftPart = index < leftParts.length ? leftParts[index] : 0;
    final rightPart = index < rightParts.length ? rightParts[index] : 0;
    if (leftPart != rightPart) {
      return leftPart.compareTo(rightPart);
    }
  }
  return 0;
}

class InhouseUpdateManifest {
  const InhouseUpdateManifest({
    required this.version,
    required this.versionCode,
    required this.required,
    required this.apkUrl,
  });

  final String version;
  final int versionCode;
  final bool required;
  final Uri apkUrl;

  factory InhouseUpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version']?.toString() ?? '';
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const FormatException('Invalid update version');
    }

    final versionCode = int.tryParse(json['versionCode']?.toString() ?? '');
    if (versionCode == null || versionCode < 1) {
      throw const FormatException('Invalid update build number');
    }

    final apkUrl = Uri.tryParse(json['apkUrl']?.toString() ?? '');
    const allowedHosts = {
      'github.com',
      'raw.githubusercontent.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
    };
    if (apkUrl == null || apkUrl.scheme != 'https' || !allowedHosts.contains(apkUrl.host)) {
      throw const FormatException('Invalid update download URL');
    }

    return InhouseUpdateManifest(
      version: version,
      versionCode: versionCode,
      required: json['required'] != false,
      apkUrl: apkUrl,
    );
  }
}

enum _InstallState { idle, downloading, permissionRequired, ready, error }

class RequiredUpdateGate extends StatefulWidget {
  const RequiredUpdateGate({required this.child, super.key});

  final Widget child;

  @override
  State<RequiredUpdateGate> createState() => _RequiredUpdateGateState();
}

class _RequiredUpdateGateState extends State<RequiredUpdateGate> with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;
  InhouseUpdateManifest? _update;
  String _installedVersion = '';
  _InstallState _installState = _InstallState.idle;
  String _status = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_checkForUpdate()));
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => unawaited(_checkForUpdate()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkForUpdate());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkForUpdate() async {
    if (!Platform.isAndroid || _checking) {
      return;
    }
    _checking = true;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final manifestUri = Uri.parse(
        _updateManifestUrl,
      ).replace(queryParameters: {'check': DateTime.now().millisecondsSinceEpoch.toString()});
      final response = await http
          .get(manifestUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Update check failed (${response.statusCode})');
      }
      final manifest = InhouseUpdateManifest.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      final needsUpdate = manifest.required && compareInhouseVersions(manifest.version, packageInfo.version) > 0;

      if (!mounted) {
        return;
      }
      setState(() {
        _installedVersion = packageInfo.version;
        _update = needsUpdate ? manifest : null;
        if (!needsUpdate) {
          _installState = _InstallState.idle;
          _status = '';
        }
      });
    } catch (_) {
      // Match Inhouse Notes: a temporary network or GitHub failure never
      // prevents an already-current app from starting.
    } finally {
      _checking = false;
    }
  }

  Future<void> _installUpdate() async {
    final update = _update;
    if (update == null) {
      return;
    }

    setState(() {
      _installState = _InstallState.downloading;
      _status = 'Downloading the update securely inside Inhouse Photos…';
    });

    try {
      final result = await _updateChannel.invokeMethod<String>('installUpdate', {'url': update.apkUrl.toString()});
      if (!mounted) {
        return;
      }
      setState(() {
        if (result == 'permission_required') {
          _installState = _InstallState.permissionRequired;
          _status = 'Allow installs from this source, return here, then tap Continue.';
        } else {
          _installState = _InstallState.ready;
          _status = 'Update downloaded and verified. Confirm installation in Android.';
        }
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _installState = _InstallState.error;
        _status = error.message ?? 'The update could not be installed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    return PopScope(
      canPop: update == null,
      child: Stack(
        children: [
          widget.child,
          if (update != null)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xF5000000),
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Material(
                          color: const Color(0xFF171310),
                          elevation: 24,
                          borderRadius: BorderRadius.circular(24),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const ImmichLogo(heroTag: 'required-update-logo'),
                                const SizedBox(height: 20),
                                Text(
                                  'Update required',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                    color: const Color(0xFFF5F5F0),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'You have Inhouse Photos $_installedVersion. Install version ${update.version} to continue.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyLarge?.copyWith(color: const Color(0xFFD7D0CA), height: 1.45),
                                ),
                                const SizedBox(height: 24),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed:
                                        _installState == _InstallState.downloading ||
                                            _installState == _InstallState.ready
                                        ? null
                                        : _installUpdate,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFD97736),
                                      foregroundColor: Colors.black,
                                      padding: const EdgeInsets.symmetric(vertical: 15),
                                    ),
                                    child: Text(switch (_installState) {
                                      _InstallState.downloading => 'Downloading…',
                                      _InstallState.permissionRequired => 'Continue installation',
                                      _InstallState.error => 'Try again',
                                      _ => 'Install update',
                                    }),
                                  ),
                                ),
                                if (_status.isNotEmpty) ...[
                                  const SizedBox(height: 14),
                                  Text(
                                    _status,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: _installState == _InstallState.error
                                          ? const Color(0xFFFFA8A8)
                                          : const Color(0xFFB8AEA7),
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
