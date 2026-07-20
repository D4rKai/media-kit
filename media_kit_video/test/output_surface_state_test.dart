import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/utils/video_output_surface_state.dart';

void main() {
  test('detached surface reattachment increments the output epoch', () {
    final state = VideoOutputSurfaceState();

    expect(state.attached.value, isFalse);
    expect(state.epoch.value, 0);

    state.update(101);
    expect(state.attached.value, isTrue);
    expect(state.epoch.value, 1);

    state.update(0);
    expect(state.attached.value, isFalse);
    expect(state.epoch.value, 1);

    state.update(102);
    expect(state.attached.value, isTrue);
    expect(state.epoch.value, 2);

    state.dispose();
  });

  test('VideoController exposes the output surface lifecycle contract', () {
    expect(_surfaceContract, isA<void Function(VideoController)>());
  });
}

void _surfaceContract(VideoController controller) {
  final ValueListenable<bool> attached = controller.outputSurfaceAttached;
  final ValueListenable<int> epoch = controller.outputSurfaceEpoch;
  final Future<void> refresh = controller.refreshVideoOutput();
  attached.addListener(() {});
  epoch.addListener(() {});
  expect(refresh, isA<Future<void>>());
}
