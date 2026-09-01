import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

String _thumbHash(int seed) {
  final rgba = Uint8List.fromList([
    for (var i = 0; i < 16; i++) ...[(seed * 31 + i * 13) % 256, (seed * 17 + i * 29) % 256, (seed * 47 + i * 7) % 256, 255],
  ]);
  return base64Encode(thumbhash.rgbaToThumbHash(4, 4, rgba));
}

RemoteAsset _asset(
  int i, {
  String? id,
  DateTime? updatedAt,
  int? width,
  int? height,
  String? thumbHash,
}) => RemoteAsset(
  id: id ?? 'asset-$i',
  name: 'IMG_$i.jpg',
  checksum: 'checksum-$i',
  ownerId: 'owner',
  createdAt: DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
  updatedAt: updatedAt ?? DateTime.utc(2024, 6, 1).add(Duration(minutes: i)),
  width: width ?? 4032,
  height: height ?? 3024,
  type: AssetType.image,
  thumbHash: thumbHash ?? _thumbHash(i),
  isEdited: false,
);

String _sign(List<BaseAsset> assets, {int columnCount = 48, int targetPixels = 32}) =>
    denseContentSignature(assets, columnCount: columnCount, targetPixels: targetPixels);

void main() {
  test('the same panel always fingerprints the same', () {
    final assets = List<BaseAsset>.generate(192, _asset);
    expect(_sign(assets), _sign(List<BaseAsset>.generate(192, _asset)));
  });

  test('every field that changes what is drawn changes the fingerprint', () {
    final base = List<BaseAsset>.generate(8, _asset);
    final signature = _sign(base);

    List<BaseAsset> withLast(RemoteAsset replacement) => [...base.take(7), replacement];

    expect(_sign(withLast(_asset(7, id: 'other'))), isNot(signature), reason: 'identity');
    expect(_sign(withLast(_asset(7, updatedAt: DateTime.utc(2025)))), isNot(signature), reason: 'edit time');
    expect(_sign(withLast(_asset(7, width: 4033))), isNot(signature), reason: 'width');
    expect(_sign(withLast(_asset(7, height: 3025))), isNot(signature), reason: 'height');
    expect(_sign(withLast(_asset(7, thumbHash: _thumbHash(99)))), isNot(signature), reason: 'thumbhash');
    expect(_sign(base.reversed.toList()), isNot(signature), reason: 'order');
    expect(_sign(base.take(7).toList()), isNot(signature), reason: 'count');
    expect(_sign(base, columnCount: 36), isNot(signature), reason: 'column count');
    expect(_sign(base, targetPixels: 64), isNot(signature), reason: 'cell size');
  });

  test('field boundaries cannot be shifted without changing the fingerprint', () {
    // Without mixing each field's length, "ab"+"c" and "a"+"bc" across adjacent
    // fields fold to the same accumulator state.
    final a = [_asset(0, id: 'ab', thumbHash: _thumbHash(1))];
    final b = [_asset(0, id: 'a', thumbHash: _thumbHash(1))];
    expect(_sign(a), isNot(_sign(b)));
  });

  test('a local photo uses its generated preview, exactly like a remote one', () {
    // The whole point of the local preview: before this, `denseThumbHashOf`
    // matched only RemoteAsset, so a photo waiting to be backed up had nothing
    // to draw and its tile stayed flat until a full thumbnail decoded. That is
    // why not-yet-uploaded photos were the ones visibly loading.
    final hash = _thumbHash(3);
    final local = LocalAsset(
      id: 'local-3',
      name: 'photo-3.jpg',
      checksum: 'checksum-3',
      type: AssetType.image,
      createdAt: DateTime.utc(2024),
      updatedAt: DateTime.utc(2024),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
      thumbHash: hash,
    );
    expect(denseThumbHashOf(local), hash);

    final pending = LocalAsset(
      id: 'local-4',
      name: 'photo-4.jpg',
      checksum: 'checksum-4',
      type: AssetType.image,
      createdAt: DateTime.utc(2024),
      updatedAt: DateTime.utc(2024),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );
    expect(denseThumbHashOf(pending), isNull, reason: 'not generated yet is not the same as having none');
    expect(denseThumbHashOf(_asset(3)), _thumbHash(3), reason: 'remote assets are unaffected');
  });

  test('a preview appearing changes the panel fingerprint', () {
    // Otherwise a panel cached while its photos had no previews would keep its
    // blank-celled texture forever, and generation would never become visible.
    LocalAsset local({String? thumbHash}) => LocalAsset(
      id: 'local-1',
      name: 'photo-1.jpg',
      checksum: 'checksum-1',
      type: AssetType.image,
      createdAt: DateTime.utc(2024),
      updatedAt: DateTime.utc(2024),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
      thumbHash: thumbHash,
    );
    expect(_sign([local()]), isNot(_sign([local(thumbHash: _thumbHash(7))])));
  });

  test('the fingerprint is exactly the width the disk cache stores', () {
    // Not cosmetic. The on-disk atlas header reserves a fixed-width field, and
    // the cache refuses - silently, with no error anywhere - to store a panel
    // whose fingerprint is any other length. Emitting a shorter digest disabled
    // the disk cache completely, so scrolling back over photos already seen
    // refetched every thumbnail instead of reading one file.
    for (final count in [1, 8, 144, 192]) {
      final signature = _sign(List<BaseAsset>.generate(count, _asset));
      expect(
        signature,
        hasLength(denseAtlasSignatureLength),
        reason: '$count assets produced a fingerprint the disk cache will drop',
      );
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(signature), isTrue, reason: 'the header field is ASCII hex');
    }
  });

  test('distinct panels across a large library do not collide', () {
    final signatures = <String>{};
    for (var panel = 0; panel < 400; panel++) {
      signatures.add(_sign(List<BaseAsset>.generate(192, (i) => _asset(panel * 192 + i))));
    }
    expect(signatures, hasLength(400));
  });
}
