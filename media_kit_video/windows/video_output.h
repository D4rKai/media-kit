// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_H_
#define VIDEO_OUTPUT_H_

#include <atomic>
#include <functional>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <utility>

#include <client.h>
#include <render.h>
#include <render_gl.h>

#include <future>
#include <memory>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "angle_surface_manager.h"
#include "thread_pool.h"

typedef struct _VideoOutputConfiguration {
  std::optional<int64_t> width;
  std::optional<int64_t> height;
  bool enable_hardware_acceleration;

  _VideoOutputConfiguration(std::optional<int64_t> width = std::nullopt,
                            std::optional<int64_t> height = std::nullopt,
                            bool enable_hardware_acceleration = true)
      : width(width),
        height(height),
        enable_hardware_acceleration(enable_hardware_acceleration) {}
} VideoOutputConfiguration;

struct TextureBackingState;
struct VideoOutputUpdateCallbackState;

class VideoOutput {
 public:
  int64_t texture_id() const { return texture_id_; }
  int64_t width() const {
    return texture_id_ ? texture_width_ : width_.value_or(1);
  }
  int64_t height() const {
    return texture_id_ ? texture_height_ : height_.value_or(1);
  }

  VideoOutput(int64_t handle,
              VideoOutputConfiguration configuration,
              flutter::PluginRegistrarWindows* registrar,
              ThreadPool* thread_pool_ref,
              std::function<void()> first_frame_callback);

  ~VideoOutput();

  void SetTextureUpdateCallback(
      std::function<void(int64_t, int64_t, int64_t)> callback);

  void SetSize(std::optional<int64_t> width, std::optional<int64_t> height);

  // Recreates the native presentation resources without replacing the libmpv
  // render context or media session.
  void Refresh(
      VideoOutputConfiguration configuration,
      std::function<void(int64_t, int64_t, int64_t)> texture_update_callback,
      std::function<void()> first_frame_callback);

 private:
  friend struct VideoOutputUpdateCallbackState;

  void NotifyRender();

  void Render();

  void CheckAndResize();

  void Resize(int64_t required_width,
              int64_t required_height,
              bool force_refresh = false);

  void ResetHardwareOutputForSoftwareFallback();

  void UnregisterTexture(int64_t texture_id);

  bool HasValidVideoGeometry();

  std::pair<int64_t, int64_t> GetPhysicalVideoDimensions();

  std::pair<int64_t, int64_t> GetVideoDimensions();

  std::pair<int64_t, int64_t> NormalizeOutputSize(int64_t width,
                                                  int64_t height);

  std::optional<int64_t> height_ = std::nullopt;
  std::optional<int64_t> width_ = std::nullopt;
  VideoOutputConfiguration configuration_ = VideoOutputConfiguration{};

  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  int64_t texture_id_ = 0;
  int64_t texture_width_ = 1;
  int64_t texture_height_ = 1;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  ThreadPool* thread_pool_ref_ = nullptr;
  // Serializes the mpv update callback's check-and-enqueue operation against
  // teardown. Atomic state also protects work already queued on the renderer.
  std::atomic<bool> destroyed_{false};
  std::mutex lifecycle_mutex_;
  VideoOutputUpdateCallbackState* update_callback_state_ = nullptr;

  // H/W rendering.

  std::unique_ptr<ANGLESurfaceManager> surface_manager_ = nullptr;

  // S/W rendering.

  std::shared_ptr<uint8_t[]> pixel_buffer_ = nullptr;

  // Each registered Flutter texture owns its immutable descriptor and any
  // backing resource it exposes. Retired states outlive VideoOutput through
  // the registrar's unregister callback and never capture raw this.
  std::unordered_map<int64_t, std::shared_ptr<TextureBackingState>>
      texture_backings_ = {};

  // Public notifier. This is called when a new texture is registered & texture
  // ID is changed. Only happens when video output resolution changes.
  std::function<void(int64_t, int64_t, int64_t)> texture_update_callback_ =
      [](int64_t, int64_t, int64_t) {};
  std::function<void()> first_frame_callback_ = []() {};
  bool qualified_texture_published_ = false;
  bool first_frame_notified_ = false;
};

#endif  // VIDEO_OUTPUT_H_
