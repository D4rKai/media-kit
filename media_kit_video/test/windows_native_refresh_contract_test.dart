import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows refresh manager is ordered and never composes detached threads',
      () {
    final source = File('windows/video_output_manager.cc').readAsStringSync();

    expect(source, contains('VideoOutputManager::Refresh'));
    expect(source, contains('operation_thread_pool_->Post'));
    expect(source, isNot(contains('std::thread')));
  });

  test('refresh preserves the libmpv render context and refreshes in place',
      () {
    final manager = File('windows/video_output_manager.cc').readAsStringSync();
    final output = File('windows/video_output.cc').readAsStringSync();

    final managerRefresh =
        _functionBody(manager, 'void VideoOutputManager::Refresh(');
    final outputRefresh = _functionBody(output, 'void VideoOutput::Refresh(');
    expect(managerRefresh, contains('existing->second->Refresh('));
    expect(managerRefresh, isNot(contains('video_outputs_.erase')));
    expect(managerRefresh, isNot(contains('make_unique<VideoOutput>')));
    expect(outputRefresh, isNot(contains('mpv_render_context_free')));
    expect(outputRefresh, isNot(contains('mpv_render_context_create')));
    expect(outputRefresh, contains('Resize('));
    expect(outputRefresh, contains('Render();'));
  });

  test('same-size refresh forces replacement of ANGLE and Flutter textures',
      () {
    final output = File('windows/video_output.cc').readAsStringSync();
    final angle = File('windows/angle_surface_manager.cc').readAsStringSync();

    expect(output, contains('Resize(required_width, required_height, true)'));
    expect(angle, contains('void ANGLESurfaceManager::Refresh()'));
    expect(angle, contains('Create();'));
    final angleRefresh =
        _functionBody(angle, 'void ANGLESurfaceManager::Refresh()');
    expect(angleRefresh, contains('WaitForSingleObject(mutex_, INFINITE)'));
  });

  test(
    'fixed-size bootstrap is qualified once when physical geometry appears',
    () {
      final header = File('windows/video_output.h').readAsStringSync();
      final source = File('windows/video_output.cc').readAsStringSync();
      final setCallback =
          _functionBody(source, 'void VideoOutput::SetTextureUpdateCallback(');
      final checkAndResize =
          _functionBody(source, 'void VideoOutput::CheckAndResize()');

      expect(header, contains('bool qualified_texture_published_ = false;'));
      expect(
        setCallback,
        contains('qualified_texture_published_ = false;'),
      );
      expect(checkAndResize, contains('HasValidVideoGeometry()'));
      expect(
        checkAndResize,
        contains('!qualified_texture_published_'),
      );
      expect(
        checkAndResize,
        contains(
          'texture_update_callback_(texture_id_, texture_width_, '
          'texture_height_)',
        ),
      );
      expect(
        checkAndResize,
        contains('qualified_texture_published_ = true;'),
      );
    },
  );

  test('initial texture callback mutation is ordered on the render worker', () {
    final source = File('windows/video_output.cc').readAsStringSync();
    final setCallback =
        _functionBody(source, 'void VideoOutput::SetTextureUpdateCallback(');

    expect(setCallback, contains('thread_pool_ref_->Post'));
    expect(setCallback, contains('update_callback.wait();'));
    expect(
      setCallback.indexOf('thread_pool_ref_->Post'),
      lessThan(setCallback.indexOf('texture_update_callback_ = callback;')),
    );
  });

  test(
    'software fallback retires failed GPU output before allocating its buffer',
    () {
      final header = File('windows/video_output.h').readAsStringSync();
      final source = File('windows/video_output.cc').readAsStringSync();
      final constructor = _functionBody(source, 'VideoOutput::VideoOutput(');

      expect(
        header,
        contains('void ResetHardwareOutputForSoftwareFallback();'),
      );
      expect(
        constructor,
        contains('ResetHardwareOutputForSoftwareFallback();'),
      );
      expect(
        constructor.indexOf('ResetHardwareOutputForSoftwareFallback();'),
        lessThan(constructor.indexOf('pixel_buffer_ =')),
      );

      final reset = _functionBody(
        source,
        'void VideoOutput::ResetHardwareOutputForSoftwareFallback()',
      );
      expect(reset, contains('surface_manager_->MakeCurrent(false);'));
      expect(reset, contains('UnregisterTexture(texture_id_);'));
      expect(reset, contains('texture_id_ = 0;'));
      expect(reset, contains('surface_manager_.reset();'));
    },
  );

  test('software refresh clamps 4K geometry before buffer rendering', () {
    final source = File('windows/video_output.cc').readAsStringSync();

    expect(source, contains('NormalizeOutputSize'));
    expect(
      source,
      contains(
        'static_cast<long double>(SW_RENDERING_MAX_WIDTH) / output_width',
      ),
    );
    expect(
      source,
      contains(
        'static_cast<long double>(SW_RENDERING_MAX_HEIGHT) / output_height',
      ),
    );
  });

  test('VideoOutput teardown detaches callbacks and waits for context release',
      () {
    final header = File('windows/video_output.h').readAsStringSync();
    final source = File('windows/video_output.cc').readAsStringSync();

    expect(header, contains('std::atomic<bool> destroyed_'));
    expect(header, contains('std::mutex lifecycle_mutex_'));
    expect(header, contains('VideoOutputUpdateCallbackState'));
    expect(source, contains('in_flight_callbacks'));
    expect(source, contains('owner = nullptr'));
    expect(source, contains('WaitForUpdateCallbacks'));
    expect(
      source,
      contains(
        'mpv_render_context_set_update_callback(render_context_, nullptr, '
        'nullptr)',
      ),
    );
    expect(source, contains('mpv_render_context_free(render_context_)'));
    final teardown = _functionBody(source, 'VideoOutput::~VideoOutput()');
    expect(teardown, contains('lifecycle_mutex_'));
    expect(teardown, contains('thread_pool_ref_->Post'));
    expect(
      teardown.indexOf('mpv_render_context_set_update_callback'),
      lessThan(teardown.indexOf('mpv_render_context_free')),
    );
    expect(teardown, contains('auto release_context = thread_pool_ref_->Post'));
    expect(teardown, contains('release_context.wait();'));
  });

  test(
      'libmpv update trampoline is noexcept and retires in-flight work by RAII',
      () {
    final source = File('windows/video_output.cc').readAsStringSync();
    final callback = _functionBody(
      source,
      'static void Callback(void* context)',
    );

    expect(source, contains('static void Callback(void* context) noexcept'));
    expect(callback, contains('struct InFlightCallbackGuard'));
    expect(callback, contains('~InFlightCallbackGuard() noexcept'));
    expect(callback, contains('catch (...)'));
    expect(
      callback,
      matches(
        RegExp(
          r'try \{[\s\S]{0,160}owner->NotifyRender\(\);'
          r'[\s\S]{0,160}catch \(\.\.\.\)',
        ),
      ),
    );
  });

  test('retired Flutter textures own backing state without raw-this callbacks',
      () {
    final header = File('windows/video_output.h').readAsStringSync();
    final source = File('windows/video_output.cc').readAsStringSync();

    expect(header, contains('std::shared_ptr<TextureBackingState>'));
    expect(source, contains('RetainFlutterTexture()'));
    expect(
      source,
      matches(
        RegExp(
          r'UnregisterTexture\([\s\S]{0,160}'
          r'\[backing = std::move\(backing\)\]',
        ),
      ),
    );
    final unregister =
        _functionBody(source, 'void VideoOutput::UnregisterTexture(');
    expect(unregister, isNot(contains('[this')));
    expect(unregister, isNot(contains('[&')));
  });

  test('plugin rejects callbacks then quiesces manager before queue teardown',
      () {
    final header = File('windows/media_kit_video_plugin.h').readAsStringSync();
    final source = File('windows/media_kit_video_plugin.cc').readAsStringSync();

    expect(header, contains('bool shutting_down_'));
    expect(source, contains('shutting_down_ = true;'));
    expect(source, contains('video_output_manager_.reset();'));
    expect(source, contains('main_thread_tasks_.pop();'));
    expect(
      source.indexOf('video_output_manager_.reset();'),
      lessThan(source.indexOf('main_thread_tasks_.pop();')),
    );
  });

  test('first-frame signal requires a successful Flutter frame notification',
      () {
    final source = File('windows/video_output.cc').readAsStringSync();

    expect(source, contains('render_result == 0'));
    expect(source, contains('HasValidVideoGeometry()'));
    expect(
      source,
      contains(
        'frame_available_notified = registrar_->texture_registrar()'
        '->MarkTextureFrameAvailable(texture_id_);',
      ),
    );
    expect(
      source,
      matches(
        RegExp(
          r'if \(rendered && frame_available_notified &&'
          r'[\s\S]{0,240}first_frame_callback_\(\)',
        ),
      ),
    );
  });
}

String _functionBody(String source, String signature) {
  final signatureIndex = source.indexOf(signature);
  expect(signatureIndex, greaterThanOrEqualTo(0), reason: signature);
  final openingBrace = source.indexOf('{', signatureIndex);
  expect(openingBrace, greaterThan(signatureIndex), reason: signature);
  var depth = 0;
  for (var index = openingBrace; index < source.length; index++) {
    switch (source[index]) {
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) {
          return source.substring(openingBrace + 1, index);
        }
    }
  }
  fail('Unterminated function body: $signature');
}
