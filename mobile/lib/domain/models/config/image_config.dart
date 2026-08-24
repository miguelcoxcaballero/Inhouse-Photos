enum ImageCacheMode { automatic, compact, performance }

class ImageConfig {
  final bool preferRemote;
  final bool loadOriginal;
  final ImageCacheMode cacheMode;

  const ImageConfig({this.preferRemote = false, this.loadOriginal = false, this.cacheMode = ImageCacheMode.automatic});

  ImageConfig copyWith({bool? preferRemote, bool? loadOriginal, ImageCacheMode? cacheMode}) => ImageConfig(
    preferRemote: preferRemote ?? this.preferRemote,
    loadOriginal: loadOriginal ?? this.loadOriginal,
    cacheMode: cacheMode ?? this.cacheMode,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImageConfig &&
          other.preferRemote == preferRemote &&
          other.loadOriginal == loadOriginal &&
          other.cacheMode == cacheMode);

  @override
  int get hashCode => Object.hash(preferRemote, loadOriginal, cacheMode);

  @override
  String toString() =>
      'ImageConfig(preferRemoteImage: $preferRemote, loadOriginal: $loadOriginal, cacheMode: $cacheMode)';
}
