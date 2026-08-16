import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const _androidUpdateManifestUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/android-update.json';
const _iosUpdateManifestUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/ios-update.json';
const _sideStoreSourceUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/altstore-source.json';
const _updateChannel = MethodChannel('com.inhousesoftware.photos/updates');

double? calculateInhouseDownloadProgress({required int downloadedBytes, required int? totalBytes}) {
  if (totalBytes == null || totalBytes <= 0) {
    return null;
  }
  return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
}

String formatInhouseDownloadBytes(int bytes) {
  const bytesPerMegabyte = 1024 * 1024;
  return '${(bytes / bytesPerMegabyte).toStringAsFixed(1)} MB';
}

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

  factory InhouseUpdateManifest.fromJson(Map<String, dynamic> json, {String assetKey = 'apkUrl'}) {
    final version = json['version']?.toString() ?? '';
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const FormatException('Invalid update version');
    }

    final versionCode = int.tryParse(json['versionCode']?.toString() ?? '');
    if (versionCode == null || versionCode < 1) {
      throw const FormatException('Invalid update build number');
    }

    final apkUrl = Uri.tryParse(json[assetKey]?.toString() ?? '');
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
  double? _downloadProgress;
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateChannel.setMethodCallHandler(_handleUpdateChannelCall);
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
    _updateChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _handleUpdateChannelCall(MethodCall call) async {
    if (call.method != 'downloadProgress' || !mounted || call.arguments is! Map) {
      return;
    }

    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    final downloadedBytes = (arguments['downloadedBytes'] as num?)?.toInt() ?? 0;
    final totalBytes = (arguments['totalBytes'] as num?)?.toInt();
    setState(() {
      _downloadedBytes = downloadedBytes;
      _downloadTotalBytes = totalBytes;
      _downloadProgress = calculateInhouseDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes);
    });
  }

  Future<void> _checkForUpdate() async {
    if ((!Platform.isAndroid && !Platform.isIOS) || _checking) {
      return;
    }
    _checking = true;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final manifestUri = Uri.parse(
        Platform.isIOS ? _iosUpdateManifestUrl : _androidUpdateManifestUrl,
      ).replace(queryParameters: {'check': DateTime.now().millisecondsSinceEpoch.toString()});
      final response = await http
          .get(manifestUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Update check failed (${response.statusCode})');
      }
      final manifest = InhouseUpdateManifest.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
        assetKey: Platform.isIOS ? 'ipaUrl' : 'apkUrl',
      );
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

    if (Platform.isIOS) {
      final sourceUri = Uri(scheme: 'sidestore', host: 'source', queryParameters: {'url': _sideStoreSourceUrl});
      var opened = false;
      try {
        opened = await launchUrl(sourceUri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _installState = opened ? _InstallState.idle : _InstallState.error;
        _status = opened
            ? 'Update Inhouse Photos from its source in SideStore, then reopen the app.'
            : 'SideStore is not installed yet. Install it first, then try again.';
      });
      return;
    }

    setState(() {
      _installState = _InstallState.downloading;
      _status = 'Downloading the update securely inside Inhouse Photos…';
      _downloadProgress = 0;
      _downloadedBytes = 0;
      _downloadTotalBytes = null;
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
          _downloadProgress = 1;
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
                                if (_installState == _InstallState.downloading) ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: _downloadProgress,
                                      minHeight: 9,
                                      backgroundColor: const Color(0xFF3A302A),
                                      valueColor: const AlwaysStoppedAnimation(Color(0xFFD97736)),
                                    ),
                                  ),
                                  const SizedBox(height: 9),
                                  Text(
                                    _downloadTotalBytes == null
                                        ? formatInhouseDownloadBytes(_downloadedBytes)
                                        : '${(_downloadProgress! * 100).round()}%  ·  '
                                              '${formatInhouseDownloadBytes(_downloadedBytes)} / '
                                              '${formatInhouseDownloadBytes(_downloadTotalBytes!)}',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium?.copyWith(color: const Color(0xFFD7D0CA)),
                                  ),
                                  const SizedBox(height: 18),
                                ],
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
                                      _ => Platform.isIOS ? 'Open SideStore' : 'Install update',
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
