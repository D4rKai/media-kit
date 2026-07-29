/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/utils/query_decoders.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/native_output_refresh_state.dart';

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  /// Width of the video (from [VideoParams]).
  int? videoParamsWidth;

  /// Height of the video (from [VideoParams]).
  int? videoParamsHeight;

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();
  late final NativeOutputRefreshState _outputRefreshState;
  bool _disposed = false;

  NativePlayer get platform => player.platform as NativePlayer;

  Future<void> setProperty(String key, String value) async {
    await platform.setProperty(key, value, waitForInitialization: false);
  }

  Future<void> setProperties(Map<String, String> properties) async {
    // ORDER IS IMPORTANT.
    for (final entry in properties.entries) {
      await setProperty(entry.key, entry.value);
    }
  }

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;

  /// {@macro native_video_controller}
  NativeVideoController._(
    super.player,
    super.configuration,
  )   : width = configuration.width,
        height = configuration.height {
    _outputRefreshState = NativeOutputRefreshState(
      timeout: const Duration(seconds: 5),
      onReady: (_) {
        if (_disposed) return;
        if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
          waitUntilFirstFrameRenderedCompleter.complete();
        }
      },
    );
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() async {
        if ([0, null].contains(event.dw) || [0, null].contains(event.dh)) {
          return;
        }

        final int handle = await player.handle;

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        if (videoParamsWidth == width && videoParamsHeight == height) {
          return;
        }

        videoParamsWidth = width;
        videoParamsHeight = height;

        await _channel.invokeMethod(
          'VideoOutputManager.SetSize',
          {
            'handle': handle.toString(),
            'width': width.toString(),
            'height': height.toString(),
          },
        );
      }),
    );
  }

  /// {@macro native_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Update [configuration] to have default values.
    configuration = configuration.copyWith(
      vo: configuration.vo ?? 'libmpv',
      hwdec: configuration.hwdec ?? 'auto',
    );

    // Retrieve the native handle of the [Player].
    final handle = await player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // In case no video-decoders are found, this means media_kit_libs_***_audio is being used.
    // Thus, --vid=no is required to prevent libmpv from trying to decode video (otherwise bad things may happen).
    //
    // Search for common H264 decoder to check if video support is available.
    final decoders = await queryDecoders(handle);
    if (!decoders.contains('h264')) {
      throw UnsupportedError(
        '[VideoController] is not available.'
        ' '
        'Please use media_kit_libs_***_video instead of media_kit_libs_***_audio.',
      );
    }

    // Creation:
    final controller = NativeVideoController._(
      player,
      configuration,
    );

    // Register [_dispose] for execution upon [Player.dispose].
    player.platform?.release.add(controller._dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    await controller.setProperties(
      {
        'vo': configuration.vo!,
        'hwdec': configuration.hwdec!,
        'vid': 'auto',
      },
    );

    // Wait until first texture ID is received.
    // We are not waiting on the native-side itself because it will block the UI thread.
    final completer = Completer<void>();
    void listener() {
      final value = controller.id.value;
      if (value != null) {
        debugPrint('NativeVideoController: Texture ID: $value');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    await _channel.invokeMethod(
      'VideoOutputManager.Create',
      {
        'handle': handle.toString(),
        'configuration': {
          'width': configuration.width.toString(),
          'height': configuration.height.toString(),
          'enableHardwareAcceleration':
              configuration.enableHardwareAcceleration,
        },
      },
    );

    await completer.future;
    controller.id.removeListener(listener);

    // Return the [VideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({
    int? width,
    int? height,
  }) async {
    final handle = await player.handle;
    if (this.width == width && this.height == height) {
      // No need to resize if the requested size is same as the current size.
      return;
    }
    if (width != null && height != null) {
      this.width = width;
      this.height = height;
      await _channel.invokeMethod(
        'VideoOutputManager.SetSize',
        {
          'handle': handle.toString(),
          'width': width.toString(),
          'height': height.toString(),
        },
      );
    } else {
      this.width = null;
      this.height = null;
      await _channel.invokeMethod(
        'VideoOutputManager.SetSize',
        {
          'handle': handle.toString(),
          'width': videoParamsWidth?.toString() ?? 'null',
          'height': videoParamsHeight?.toString() ?? 'null',
        },
      );
    }
  }

  @override
  Future<void> refreshVideoOutput() {
    if (!Platform.isWindows) return Future<void>.value();
    return _outputRefreshState.refresh((generation) async {
      final handle = await player.handle;
      final geometry = resolveNativeOutputRefreshGeometry(
        configuredWidth: width,
        configuredHeight: height,
        videoWidth: videoParamsWidth,
        videoHeight: videoParamsHeight,
      );
      await _channel.invokeMethod(
        'VideoOutputManager.Refresh',
        {
          'handle': handle.toString(),
          'generation': generation.toString(),
          'configuration': {
            'width': geometry.width?.toString() ?? 'null',
            'height': geometry.height?.toString() ?? 'null',
            'enableHardwareAcceleration':
                configuration.enableHardwareAcceleration,
          },
        },
      );
    });
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _outputRefreshState.dispose();
    final handle = await player.handle;
    _controllers.remove(handle);
    await videoParamsSubscription?.cancel();
    super.dispose();
    await _channel.invokeMethod(
      'VideoOutputManager.Dispose',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [_channel].
  static final _controllers = HashMap<int, NativeVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler(
          (MethodCall call) async {
            try {
              debugPrint(call.method.toString());
              debugPrint(call.arguments.toString());
              switch (call.method) {
                case 'VideoOutput.Resize':
                  {
                    // Notify about updated texture ID & [Rect].
                    final int handle = call.arguments['handle'];
                    final Rect rect = Rect.fromLTWH(
                      call.arguments['rect']['left'] * 1.0,
                      call.arguments['rect']['top'] * 1.0,
                      call.arguments['rect']['width'] * 1.0,
                      call.arguments['rect']['height'] * 1.0,
                    );
                    final int id = call.arguments['id'];
                    final int generation =
                        call.arguments['generation'] as int? ?? 0;
                    final controller = _controllers[handle];
                    if (controller != null) {
                      if (id <= 0) {
                        controller._outputRefreshState.acceptDetachment(
                          generation: generation,
                          onAccept: () {
                            controller.rect.value = rect;
                            controller.id.value = id;
                            controller.updateOutputSurface(0);
                          },
                        );
                      } else if (rect.width <= 0 || rect.height <= 0) {
                        controller._outputRefreshState.acceptBootstrapSurface(
                          generation: generation,
                          onAccept: () {
                            controller.rect.value = rect;
                            controller.id.value = id;
                            controller.updateOutputSurface(id);
                          },
                        );
                      } else {
                        controller._outputRefreshState.acceptSurface(
                          generation: generation,
                          surfaceId: id,
                          width: rect.width.toInt(),
                          height: rect.height.toInt(),
                          onAccept: () {
                            controller.rect.value = rect;
                            controller.id.value = id;
                            controller.updateOutputSurface(id);
                          },
                        );
                      }
                    }
                    // Windows publishes a correlated callback after libmpv has
                    // rendered into the replacement texture. Other native
                    // platforms retain their legacy resize-based first-frame
                    // behavior until they implement the same native contract.
                    if (!Platform.isWindows &&
                        rect.width > 0 &&
                        rect.height > 0) {
                      controller?._outputRefreshState.acceptFrame(
                        generation: generation,
                      );
                    }
                    break;
                  }
                case 'VideoOutput.FirstFrame':
                  {
                    final int handle = call.arguments['handle'];
                    final int generation =
                        call.arguments['generation'] as int? ?? 0;
                    _controllers[handle]?._outputRefreshState.acceptFrame(
                          generation: generation,
                        );
                    break;
                  }
                default:
                  {
                    break;
                  }
              }
            } catch (exception, stacktrace) {
              debugPrint(exception.toString());
              debugPrint(stacktrace.toString());
            }
          },
        );
}
