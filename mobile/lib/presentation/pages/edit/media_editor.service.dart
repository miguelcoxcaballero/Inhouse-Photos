import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/pages/edit/media_edit_options.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

/// Each editor owns a cache directory; neither acquisition nor export mutates an original.
class MediaEditorService {
  static const channel = MethodChannel('com.inhousesoftware.photos/media_editor');
  Directory? _directory;
  String? _operationId;
  bool _disposed = false;
  bool _cancelRequested = false;
  Future<void>? _activeWork;

  Future<T> _track<T>(Future<T> operation) {
    _activeWork = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<File> acquire(BaseAsset asset, void Function(double?) onProgress) => _track(_acquire(asset, onProgress));

  Future<File> _acquire(BaseAsset asset, void Function(double?) onProgress) async {
    final directory = await Directory(
      p.join((await getTemporaryDirectory()).path, 'media-editor'),
    ).create(recursive: true);
    _directory = await directory.createTemp('session-');
    if (_disposed) {
      throw StateError('Editor closed');
    }
    // A server-edited photo must start with the displayed edited original.
    if (asset.localId != null && !asset.isEdited) {
      try {
        final entity = await AssetEntity.fromId(asset.localId!);
        final file = await entity?.originFile;
        if (file != null && await file.exists()) {
          return file;
        }
      } catch (_) {
        // A stale MediaStore id or revoked local access can still have a server original.
      }
    }
    final remoteId = asset.remoteId;
    if (remoteId == null) {
      throw StateError('Original is no longer available on this device');
    }
    final request = http.Request('GET', Uri.parse(getOriginalUrlForRemoteId(remoteId)))
      ..headers.addAll(ApiService.getRequestHeaders());
    final response = await NetworkRepository.client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw HttpException('Could not download original (${response.statusCode})');
    }
    final file = File(p.join(_directory!.path, 'original${p.extension(asset.name)}'));
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 45))) {
        if (_disposed) {
          throw StateError('Editor closed');
        }
        sink.add(chunk);
        received += chunk.length;
        final length = response.contentLength;
        onProgress(length != null && length > 0 ? (received / length).clamp(0, 1) : null);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return file;
  }

  Future<Map<Object?, Object?>> inspect(File source, {required bool isVideo}) =>
      _track(_inspect(source, isVideo: isVideo));

  Future<Map<Object?, Object?>> _inspect(File source, {required bool isVideo}) async {
    if (_disposed) {
      throw StateError('Editor closed');
    }
    return (await channel.invokeMapMethod<Object?, Object?>('inspect', {
      'sourcePath': source.path,
      'isVideo': isVideo,
      'outputDirectory': _directory!.path,
    }))!;
  }

  Future<void> saveCopy(
    File source,
    BaseAsset asset,
    MediaEditOptions options,
    void Function(double) onProgress, {
    ExifInfo? metadata,
  }) => _track(_saveCopy(source, asset, options, onProgress, metadata));

  Future<void> _saveCopy(
    File source,
    BaseAsset asset,
    MediaEditOptions options,
    void Function(double) onProgress,
    ExifInfo? metadata,
  ) async {
    if (_disposed) {
      throw StateError('Editor closed');
    }
    _cancelRequested = false;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _operationId = id;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        if (args['operationId'] == id) {
          onProgress((args['progress'] as num).toDouble().clamp(0, 0.99));
        }
      }
    });
    try {
      final path = await channel.invokeMethod<String>('export', {
        'sourcePath': source.path,
        'outputDirectory': _directory!.path,
        'isVideo': asset.isVideo,
        'operationId': id,
        ...options.toMap(),
        ...editedLocationParameters(metadata, hasRemote: asset.hasRemote),
      });
      if (_disposed || _cancelRequested || path == null) {
        throw StateError('Export cancelled');
      }
      // Library insertion is atomic and cannot be cancelled once started.
      _operationId = null;
      onProgress(1);
      final name = '${p.basenameWithoutExtension(asset.name)}_edited_$id${p.extension(path)}';
      if (asset.isVideo) {
        await PhotoManager.editor.saveVideo(
          File(path),
          title: name,
          relativePath: 'Movies/Inhouse Edits',
          creationDate: asset.createdAt,
        );
      } else {
        await PhotoManager.editor.saveImageWithPath(
          path,
          title: name,
          relativePath: 'Pictures/Inhouse Edits',
          creationDate: asset.createdAt,
        );
      }
    } finally {
      _operationId = null;
      channel.setMethodCallHandler(null);
    }
  }

  Future<void> cancel() async {
    _cancelRequested = true;
    final id = _operationId;
    if (id != null) {
      await channel.invokeMethod<void>('cancel', {'operationId': id});
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
    // Never delete the source/preview while acquisition or a native codec still uses it.
    await _activeWork;
    final directory = _directory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
