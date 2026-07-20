import 'dart:math' as math;
import 'dart:ui';

/// Fits [source] inside [maximum] without upscaling.
///
/// Even output dimensions keep decoder and Android surface allocations aligned.
Size fitAndroidSurfaceSize(Size source, {required Size maximum}) {
  if (source.isEmpty || maximum.isEmpty) return source;

  final scale = math.min(
    1.0,
    math.min(maximum.width / source.width, maximum.height / source.height),
  );
  final width = _positiveEven((source.width * scale).floor());
  final height = _positiveEven((source.height * scale).floor());
  return Size(width.toDouble(), height.toDouble());
}

/// Applies an optional Android output-surface bound.
Size resolveAndroidSurfaceSize(Size source, {required Size? maximum}) {
  if (maximum == null) return source;
  return fitAndroidSurfaceSize(source, maximum: maximum);
}

int _positiveEven(int value) {
  final bounded = math.max(2, value);
  return bounded.isEven ? bounded : bounded - 1;
}
