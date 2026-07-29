import 'dart:async';

typedef NativeOutputRefreshInvoker = Future<void> Function(int generation);
typedef NativeOutputReadyCallback = void Function(int generation);

({int? width, int? height}) resolveNativeOutputRefreshGeometry({
  required int? configuredWidth,
  required int? configuredHeight,
  required int? videoWidth,
  required int? videoHeight,
}) {
  int? positive(int? value) => value != null && value > 0 ? value : null;

  return (
    width: positive(configuredWidth) ?? positive(videoWidth),
    height: positive(configuredHeight) ?? positive(videoHeight),
  );
}

/// Correlates a desktop native-output replacement with its texture and frame.
///
/// A refresh is complete only after the same generation has published both a
/// replacement texture and a rendered frame. Concurrent callers share one
/// request, while timeouts, invocation failures, and disposal permanently
/// reject callbacks from that generation.
final class NativeOutputRefreshState {
  NativeOutputRefreshState({
    required this.timeout,
    required this.onReady,
  });

  final Duration timeout;
  final NativeOutputReadyCallback onReady;

  int _nextGeneration = 0;
  int _minimumGeneration = 0;
  int _rejectedThrough = -1;
  int _activeGeneration = -1;
  bool _surfaceAttached = false;
  bool _surfaceQualified = false;
  final Set<int> _observedFrames = <int>{};
  final Set<int> _readyGenerations = <int>{};
  _PendingNativeOutputRefresh? _pending;
  bool _disposed = false;

  Future<void> refresh(NativeOutputRefreshInvoker invoke) {
    if (_disposed) {
      throw StateError('native_output_refresh_disposed');
    }
    final existing = _pending;
    if (existing != null) {
      return existing.completer.future;
    }

    final generation = ++_nextGeneration;
    _minimumGeneration = generation;
    final pending = _PendingNativeOutputRefresh(generation);
    _pending = pending;
    pending.timer = Timer(timeout, () {
      _fail(
        pending,
        TimeoutException(
          'native_output_refresh_timeout',
          timeout,
        ),
        StackTrace.current,
      );
    });

    Future<void>.sync(() => invoke(generation)).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _fail(pending, error, stackTrace);
      },
    );
    return pending.completer.future;
  }

  /// Accepts the replacement texture for [generation].
  ///
  /// [onAccept] is run before readiness can complete, so public texture and
  /// surface-epoch state is already current when observers receive onReady.
  bool acceptSurface({
    required int generation,
    required int surfaceId,
    required int width,
    required int height,
    void Function()? onAccept,
  }) {
    if (surfaceId <= 0 || width <= 0 || height <= 0 || !_accepts(generation)) {
      return false;
    }
    final pending = _pending;
    if (pending != null && pending.generation != generation) {
      return false;
    }

    _activeGeneration = generation;
    _surfaceAttached = true;
    _surfaceQualified = true;
    onAccept?.call();
    if (pending != null) {
      pending.surfaceAccepted = true;
      _completeIfReady(pending);
    } else if (_observedFrames.contains(generation)) {
      _publishReady(generation);
    }
    return true;
  }

  /// Publishes a valid texture identifier before native video geometry exists.
  ///
  /// Flutter must mount the texture to break the initial render deadlock, but
  /// a bootstrap surface never satisfies first-frame readiness on its own.
  bool acceptBootstrapSurface({
    required int generation,
    void Function()? onAccept,
  }) {
    if (!_accepts(generation)) return false;
    final pending = _pending;
    if (pending != null && pending.generation != generation) {
      return false;
    }

    _activeGeneration = generation;
    _surfaceAttached = true;
    _surfaceQualified = false;
    if (pending != null) pending.surfaceAccepted = false;
    onAccept?.call();
    return true;
  }

  /// Publishes a detached output only when [generation] still owns recovery.
  bool acceptDetachment({
    required int generation,
    void Function()? onAccept,
  }) {
    if (!_accepts(generation)) return false;
    final pending = _pending;
    if (pending != null && pending.generation != generation) {
      return false;
    }

    _activeGeneration = generation;
    _surfaceAttached = false;
    _surfaceQualified = false;
    if (pending != null) pending.surfaceAccepted = false;
    onAccept?.call();
    return true;
  }

  /// Records a real rendered frame from the native output [generation].
  void acceptFrame({required int generation}) {
    if (!_accepts(generation)) return;
    if (generation != _activeGeneration ||
        !_surfaceAttached ||
        !_surfaceQualified) {
      final pending = _pending;
      if (pending != null && pending.generation == generation) {
        pending.frameRendered = true;
      } else {
        _observedFrames.add(generation);
      }
      return;
    }

    final pending = _pending;
    if (pending != null) {
      if (pending.generation != generation) return;
      pending.frameRendered = true;
      _completeIfReady(pending);
      return;
    }
    _publishReady(generation);
  }

  bool _accepts(int generation) {
    if (_disposed ||
        generation < _minimumGeneration ||
        generation <= _rejectedThrough ||
        generation > _nextGeneration) {
      return false;
    }
    return true;
  }

  void _completeIfReady(_PendingNativeOutputRefresh pending) {
    if (!identical(_pending, pending) ||
        !pending.surfaceAccepted ||
        !pending.frameRendered) {
      return;
    }
    _publishReady(pending.generation);
    pending.timer?.cancel();
    _pending = null;
    if (!pending.completer.isCompleted) {
      pending.completer.complete();
    }
  }

  void _publishReady(int generation) {
    if (!_readyGenerations.add(generation)) return;
    _observedFrames.remove(generation);
    onReady(generation);
  }

  void _fail(
    _PendingNativeOutputRefresh pending,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!identical(_pending, pending)) return;
    pending.timer?.cancel();
    _pending = null;
    _rejectedThrough = pending.generation;
    _observedFrames.remove(pending.generation);
    if (!pending.completer.isCompleted) {
      pending.completer.completeError(error, stackTrace);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      pending.timer?.cancel();
      _rejectedThrough = pending.generation;
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('native_output_refresh_disposed'),
          StackTrace.current,
        );
      }
    }
    _observedFrames.clear();
    _readyGenerations.clear();
  }
}

final class _PendingNativeOutputRefresh {
  _PendingNativeOutputRefresh(this.generation);

  final int generation;
  final Completer<void> completer = Completer<void>();
  Timer? timer;
  bool surfaceAccepted = false;
  bool frameRendered = false;
}
