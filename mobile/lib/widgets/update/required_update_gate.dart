import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
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
const _minimumUpdateScreenTime = Duration(milliseconds: 650);
const _dataUpdateCheckTimeout = Duration(seconds: 12);
const _dataUpdateInstallTimeout = Duration(seconds: 45);

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

String formatInhouseInstallerError(String message) {
  final normalized = message.toLowerCase();
  if (normalized.contains('not newer') ||
      normalized.contains('older than the installed') ||
      normalized.contains('versiondowngrade')) {
    return 'This download was older than the installed app. The update catalogue has been refreshed; tap Try again to download the latest build.';
  }
  if (normalized.contains('parse') || normalized.contains('malformed') || normalized.contains('invalid apk')) {
    return 'The downloaded update was incomplete or invalid. Tap Try again to download a fresh copy.';
  }
  return message.isEmpty ? 'The update could not be installed. Please try again.' : message;
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

enum _InstallState {
  checking,
  upToDate,
  downloadingData,
  restartRequired,
  downloadingApk,
  permissionRequired,
  ready,
  error,
}

final class _ShorebirdUpdateResult extends ffi.Struct {
  @ffi.Int32()
  external int status;

  external ffi.Pointer<ffi.Char> message;
}

typedef _NativePatchNumber = ffi.UintPtr Function();
typedef _DartPatchNumber = int Function();
typedef _NativeCheckUpdate = ffi.Bool Function(ffi.Pointer<ffi.Char>);
typedef _DartCheckUpdate = bool Function(ffi.Pointer<ffi.Char>);
typedef _NativeInstallUpdate = ffi.Pointer<_ShorebirdUpdateResult> Function(ffi.Pointer<ffi.Char>);
typedef _DartInstallUpdate = ffi.Pointer<_ShorebirdUpdateResult> Function(ffi.Pointer<ffi.Char>);
typedef _NativeFreeUpdate = ffi.Void Function(ffi.Pointer<_ShorebirdUpdateResult>);
typedef _DartFreeUpdate = void Function(ffi.Pointer<_ShorebirdUpdateResult>);

const _shorebirdNoUpdate = 0;
const _shorebirdUpdateInstalled = 1;
const _shorebirdUpdateInProgress = 4;

class _ShorebirdSnapshot {
  const _ShorebirdSnapshot({
    required this.available,
    required this.currentPatch,
    required this.nextPatch,
    required this.downloadable,
  });

  const _ShorebirdSnapshot.unavailable() : available = false, currentPatch = 0, nextPatch = 0, downloadable = false;

  final bool available;
  final int currentPatch;
  final int nextPatch;
  final bool downloadable;

  bool get requiresRestart => available && currentPatch != nextPatch;
}

class _ShorebirdInstallResult {
  const _ShorebirdInstallResult(this.status, this.message);

  final int status;
  final String message;

  bool get accepted =>
      status == _shorebirdNoUpdate || status == _shorebirdUpdateInstalled || status == _shorebirdUpdateInProgress;
}

/// Talks directly to the Shorebird engine already bundled in the installed
/// OTA base. This avoids adding another native plugin to a data-only patch.
class _ShorebirdUpdateClient {
  static Future<_ShorebirdSnapshot> inspect({required bool checkNetwork}) => Isolate.run(() {
    try {
      final library = ffi.DynamicLibrary.process();
      final currentPatch = library.lookupFunction<_NativePatchNumber, _DartPatchNumber>(
        'shorebird_current_boot_patch_number',
      );
      final nextPatch = library.lookupFunction<_NativePatchNumber, _DartPatchNumber>(
        'shorebird_next_boot_patch_number',
      );
      final checkUpdate = library.lookupFunction<_NativeCheckUpdate, _DartCheckUpdate>(
        'shorebird_check_for_downloadable_update',
      );
      return _ShorebirdSnapshot(
        available: true,
        currentPatch: currentPatch(),
        nextPatch: nextPatch(),
        downloadable: checkNetwork && checkUpdate(ffi.nullptr),
      );
    } catch (_) {
      return const _ShorebirdSnapshot.unavailable();
    }
  });

  static Future<_ShorebirdInstallResult> install() => Isolate.run(() {
    try {
      final library = ffi.DynamicLibrary.process();
      final installUpdate = library.lookupFunction<_NativeInstallUpdate, _DartInstallUpdate>(
        'shorebird_update_with_result',
      );
      final freeUpdate = library.lookupFunction<_NativeFreeUpdate, _DartFreeUpdate>('shorebird_free_update_result');
      final result = installUpdate(ffi.nullptr);
      if (result == ffi.nullptr) {
        return const _ShorebirdInstallResult(-1, 'The updater returned no result.');
      }
      try {
        final message = result.ref.message == ffi.nullptr ? '' : result.ref.message.cast<Utf8>().toDartString();
        return _ShorebirdInstallResult(result.ref.status, message);
      } finally {
        freeUpdate(result);
      }
    } catch (error) {
      return _ShorebirdInstallResult(-1, error.toString());
    }
  });
}

/// One launch gate for both data patches and native packages. The Shorebird
/// engine inside the OTA base APK checks and downloads data patches itself;
/// this screen intentionally appears at every cold start so that behaviour is
/// visible instead of looking like nothing happened.
class RequiredUpdateGate extends StatefulWidget {
  const RequiredUpdateGate({required this.child, super.key});

  final Widget child;

  @override
  State<RequiredUpdateGate> createState() => _RequiredUpdateGateState();
}

class _RequiredUpdateGateState extends State<RequiredUpdateGate> with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;
  bool _showUpdateScreen = false;
  InhouseUpdateManifest? _apkUpdate;
  String _installedVersion = '';
  _InstallState _installState = _InstallState.checking;
  String _status = 'Checking for the latest Inhouse Photos update...';
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

  Future<void> _checkForUpdate({bool showScreen = false}) async {
    final updateOperationActive =
        _installState == _InstallState.downloadingApk ||
        _installState == _InstallState.downloadingData ||
        _installState == _InstallState.permissionRequired ||
        _installState == _InstallState.restartRequired;
    if ((!Platform.isAndroid && !Platform.isIOS) || _checking || updateOperationActive) {
      return;
    }

    _checking = true;
    if (showScreen && mounted) {
      setState(() {
        _showUpdateScreen = true;
        _installState = _InstallState.checking;
        _status = 'Checking for the latest Inhouse Photos update...';
      });
    }

    final startedAt = DateTime.now();
    final packageInfoFuture = PackageInfo.fromPlatform();
    final nativeUpdateFuture = _fetchNativeUpdate();

    try {
      final packageInfo = await packageInfoFuture;
      final nativeUpdate = await nativeUpdateFuture;
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
      // used build 3097. A build number alone must never offer a lower visible
      // version, but it resolves two builds of the same version.
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
        _installState = needsNativeUpdate ? _InstallState.ready : _InstallState.checking;
        _status = needsNativeUpdate
            ? 'A new Inhouse Photos app version is ready.'
            : 'Checking for secure data updates...';
        if (needsNativeUpdate) {
          _showUpdateScreen = true;
        }
      });

      if (!needsNativeUpdate) {
        await _installDataUpdate(keepResultVisible: showScreen);
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

  Future<void> _installDataUpdate({required bool keepResultVisible}) async {
    _ShorebirdSnapshot snapshot;
    try {
      snapshot = await _ShorebirdUpdateClient.inspect(checkNetwork: true).timeout(_dataUpdateCheckTimeout);
    } catch (_) {
      snapshot = const _ShorebirdSnapshot.unavailable();
    }
    if (!mounted) {
      return;
    }

    if (!snapshot.available) {
      _finishDataUpdateCheck(
        'Data updates are unavailable right now. Your installed app is ready to use.',
        keepResultVisible: keepResultVisible,
      );
      return;
    }

    if (snapshot.requiresRestart) {
      _showPreparedDataUpdate(snapshot.nextPatch);
      return;
    }

    if (!snapshot.downloadable) {
      _finishDataUpdateCheck('Inhouse Photos is fully up to date.', keepResultVisible: keepResultVisible);
      return;
    }

    setState(() {
      _showUpdateScreen = true;
      _installState = _InstallState.downloadingData;
      _status = 'Downloading and verifying the latest data update...';
    });

    final result = await _ShorebirdUpdateClient.install().timeout(
      _dataUpdateInstallTimeout,
      onTimeout: () => const _ShorebirdInstallResult(-1, 'The update timed out.'),
    );
    if (!mounted) {
      return;
    }

    if (!result.accepted) {
      setState(() {
        _installState = _InstallState.error;
        _status = result.message.isEmpty
            ? 'The data update could not be installed. You can keep using Photos and try again later.'
            : 'The data update could not be installed: ${result.message}';
      });
      return;
    }

    if (result.status == _shorebirdNoUpdate) {
      setState(() {
        _installState = _InstallState.upToDate;
        _status = 'Inhouse Photos is fully up to date.';
        _showUpdateScreen = false;
      });
      return;
    }

    if (!snapshot.downloadable) {
      setState(() {
        _showUpdateScreen = true;
        _installState = _InstallState.downloadingData;
        _status = 'Finishing and verifying the data update...';
      });
    }

    final preparedPatch = await _waitForPreparedPatch();
    if (!mounted) {
      return;
    }
    if (preparedPatch != null) {
      _showPreparedDataUpdate(preparedPatch);
      return;
    }

    final settledSnapshot = await _ShorebirdUpdateClient.inspect(checkNetwork: true);
    if (!mounted) {
      return;
    }
    if (settledSnapshot.requiresRestart) {
      _showPreparedDataUpdate(settledSnapshot.nextPatch);
      return;
    }
    if (settledSnapshot.available && !settledSnapshot.downloadable) {
      setState(() {
        _installState = _InstallState.upToDate;
        _status = 'Inhouse Photos is fully up to date.';
        _showUpdateScreen = false;
      });
      return;
    }

    setState(() {
      _installState = _InstallState.error;
      _status = 'The data update did not finish. You can keep using Photos and try again later.';
    });
  }

  void _finishDataUpdateCheck(String status, {required bool keepResultVisible}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _installState = _InstallState.upToDate;
      _status = status;
      _showUpdateScreen = keepResultVisible;
    });
  }

  Future<int?> _waitForPreparedPatch() async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      final snapshot = await _ShorebirdUpdateClient.inspect(checkNetwork: false);
      if (snapshot.requiresRestart) {
        return snapshot.nextPatch;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  void _showPreparedDataUpdate(int patchNumber) {
    if (!mounted) {
      return;
    }
    setState(() {
      _showUpdateScreen = true;
      _installState = _InstallState.restartRequired;
      _downloadProgress = 1;
      _status = 'Update $patchNumber is downloaded, verified, and installed. Reopen the app to activate it.';
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
        } else if (result == 'downloading') {
          _installState = _InstallState.downloadingApk;
          _status = 'The update download is continuing securely...';
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
        if (error.code == 'already_downloading') {
          _installState = _InstallState.downloadingApk;
          _status = 'The update download is still running. Progress will continue here automatically.';
        } else {
          _installState = _InstallState.error;
          _status = formatInhouseInstallerError(error.message ?? '');
        }
      });
    }
  }

  Future<void> _restartAndActivate() async {
    if (Platform.isAndroid) {
      setState(() {
        _installState = _InstallState.checking;
        _status = 'Restarting Inhouse Photos to activate the update...';
      });
      try {
        await _updateChannel.invokeMethod<String>('restartApp');
      } on PlatformException {
        // Older native bases cannot relaunch themselves. Closing remains a
        // safe fallback until the one-time native base update is installed.
        await SystemNavigator.pop();
      }
    }
  }

  void _openApp() {
    setState(() => _showUpdateScreen = false);
  }

  @override
  Widget build(BuildContext context) {
    final nativeUpdate = _apkUpdate;
    if (!_showUpdateScreen) {
      return widget.child;
    }

    final isNativeUpdate = nativeUpdate != null;
    final isChecking = _installState == _InstallState.checking;
    final isDownloadingData = _installState == _InstallState.downloadingData;
    final isDownloadingApk = _installState == _InstallState.downloadingApk;
    final isDownloading = isDownloadingData || isDownloadingApk;
    final needsRestart = _installState == _InstallState.restartRequired;
    final isUpToDate = _installState == _InstallState.upToDate;
    final hasError = _installState == _InstallState.error;
    final heading = switch (_installState) {
      _InstallState.checking => 'Checking for updates',
      _InstallState.upToDate => 'You are up to date',
      _InstallState.downloadingData => 'Installing data update',
      _InstallState.restartRequired => 'Update installed',
      _InstallState.downloadingApk => 'Downloading app update',
      _ => isNativeUpdate ? 'App update ready' : 'Checking for updates',
    };

    return PopScope(
      canPop: false,
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
                              if (isDownloading) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: isDownloadingData ? null : _downloadProgress,
                                    minHeight: 9,
                                    backgroundColor: const Color(0xFF3A302A),
                                    valueColor: const AlwaysStoppedAnimation(Color(0xFFD97736)),
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Text(
                                  isDownloadingData
                                      ? 'Keep Inhouse Photos open until verification finishes'
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
                                  onPressed: (isChecking || isDownloading) && isNativeUpdate
                                      ? null
                                      : (!isNativeUpdate && (isChecking || isDownloadingData))
                                      ? _openApp
                                      : needsRestart
                                      ? () => unawaited(_restartAndActivate())
                                      : hasError
                                      ? () => unawaited(_checkForUpdate(showScreen: true))
                                      : isNativeUpdate
                                      ? _installNativeUpdate
                                      : isUpToDate
                                      ? _openApp
                                      : null,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFD97736),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(vertical: 15),
                                  ),
                                  child: Text(switch (_installState) {
                                    _InstallState.checking => isNativeUpdate ? 'Checking...' : 'Open Photos',
                                    _InstallState.upToDate => 'Open Photos',
                                    _InstallState.downloadingData => 'Open Photos',
                                    _InstallState.restartRequired =>
                                      Platform.isAndroid ? 'Activate update' : 'Close and reopen',
                                    _InstallState.downloadingApk => 'Downloading...',
                                    _InstallState.permissionRequired => 'Continue installation',
                                    _InstallState.error => 'Try again',
                                    _ =>
                                      isNativeUpdate
                                          ? (Platform.isIOS ? 'Open SideStore' : 'Install app update')
                                          : 'Open Photos',
                                  }),
                                ),
                              ),
                              if (needsRestart) ...[
                                const SizedBox(height: 12),
                                Text(
                                  Platform.isAndroid
                                      ? 'Inhouse Photos will restart automatically.'
                                      : 'Close Inhouse Photos completely, then open it again to activate the update.',
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
