import 'dart:ui';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/utils/android_surface_size.dart';

void main() {
  test('fits a 4K surface inside 1080p with even dimensions', () {
    final size = fitAndroidSurfaceSize(
      const Size(3840, 2160),
      maximum: const Size(1920, 1080),
    );

    expect(size, const Size(1920, 1080));
    expect(size.width.toInt().isEven, isTrue);
    expect(size.height.toInt().isEven, isTrue);
  });

  test('preserves aspect ratio and bounds for non-16:9 surfaces', () {
    final size = fitAndroidSurfaceSize(
      const Size(4096, 2160),
      maximum: const Size(1920, 1080),
    );

    expect(size.width, lessThanOrEqualTo(1920));
    expect(size.height, lessThanOrEqualTo(1080));
    expect(size.width.toInt().isEven, isTrue);
    expect(size.height.toInt().isEven, isTrue);
    expect(size.aspectRatio, closeTo(4096 / 2160, 0.01));
  });

  test('leaves an already bounded even surface unchanged', () {
    expect(
      fitAndroidSurfaceSize(
        const Size(1280, 720),
        maximum: const Size(1920, 1080),
      ),
      const Size(1280, 720),
    );
  });

  test('does not alter Android output when no limit is configured', () {
    expect(
      resolveAndroidSurfaceSize(const Size(3840, 2160), maximum: null),
      const Size(3840, 2160),
    );
  });

  test('Android surface limit is opt-in and survives configuration copies', () {
    const uncapped = VideoControllerConfiguration();
    const capped = VideoControllerConfiguration(
      androidSurfaceSizeLimit: Size(1920, 1080),
    );

    expect(uncapped.androidSurfaceSizeLimit, isNull);
    expect(capped.androidSurfaceSizeLimit, const Size(1920, 1080));
    expect(
      capped
          .copyWith(enableHardwareAcceleration: false)
          .androidSurfaceSizeLimit,
      const Size(1920, 1080),
    );
  });

  test(
      'Android controller resolves video parameters through the configured limit',
      () {
    final source = File(
      'lib/src/video_controller/android_video_controller/real.dart',
    ).readAsStringSync();

    expect(source, contains('resolveAndroidSurfaceSize('));
    expect(source, contains('maximum: configuration.androidSurfaceSizeLimit'));
  });
}
