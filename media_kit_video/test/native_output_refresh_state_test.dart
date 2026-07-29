import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/native_output_refresh_state.dart';

void main() {
  test(
    'coalesces refreshes and completes only after correlated surface and frame',
    () async {
      final readyGenerations = <int>[];
      final invocations = <int>[];
      final state = NativeOutputRefreshState(
        timeout: const Duration(seconds: 1),
        onReady: readyGenerations.add,
      );

      final first = state.refresh((generation) async {
        invocations.add(generation);
      });
      final duplicate = state.refresh((generation) async {
        invocations.add(generation);
      });

      expect(invocations, <int>[1]);
      expect(
        state.acceptSurface(
          generation: 0,
          surfaceId: 90,
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
      state.acceptFrame(generation: 0);

      var completed = false;
      first.then((_) => completed = true);
      state.acceptFrame(generation: 1);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      expect(
        state.acceptSurface(
          generation: 1,
          surfaceId: 0,
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
      expect(
        state.acceptSurface(
          generation: 1,
          surfaceId: 91,
          width: 0,
          height: 0,
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      expect(
        state.acceptSurface(
          generation: 1,
          surfaceId: 91,
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
      await Future.wait(<Future<void>>[first, duplicate]);

      expect(readyGenerations, <int>[1]);
      expect(invocations, <int>[1]);
      state.dispose();
    },
  );

  test('initial output accepts generation zero exactly once', () {
    final readyGenerations = <int>[];
    final state = NativeOutputRefreshState(
      timeout: const Duration(seconds: 1),
      onReady: readyGenerations.add,
    );

    expect(
      state.acceptSurface(
        generation: 0,
        surfaceId: 12,
        width: 1280,
        height: 720,
      ),
      isTrue,
    );
    state.acceptFrame(generation: 0);
    state.acceptFrame(generation: 0);

    expect(readyGenerations, <int>[0]);
    state.dispose();
  });

  test('initial frame arriving before a valid surface is retained', () {
    final readyGenerations = <int>[];
    final state = NativeOutputRefreshState(
      timeout: const Duration(seconds: 1),
      onReady: readyGenerations.add,
    );

    state.acceptFrame(generation: 0);
    expect(readyGenerations, isEmpty);
    expect(
      state.acceptSurface(
        generation: 0,
        surfaceId: 0,
        width: 0,
        height: 0,
      ),
      isFalse,
    );
    expect(readyGenerations, isEmpty);

    expect(
      state.acceptSurface(
        generation: 0,
        surfaceId: 13,
        width: 1920,
        height: 1080,
      ),
      isTrue,
    );
    expect(readyGenerations, <int>[0]);
    state.dispose();
  });

  test('bootstrap attachment publishes id without qualifying first frame', () {
    var idPublished = false;
    final readyGenerations = <int>[];
    final state = NativeOutputRefreshState(
      timeout: const Duration(seconds: 1),
      onReady: readyGenerations.add,
    );

    expect(
      state.acceptBootstrapSurface(
        generation: 0,
        onAccept: () => idPublished = true,
      ),
      isTrue,
    );
    expect(idPublished, isTrue);
    state.acceptFrame(generation: 0);
    expect(readyGenerations, isEmpty);

    expect(
      state.acceptSurface(
        generation: 0,
        surfaceId: 14,
        width: 1920,
        height: 1080,
      ),
      isTrue,
    );
    expect(readyGenerations, <int>[0]);
    state.dispose();
  });

  test(
    'same-size qualification releases a refresh frame retained after bootstrap',
    () async {
      final readyGenerations = <int>[];
      final state = NativeOutputRefreshState(
        timeout: const Duration(seconds: 1),
        onReady: readyGenerations.add,
      );

      final refresh = state.refresh((_) async {});
      expect(
        state.acceptBootstrapSurface(generation: 1),
        isTrue,
      );
      state.acceptFrame(generation: 1);
      expect(readyGenerations, isEmpty);

      expect(
        state.acceptSurface(
          generation: 1,
          surfaceId: 14,
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
      await refresh;

      expect(readyGenerations, <int>[1]);
      state.dispose();
    },
  );

  test('dynamic refresh reuses known video geometry instead of 1x1', () {
    expect(
      resolveNativeOutputRefreshGeometry(
        configuredWidth: null,
        configuredHeight: null,
        videoWidth: 3840,
        videoHeight: 2160,
      ),
      (width: 3840, height: 2160),
    );
    expect(
      resolveNativeOutputRefreshGeometry(
        configuredWidth: 1280,
        configuredHeight: 720,
        videoWidth: 3840,
        videoHeight: 2160,
      ),
      (width: 1280, height: 720),
    );
    expect(
      resolveNativeOutputRefreshGeometry(
        configuredWidth: null,
        configuredHeight: null,
        videoWidth: 0,
        videoHeight: 0,
      ),
      (width: null, height: null),
    );
  });

  test('current detachment is published but a stale detachment is rejected',
      () async {
    var attached = false;
    var attachmentEpoch = 0;
    final state = NativeOutputRefreshState(
      timeout: const Duration(seconds: 1),
      onReady: (_) {},
    );

    expect(
      state.acceptSurface(
        generation: 0,
        surfaceId: 50,
        width: 1920,
        height: 1080,
        onAccept: () {
          attached = true;
          attachmentEpoch++;
        },
      ),
      isTrue,
    );
    expect(attached, isTrue);
    expect(attachmentEpoch, 1);

    expect(
      state.acceptDetachment(
        generation: 0,
        onAccept: () => attached = false,
      ),
      isTrue,
    );
    expect(attached, isFalse);
    expect(attachmentEpoch, 1);

    final refresh = state.refresh((_) async {});
    expect(
      state.acceptSurface(
        generation: 1,
        surfaceId: 51,
        width: 3840,
        height: 2160,
        onAccept: () {
          attached = true;
          attachmentEpoch++;
        },
      ),
      isTrue,
    );
    state.acceptFrame(generation: 1);
    await refresh;
    expect(attached, isTrue);
    expect(attachmentEpoch, 2);

    expect(
      state.acceptDetachment(
        generation: 0,
        onAccept: () => attached = false,
      ),
      isFalse,
    );
    expect(attached, isTrue);
    expect(attachmentEpoch, 2);
    state.dispose();
  });

  test('timeout rejects late callbacks and a retry uses a newer generation',
      () async {
    final readyGenerations = <int>[];
    final invocations = <int>[];
    final state = NativeOutputRefreshState(
      timeout: const Duration(milliseconds: 20),
      onReady: readyGenerations.add,
    );

    await expectLater(
      state.refresh((generation) async {
        invocations.add(generation);
      }),
      throwsA(isA<TimeoutException>()),
    );

    expect(
      state.acceptSurface(
        generation: 1,
        surfaceId: 21,
        width: 1920,
        height: 1080,
      ),
      isFalse,
    );
    state.acceptFrame(generation: 1);
    expect(readyGenerations, isEmpty);

    final retry = state.refresh((generation) async {
      invocations.add(generation);
    });
    expect(
      state.acceptSurface(
        generation: 2,
        surfaceId: 22,
        width: 1920,
        height: 1080,
      ),
      isTrue,
    );
    state.acceptFrame(generation: 2);
    await retry;

    expect(invocations, <int>[1, 2]);
    expect(readyGenerations, <int>[2]);
    state.dispose();
  });

  test('native invocation failure is bounded and permits a retry', () async {
    final state = NativeOutputRefreshState(
      timeout: const Duration(seconds: 1),
      onReady: (_) {},
    );

    await expectLater(
      state.refresh(
        (_) => Future<void>.error(StateError('native_refresh_failed')),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'native_refresh_failed',
        ),
      ),
    );

    final retry = state.refresh((_) async {});
    expect(
      state.acceptSurface(
        generation: 2,
        surfaceId: 32,
        width: 1920,
        height: 1080,
      ),
      isTrue,
    );
    state.acceptFrame(generation: 2);
    await retry;
    state.dispose();
  });

  test('dispose rejects pending work and ignores every stale callback',
      () async {
    final readyGenerations = <int>[];
    final state = NativeOutputRefreshState(
      timeout: const Duration(seconds: 1),
      onReady: readyGenerations.add,
    );
    final pending = state.refresh((_) async {});

    state.dispose();

    await expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'native_output_refresh_disposed',
        ),
      ),
    );
    expect(
      state.acceptSurface(
        generation: 1,
        surfaceId: 41,
        width: 1920,
        height: 1080,
      ),
      isFalse,
    );
    state.acceptFrame(generation: 1);
    expect(readyGenerations, isEmpty);
    expect(
      () => state.refresh((_) async {}),
      throwsA(isA<StateError>()),
    );
  });
}
