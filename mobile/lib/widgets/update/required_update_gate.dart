import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'package:url_launcher/url_launcher.dart';

const _androidUpdateManifestUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/android-update.json';
const _iosUpdateManifestUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/ios-update.json';
const _sideStoreSourceUrl =
    'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/altstore-source.json';
const _updateChannel = MethodChannel('com.inhousesoftware.photos/updates');
const _minimumUpdateScreenTime = Duration(milliseconds: 650);

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

Uri buildSideStoreInstallUri(Uri ipaUrl) {
  return Uri(scheme: 'sidestore', host: 'install', queryParameters: {'url': ipaUrl.toString()});
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

enum _InstallState { idle, downloadingApk, applyingDataUpdate, permissionRequired, restartRequired, ready, error }

/// A single launch gate for both signed Shorebird data patches and native app
/// packages. The screen deliberately appears on every cold app launch: this
/// makes an OTA update visible instead of silently looking like nothing changed.
class RequiredUpdateGate extends StatefulWidget {
  const RequiredUpdateGate({required this.child, super.key});

  final Widget child;

  @override
  State<RequiredUpdateGate> createState() => _RequiredUpdateGateState();
}

class _RequiredUpdateGateState extends State<RequiredUpdateGate> with WidgetsBindingObserver {
  final ShorebirdUpdater _shorebirdUpdater = ShorebirdUpdater();
  Timer? _timer;
  Timer? _dismissTimer;
  bool _checking = false;
  bool _showUpdateScreen = true;
  InhouseUpdateManifest? _apkUpdate;
  String _installedVersion = '';
  _InstallState _installState = _InstallState.idle;
  String _status = 'Checking for the latest Inhouse Photos update...';
  double? _downloadProgress;
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateChannel.setMethodCallHandler(_handleUpdateChannelCall);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_checkForUpdate(showScreen: true)));
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
    _dismissTimer?.cancel();
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

  Future<InhouseUpdateManifest?> _fetchNativeUpdate() async {
    try {
      final manifestUri = Uri.parse(
        Platform.isIOS ? _iosUpdateManifestUrl : _androidUpdateManifestUrl,
      ).replace(queryParameters: {'check': DateTime.now().millisecondsSinceEpoch.toString()});
      final response = await http
          .get(manifestUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      return InhouseUpdateManifest.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
        assetKey: Platform.isIOS ? 'ipaUrl' : 'apkUrl',
      );
    } catch (_) {
      return null;
    }
  }

  Future<UpdateStatus?> _fetchDataUpdateStatus() async {
    if (!_shorebirdUpdater.isAvailable) {
      return null;
    }
    try {
      return await _shorebirdUpdater.checkForUpdate().timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkForUpdate({bool showScreen = false}) async {
    if ((!Platform.isAndroid && !Platform.isIOS) || _checking) {
      return;
    }

    _checking = true;
    _dismissTimer?.cancel();
    if (showScreen && mounted) {
      setState(() {
        _showUpdateScreen = true;
        _installState = _InstallState.idle;
        _status = 'Checking for the latest Inhouse Photos update...';
      });
    }

    final startedAt = DateTime.now();
    final packageInfoFuture = PackageInfo.fromPlatform();
    final nativeUpdateFuture = _fetchNativeUpdate();
    final dataUpdateFuture = _fetchDataUpdateStatus();

    try {
      final packageInfo = await packageInfoFuture;
      final nativeUpdate = await nativeUpdateFuture;
      final dataStatus = await dataUpdateFuture;
      final remaining = _minimumUpdateScreenTime - DateTime.now().difference(startedAt);
      if (!remaining.isNegative) {
        await Future<void>.delayed(remaining);
      }
      if (!mounted) {
        return;
      }

      final nativeVersionComparison = nativeUpdate == null
          ? 0
          : compareInhouseVersions(nativeUpdate.version, packageInfo.version);
      // The 3.1.37 OTA base used build 5096 while a short-lived manual APK
      // used build 3097. A build number by itself must never offer a lower
      // visible version, but it resolves two builds of the same version.
      final needsNativeUpdate =
          nativeUpdate != null &&
          nativeUpdate.required &&
          (nativeVersionComparison > 0 ||
              (nativeVersionComparison == 0 &&
                  nativeUpdate.versionCode > (int.tryParse(packageInfo.buildNumber) ?? 0)));

      setState(() {
        _installedVersion = packageInfo.version;
        _apkUpdate = needsNativeUpdate ? nativeUpdate : null;
        _downloadProgress = null;
        _downloadedBytes = 0;
        _downloadTotalBytes = null;
        if (needsNativeUpdate) {
          _status = 'A new Inhouse Photos app version is ready.';
        } else if (dataStatus == UpdateStatus.outdated) {
          _installState = _InstallState.applyingDataUpdate;
          _status = 'Downloading the latest Inhouse Photos improvements...';
        } else if (dataStatus == UpdateStatus.restartRequired) {
          _installState = _InstallState.restartRequired;
          _status = 'The latest Inhouse Photos improvements are ready.';
        } else {
          _installState = _InstallState.idle;
          _status = 'Inhouse Photos is up to date.';
        }
      });

      if (needsNativeUpdate) {
        return;
      }
      if (dataStatus == UpdateStatus.outdated) {
        unawaited(_applyDataUpdate());
        return;
      }
      if (dataStatus != UpdateStatus.restartRequired) {
        _dismissUpdateScreenSoon();
      }
    } catch (_) {
      if (mounted && showScreen) {
        setState(() {
          _installState = _InstallState.error;
          _status = 'We could not check for updates. Your installed app can still open normally.';
        });
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _applyDataUpdate() async {
    if (!_shorebirdUpdater.isAvailable) {
      return;
    }
    try {
      await _shorebirdUpdater.update();
      if (!mounted) {
        return;
      }
      setState(() {
        _installState = _InstallState.restartRequired;
        _status = 'Update downloaded and verified. Restart Inhouse Photos to use it.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _installState = _InstallState.error;
        _status = 'The data update could not finish. Tap Try again to retry securely.';
      });
    }
  }

  void _dismissUpdateScreenSoon() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && _apkUpdate == null && _installState == _InstallState.idle) {
        setState(() => _showUpdateScreen = false);
      }
    });
  }

  Future<void> _installNativeUpdate() async {
    final update = _apkUpdate;
    if (update == null) {
      return;
    }

    if (Platform.isIOS) {
      final installUri = buildSideStoreInstallUri(update.apkUrl);
      var opened = false;
      try {
        opened = await launchUrl(installUri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _installState = opened ? _InstallState.ready : _InstallState.error;
        _status = opened
            ? 'SideStore is preparing the update. Keep LocalDevVPN enabled, install it there, then reopen Inhouse Photos.'
            : 'SideStore is not installed. Add the Inhouse Photos source there, then try again: $_sideStoreSourceUrl';
      });
      return;
    }

    setState(() {
      _installState = _InstallState.downloadingApk;
      _status = 'Downloading the app update securely...';
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

  void _closeForRestart() {
    // A Shorebird patch is loaded by a fresh Flutter engine. Android can close
    // the task immediately; iOS follows the platform rule and asks the user to
    // reopen it rather than attempting an unsafe in-process restart.
    if (Platform.isAndroid) {
      unawaited(SystemNavigator.pop());
    }
  }

  void _openApp() {
    _dismissTimer?.cancel();
    setState(() => _showUpdateScreen = false);
  }

  @override
  Widget build(BuildContext context) {
    final nativeUpdate = _apkUpdate;
    if (!_showUpdateScreen) {
      return widget.child;
    }

    final isNativeUpdate = nativeUpdate != null;
    final isApplyingDataUpdate = _installState == _InstallState.applyingDataUpdate;
    final isDownloadingApk = _installState == _InstallState.downloadingApk;
    final needsRestart = _installState == _InstallState.restartRequired;
    final hasError = _installState == _InstallState.error;
    final heading = switch (_installState) {
      _InstallState.applyingDataUpdate => 'Updating Inhouse Photos',
      _InstallState.restartRequired => 'Update ready',
      _InstallState.downloadingApk => 'Downloading app update',
      _ => isNativeUpdate ? 'App update ready' : 'Checking for updates',
    };

    return PopScope(
      canPop: !isNativeUpdate && !isApplyingDataUpdate && !isDownloadingApk,
      child: Stack(
        children: [
          widget.child,
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
                                heading,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: const Color(0xFFF5F5F0),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _status,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: hasError ? const Color(0xFFFFA8A8) : const Color(0xFFD7D0CA),
                                  height: 1.45,
                                ),
                              ),
                              if (isNativeUpdate) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'App version $_installedVersion to ${nativeUpdate.version}',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodySmall?.copyWith(color: const Color(0xFFB8AEA7)),
                                ),
                              ],
                              const SizedBox(height: 24),
                              if (isApplyingDataUpdate || isDownloadingApk) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: isApplyingDataUpdate ? null : _downloadProgress,
                                    minHeight: 9,
                                    backgroundColor: const Color(0xFF3A302A),
                                    valueColor: const AlwaysStoppedAnimation(Color(0xFFD97736)),
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Text(
                                  isApplyingDataUpdate
                                      ? 'This is a small app-data update. No APK installation is needed.'
                                      : _downloadTotalBytes == null
                                      ? formatInhouseDownloadBytes(_downloadedBytes)
                                      : '${(_downloadProgress! * 100).round()}% · '
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
                                  onPressed: isApplyingDataUpdate || isDownloadingApk
                                      ? null
                                      : needsRestart
                                      ? _closeForRestart
                                      : hasError
                                      ? () => unawaited(_checkForUpdate(showScreen: true))
                                      : isNativeUpdate
                                      ? _installNativeUpdate
                                      : _openApp,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFD97736),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(vertical: 15),
                                  ),
                                  child: Text(switch (_installState) {
                                    _InstallState.applyingDataUpdate => 'Updating...',
                                    _InstallState.downloadingApk => 'Downloading...',
                                    _InstallState.restartRequired =>
                                      Platform.isIOS ? 'Close and reopen' : 'Restart now',
                                    _InstallState.permissionRequired => 'Continue installation',
                                    _InstallState.error => 'Try again',
                                    _ =>
                                      isNativeUpdate
                                          ? (Platform.isIOS ? 'Open SideStore' : 'Install app update')
                                          : 'Open Photos',
                                  }),
                                ),
                              ),
                              if (needsRestart && Platform.isIOS) ...[
                                const SizedBox(height: 12),
                                Text(
                                  'Close Inhouse Photos, then open it again to use the update.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodySmall?.copyWith(color: const Color(0xFFB8AEA7), height: 1.4),
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
