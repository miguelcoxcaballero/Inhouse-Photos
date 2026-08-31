import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';

void main() {
  test('local thumbnail cache keys include requested physical resolution', () {
    final small = LocalThumbProvider(id: 'asset-1', assetType: AssetType.image, size: const Size.square(32));
    final crisp = LocalThumbProvider(id: 'asset-1', assetType: AssetType.image, size: const Size.square(96));
    final same = LocalThumbProvider(id: 'asset-1', assetType: AssetType.image, size: const Size.square(96));

    expect(small, isNot(crisp));
    expect(crisp, same);
    expect(crisp.hashCode, same.hashCode);
  });
}
