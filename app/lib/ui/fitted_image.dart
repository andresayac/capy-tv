import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../data/image_store.dart';

/// [image] decoded no bigger than [fit] needs to fill [size] (physical pixels), and never bigger
/// than it is. Providers' posters and backdrops are often 2000×3000 or 4K: decoded whole that is
/// 24–33 MB each, for a card that shows 300×450, and a screen of them takes more memory than a TV
/// stick has. [image] as it is when [size] is no real size (an unbounded box).
ImageProvider fitted(ImageProvider image, Size size, BoxFit fit) =>
    size.isFinite && !size.isEmpty ? _Fitted(image, size.width.ceil(), size.height.ceil(), fit) : image;

class _Fitted extends ImageProvider<_FittedKey> {
  const _Fitted(this.image, this.width, this.height, this.fit);

  final ImageProvider image;
  final int width, height;
  final BoxFit fit;

  @override
  Future<_FittedKey> obtainKey(ImageConfiguration configuration) {
    // As ResizeImage does: at once when the image's own key comes at once, so one already decoded
    // shows in the same frame
    Completer<_FittedKey>? later;
    SynchronousFuture<_FittedKey>? now;
    image.obtainKey(configuration).then((key) {
      final fittedKey = _FittedKey(key, width, height, fit);
      final waiting = later;
      if (waiting == null) {
        now = SynchronousFuture(fittedKey);
      } else {
        waiting.complete(fittedKey);
      }
    });
    if (now != null) return now!;
    return (later = Completer()).future;
  }

  @override
  ImageStreamCompleter loadImage(_FittedKey key, ImageDecoderCallback decode) {
    final completer = image.loadImage(key.image, (buffer, {getTargetSize}) => decode(buffer, getTargetSize: _size));
    // As ResizeImage does: one that fails goes from the cache, so it is asked for again the next
    // time it shows (the image's own provider takes only its own key out). After a moment: the
    // failure can come before the cache has it
    completer.addEphemeralErrorListener(
      (_, _) => scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key)),
    );
    return completer;
  }

  ui.TargetImageSize _size(int w, int h) {
    final across = width / w, down = height / h;
    final scale = fit == BoxFit.contain || fit == BoxFit.scaleDown ? math.min(across, down) : math.max(across, down);
    if (scale >= 1) return const ui.TargetImageSize();
    return ui.TargetImageSize(width: math.max(1, (w * scale).ceil()), height: math.max(1, (h * scale).ceil()));
  }
}

@immutable
class _FittedKey {
  const _FittedKey(this.image, this.width, this.height, this.fit);

  final Object image;
  final int width, height;
  final BoxFit fit;

  @override
  bool operator ==(Object other) =>
      other is _FittedKey && other.image == image && other.width == width && other.height == height && other.fit == fit;

  @override
  int get hashCode => Object.hash(image, width, height, fit);
}

/// The image at [url], through [ImageStore]. One that fails to decode was no image: it is not kept.
@immutable
class StoredImage extends ImageProvider<StoredImage> {
  const StoredImage(this.url);

  final String url;

  @override
  Future<StoredImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(StoredImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _codec(key.url, decode), scale: 1);

  static Future<ui.Codec> _codec(String url, ImageDecoderCallback decode) async {
    final bytes = await ImageStore.instance.bytes(url);
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } on Object {
      ImageStore.instance.forget(url);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is StoredImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
