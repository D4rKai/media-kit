// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output.h"

#include <algorithm>
#include <condition_variable>
#include <vector>

// Limit the frame size to 1080p in software rendering.
// This is for performance reasons & to avoid allocating too much memory.
#define SW_RENDERING_MAX_WIDTH 1920
#define SW_RENDERING_MAX_HEIGHT 1080
#define SW_RENDERING_PIXEL_BUFFER_SIZE \
  (SW_RENDERING_MAX_WIDTH) * (SW_RENDERING_MAX_HEIGHT) * (4)

struct TextureBackingState {
  std::mutex mutex;
  bool active = true;
  ANGLESurfaceManager* surface_manager = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> retained_gpu_texture;
  std::shared_ptr<uint8_t[]> pixel_buffer_owner;
  std::unique_ptr<FlutterDesktopGpuSurfaceDescriptor> gpu_descriptor;
  std::unique_ptr<FlutterDesktopPixelBuffer> pixel_descriptor;
  std::unique_ptr<flutter::TextureVariant> texture_variant;

  FlutterDesktopGpuSurfaceDescriptor* GetGpuDescriptor() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || surface_manager == nullptr || gpu_descriptor == nullptr) {
      return nullptr;
    }
    surface_manager->Read();
    return gpu_descriptor.get();
  }

  FlutterDesktopPixelBuffer* GetPixelDescriptor() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || pixel_descriptor == nullptr) {
      return nullptr;
    }
    return pixel_descriptor.get();
  }

  void Deactivate() {
    std::lock_guard<std::mutex> lock(mutex);
    active = false;
    surface_manager = nullptr;
  }
};

struct VideoOutputUpdateCallbackState {
  std::mutex mutex;
  std::condition_variable condition;
  VideoOutput* owner = nullptr;
  size_t in_flight_callbacks = 0;

  static void Callback(void* context) noexcept {
    auto state = reinterpret_cast<VideoOutputUpdateCallbackState*>(context);
    if (state == nullptr) return;
    VideoOutput* owner = nullptr;
    try {
      std::lock_guard<std::mutex> lock(state->mutex);
      ++state->in_flight_callbacks;
      owner = state->owner;
    } catch (...) {
      return;
    }

    struct InFlightCallbackGuard {
      VideoOutputUpdateCallbackState* state;

      ~InFlightCallbackGuard() noexcept {
        try {
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->in_flight_callbacks > 0) {
              --state->in_flight_callbacks;
            }
          }
          state->condition.notify_all();
        } catch (...) {
          // A C callback must never unwind through libmpv.
        }
      }
    } in_flight{state};

    try {
      if (owner != nullptr) {
        owner->NotifyRender();
      }
    } catch (...) {
      // NotifyRender may fail to acquire or enqueue during teardown. The guard
      // still retires this callback and no exception crosses the C ABI.
    }
  }

  void Retire(VideoOutput* expected_owner) {
    std::lock_guard<std::mutex> lock(mutex);
    if (owner == expected_owner) {
      owner = nullptr;
    }
  }

  void WaitForUpdateCallbacks() {
    std::unique_lock<std::mutex> lock(mutex);
    condition.wait(lock, [this]() { return in_flight_callbacks == 0; });
  }
};

namespace {

VideoOutputUpdateCallbackState* CreateUpdateCallbackState(VideoOutput* owner) {
  // libmpv does not document set_update_callback(NULL) as joining a callback
  // that was dispatched but has not entered its first instruction. Retaining
  // these tiny trampolines for process lifetime makes such a late callback
  // safe: it observes owner == nullptr and never dereferences VideoOutput.
  static auto* states =
      new std::vector<std::unique_ptr<VideoOutputUpdateCallbackState>>();
  static auto* states_mutex = new std::mutex();
  auto state = std::make_unique<VideoOutputUpdateCallbackState>();
  state->owner = owner;
  auto result = state.get();
  std::lock_guard<std::mutex> lock(*states_mutex);
  states->push_back(std::move(state));
  return result;
}

}  // namespace

VideoOutput::VideoOutput(int64_t handle,
                         VideoOutputConfiguration configuration,
                         flutter::PluginRegistrarWindows* registrar,
                         ThreadPool* thread_pool_ref,
                         std::function<void()> first_frame_callback)
    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),
      registrar_(registrar),
      thread_pool_ref_(thread_pool_ref),
      first_frame_callback_(std::move(first_frame_callback)) {
  update_callback_state_ = CreateUpdateCallbackState(this);
  // The constructor must be invoked through the thread pool, because
  // |ANGLESurfaceManager| & libmpv render context creation can conflict with
  // the existing |Render| or |Resize| calls from another |VideoOutput|
  // instances (which will result in access violation).
  auto future = thread_pool_ref_->Post([&]() {
    mpv_set_option_string(handle_, "video-sync", "audio");
    mpv_set_option_string(handle_, "video-timing-offset", "0");
    // First try to initialize video playback with hardware acceleration &
    // |ANGLESurfaceManager|, use S/W API as fallback.
    auto is_hardware_acceleration_enabled = false;
    // Attempt to use H/W rendering.
    if (configuration.enable_hardware_acceleration) {
      try {
        // OpenGL context needs to be set before |mpv_render_context_create|.
        const auto initial_width = std::max<int64_t>(1, width_.value_or(1));
        const auto initial_height = std::max<int64_t>(1, height_.value_or(1));
        surface_manager_ = std::make_unique<ANGLESurfaceManager>(
            static_cast<int32_t>(initial_width),
            static_cast<int32_t>(initial_height));
        surface_manager_->MakeCurrent(true);
        Resize(initial_width, initial_height);
        mpv_opengl_init_params gl_init_params{
            [](auto, auto name) {
              return reinterpret_cast<void*>(eglGetProcAddress(name));
            },
            nullptr,
        };
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        // Create render context.
        if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
          mpv_render_context_set_update_callback(
              render_context_, VideoOutputUpdateCallbackState::Callback,
              update_callback_state_);
          // Set flag to true, indicating that H/W rendering is supported.
          is_hardware_acceleration_enabled = true;
          std::cout << "media_kit: VideoOutput: Using H/W rendering."
                    << std::endl;
        }
      } catch (...) {
        // Do nothing.
        // Likely received an |std::runtime_error| from |ANGLESurfaceManager|,
        // which indicates that H/W rendering is not supported.
      }
    }
    if (!is_hardware_acceleration_enabled) {
      // This constructor body already runs on the ordered render worker.
      // A failed OpenGL context creation can still leave ANGLE and its
      // bootstrap Flutter texture alive; retire both before selecting SW.
      ResetHardwareOutputForSoftwareFallback();
      std::cout << "media_kit: VideoOutput: Using S/W rendering." << std::endl;
      // Allocate a "large enough" buffer ahead of time.
      pixel_buffer_ = std::shared_ptr<uint8_t[]>(
          new uint8_t[SW_RENDERING_PIXEL_BUFFER_SIZE],
          std::default_delete<uint8_t[]>());
      const auto initial_size =
          NormalizeOutputSize(width_.value_or(1), height_.value_or(1));
      Resize(initial_size.first, initial_size.second);
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
        mpv_render_context_set_update_callback(
            render_context_, VideoOutputUpdateCallbackState::Callback,
            update_callback_state_);
      }
    }
  });
  future.wait();
}

VideoOutput::~VideoOutput() {
  {
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    destroyed_.store(true);
  }
  update_callback_state_->Retire(this);

  // Detach on the same ordered worker used by every render-context operation.
  // The lifecycle mutex guarantees that an update callback either queued its
  // work before this barrier or observed destroyed_ and queued nothing.
  auto detach_callback = thread_pool_ref_->Post([this]() {
    if (render_context_ != nullptr) {
      mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
    }
  });
  detach_callback.wait();
  update_callback_state_->WaitForUpdateCallbacks();

  auto unregister_current = thread_pool_ref_->Post([this]() {
    const auto texture_id = texture_id_;
    texture_id_ = 0;
    if (texture_id) {
      UnregisterTexture(texture_id);
    }
  });
  unregister_current.wait();

  auto release_context = thread_pool_ref_->Post([this]() {
    texture_backings_.clear();
    if (render_context_ != nullptr) {
      if (surface_manager_ != nullptr) {
        surface_manager_->MakeCurrent(true);
      }
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
      if (surface_manager_ != nullptr) {
        surface_manager_->MakeCurrent(false);
      }
    }
    surface_manager_.reset(nullptr);
    pixel_buffer_.reset();
  });
  release_context.wait();
}

void VideoOutput::NotifyRender() {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (destroyed_.load()) {
    return;
  }
  try {
    thread_pool_ref_->Post([this]() {
      if (destroyed_.load()) return;
      CheckAndResize();
      Render();
    });
  } catch (...) {
    // Never allow an exception to cross libmpv's C callback boundary.
  }
}

void VideoOutput::Render() {
  if (destroyed_.load() || render_context_ == nullptr) {
    return;
  }
  if (texture_id_) {
    auto rendered = false;
    // H/W
    if (surface_manager_ != nullptr) {
      surface_manager_->Draw([&]() {
        mpv_opengl_fbo fbo{
            0,
            surface_manager_->width(),
            surface_manager_->height(),
            0,
        };
        mpv_render_param params[]{
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        const auto render_result =
            mpv_render_context_render(render_context_, params);
        rendered = render_result == 0;
      });
    }
    // S/W
    if (pixel_buffer_ != nullptr) {
      int32_t size[]{
          static_cast<int32_t>(texture_width_),
          static_cast<int32_t>(texture_height_),
      };
      auto pitch = 4 * size[0];
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_SW_SIZE, size},
          {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
          {MPV_RENDER_PARAM_SW_POINTER, pixel_buffer_.get()},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      const auto render_result =
          mpv_render_context_render(render_context_, params);
      rendered = render_result == 0;
    }
    auto frame_available_notified = false;
    if (rendered) {
      try {
        // Notify Flutter that the successfully rendered frame is available.
        frame_available_notified = registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
      } catch (...) {
        // Prevent any redundant exceptions if the texture is unregistered etc.
      }
    }
    if (rendered && frame_available_notified &&
        qualified_texture_published_ && !first_frame_notified_ &&
        HasValidVideoGeometry() && !destroyed_.load()) {
      first_frame_notified_ = true;
      first_frame_callback_();
    }
  }
}

void VideoOutput::SetTextureUpdateCallback(
    std::function<void(int64_t, int64_t, int64_t)> callback) {
  std::future<void> update_callback;
  {
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    if (destroyed_.load()) return;
    update_callback = thread_pool_ref_->Post([this, callback]() {
      if (destroyed_.load()) return;
      texture_update_callback_ = callback;
      const auto required_size = GetVideoDimensions();
      const auto required_width = required_size.first;
      const auto required_height = required_size.second;
      if (HasValidVideoGeometry() && required_width == width() &&
          required_height == height()) {
        qualified_texture_published_ = true;
        texture_update_callback_(texture_id_, width(), height());
      } else {
        // Publish the valid texture identifier so Flutter mounts it, but
        // withhold qualified geometry until the texture really matches video.
        qualified_texture_published_ = false;
        texture_update_callback_(texture_id_, 0, 0);
      }
    });
  }
  update_callback.wait();
}

void VideoOutput::SetSize(std::optional<int64_t> width,
                          std::optional<int64_t> height) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (destroyed_.load()) return;
  thread_pool_ref_->Post([this, width, height]() {
    if (destroyed_.load()) return;
    width_ = width.has_value() && width.value() > 0 ? width : std::nullopt;
    height_ = height.has_value() && height.value() > 0 ? height : std::nullopt;
  });
}

void VideoOutput::Refresh(
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback,
    std::function<void()> first_frame_callback) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (destroyed_.load()) return;
  thread_pool_ref_->Post(
      [this, configuration, texture_update_callback, first_frame_callback]() {
        if (destroyed_.load()) return;

        configuration_ = configuration;
        if (configuration.width.has_value() &&
            configuration.width.value() > 0) {
          width_ = configuration.width;
        }
        if (configuration.height.has_value() &&
            configuration.height.value() > 0) {
          height_ = configuration.height;
        }

        const auto required_size = GetVideoDimensions();
        auto required_width = required_size.first;
        auto required_height = required_size.second;
        if (required_width < 1) required_width = width();
        if (required_height < 1) required_height = height();
        required_width = std::max<int64_t>(1, required_width);
        required_height = std::max<int64_t>(1, required_height);

        texture_update_callback_ = texture_update_callback;
        first_frame_callback_ = first_frame_callback;
        qualified_texture_published_ = false;
        first_frame_notified_ = false;

        // This generation owns the detachment and the replacement surface.
        texture_update_callback_(0, 0, 0);
        Resize(required_width, required_height, true);

        // A paused VOD may not produce another mpv update callback. Render the
        // retained frame immediately into the replacement Flutter texture.
        Render();
      });
}

void VideoOutput::CheckAndResize() {
  if (destroyed_.load()) return;
  // Check if a new texture with different dimensions is needed.
  const auto required_size = GetVideoDimensions();
  auto required_width = required_size.first;
  auto required_height = required_size.second;
  if (required_width < 1 || required_height < 1) {
    // Invalid.
    return;
  }
  if (pixel_buffer_ != nullptr) {
    const auto normalized =
        NormalizeOutputSize(required_width, required_height);
    required_width = normalized.first;
    required_height = normalized.second;
  }
  const auto current_width = texture_width_;
  const auto current_height = texture_height_;
  // Currently rendered video output dimensions.
  // Either H/W or S/W rendered.
  assert(current_width > 0);
  assert(current_height > 0);
  if (required_width == current_width && required_height == current_height) {
    if (!qualified_texture_published_ && HasValidVideoGeometry()) {
      // A fixed-size texture may already match before mpv publishes physical
      // video geometry. Qualify that existing texture exactly once so an
      // earlier rendered frame can complete the matching Dart generation.
      qualified_texture_published_ = true;
      texture_update_callback_(texture_id_, texture_width_, texture_height_);
    }
    // No creation of new texture required.
    return;
  }
  Resize(required_width, required_height);
}

void VideoOutput::Resize(int64_t required_width,
                         int64_t required_height,
                         bool force_refresh) {
  if (destroyed_.load()) return;
  if (pixel_buffer_ != nullptr) {
    const auto normalized =
        NormalizeOutputSize(required_width, required_height);
    required_width = normalized.first;
    required_height = normalized.second;
  }
  std::cout << required_width << " " << required_height << std::endl;
  qualified_texture_published_ = false;
  // Unregister previously registered texture & delete underlying objects.
  if (texture_id_) {
    UnregisterTexture(texture_id_);
    texture_id_ = 0;
  }
  // H/W
  if (surface_manager_ != nullptr) {
    // Destroy internal ID3D11Texture2D & EGLSurface & create new with updated
    // dimensions while preserving previous EGLDisplay & EGLContext.
    const auto same_size =
        surface_manager_->width() == required_width &&
        surface_manager_->height() == required_height;
    if (force_refresh && same_size) {
      surface_manager_->Refresh();
    } else {
      surface_manager_->SetSize(static_cast<int32_t>(required_width),
                                static_cast<int32_t>(required_height));
    }
    auto backing = std::make_shared<TextureBackingState>();
    backing->surface_manager = surface_manager_.get();
    backing->retained_gpu_texture = surface_manager_->RetainFlutterTexture();
    backing->gpu_descriptor =
        std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    backing->gpu_descriptor->struct_size =
        sizeof(FlutterDesktopGpuSurfaceDescriptor);
    backing->gpu_descriptor->handle = surface_manager_->handle();
    backing->gpu_descriptor->width = backing->gpu_descriptor->visible_width =
        surface_manager_->width();
    backing->gpu_descriptor->height = backing->gpu_descriptor->visible_height =
        surface_manager_->height();
    backing->gpu_descriptor->release_context = nullptr;
    backing->gpu_descriptor->release_callback = [](void*) {};
    backing->gpu_descriptor->format = kFlutterDesktopPixelFormatBGRA8888;
    std::weak_ptr<TextureBackingState> weak_backing = backing;
    backing->texture_variant =
        std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [weak_backing](auto, auto) {
              const auto backing = weak_backing.lock();
              return backing != nullptr ? backing->GetGpuDescriptor()
                                        : nullptr;
            }));
    // Register new texture.
    texture_id_ = registrar_->texture_registrar()->RegisterTexture(
        backing->texture_variant.get());
    texture_width_ = surface_manager_->width();
    texture_height_ = surface_manager_->height();
    texture_backings_[texture_id_] = std::move(backing);
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    // Notify public texture update callback.
    if (HasValidVideoGeometry()) {
      qualified_texture_published_ = true;
      texture_update_callback_(texture_id_, texture_width_, texture_height_);
    } else {
      texture_update_callback_(texture_id_, 0, 0);
    }
  }
  // S/W
  if (pixel_buffer_ != nullptr) {
    auto backing = std::make_shared<TextureBackingState>();
    backing->pixel_buffer_owner = pixel_buffer_;
    backing->pixel_descriptor =
        std::make_unique<FlutterDesktopPixelBuffer>();
    backing->pixel_descriptor->buffer = pixel_buffer_.get();
    backing->pixel_descriptor->width = required_width;
    backing->pixel_descriptor->height = required_height;
    backing->pixel_descriptor->release_context = nullptr;
    backing->pixel_descriptor->release_callback = [](void*) {};
    std::weak_ptr<TextureBackingState> weak_backing = backing;
    backing->texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([weak_backing](auto, auto) {
          const auto backing = weak_backing.lock();
          return backing != nullptr ? backing->GetPixelDescriptor() : nullptr;
        }));
    // Register new texture.
    texture_id_ = registrar_->texture_registrar()->RegisterTexture(
        backing->texture_variant.get());
    texture_width_ = required_width;
    texture_height_ = required_height;
    texture_backings_[texture_id_] = std::move(backing);
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    // Notify public texture update callback.
    if (HasValidVideoGeometry()) {
      qualified_texture_published_ = true;
      texture_update_callback_(texture_id_, texture_width_, texture_height_);
    } else {
      texture_update_callback_(texture_id_, 0, 0);
    }
  }
}

void VideoOutput::ResetHardwareOutputForSoftwareFallback() {
  if (surface_manager_ != nullptr) {
    surface_manager_->MakeCurrent(false);
  }
  if (texture_id_) {
    UnregisterTexture(texture_id_);
    texture_id_ = 0;
  }
  qualified_texture_published_ = false;
  surface_manager_.reset();
}

void VideoOutput::UnregisterTexture(int64_t texture_id) {
  if (!texture_id) return;
  const auto found = texture_backings_.find(texture_id);
  if (found == texture_backings_.end()) return;
  auto backing = std::move(found->second);
  texture_backings_.erase(found);
  backing->Deactivate();
  registrar_->texture_registrar()->UnregisterTexture(
      texture_id, [backing = std::move(backing)]() { (void)backing; });
}

bool VideoOutput::HasValidVideoGeometry() {
  const auto dimensions = GetPhysicalVideoDimensions();
  return dimensions.first > 0 && dimensions.second > 0;
}

std::pair<int64_t, int64_t> VideoOutput::GetPhysicalVideoDimensions() {
  mpv_node params{};
  if (mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params) <
      0) {
    return {0, 0};
  }

  int64_t display_width = 0;
  int64_t display_height = 0;
  int64_t rotation = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      const auto key = params.u.list->keys[i];
      const auto value = params.u.list->values[i];
      if (value.format != MPV_FORMAT_INT64) continue;
      if (strcmp(key, "dw") == 0) display_width = value.u.int64;
      if (strcmp(key, "dh") == 0) display_height = value.u.int64;
      if (strcmp(key, "rotate") == 0) rotation = value.u.int64;
    }
  }
  mpv_free_node_contents(&params);
  if (rotation == 90 || rotation == 270) {
    return {display_height, display_width};
  }
  return {display_width, display_height};
}

std::pair<int64_t, int64_t> VideoOutput::GetVideoDimensions() {
  const auto physical = GetPhysicalVideoDimensions();
  return NormalizeOutputSize(width_.value_or(physical.first),
                             height_.value_or(physical.second));
}

std::pair<int64_t, int64_t> VideoOutput::NormalizeOutputSize(
    int64_t output_width,
    int64_t output_height) {
  if (output_width < 1 || output_height < 1 || pixel_buffer_ == nullptr) {
    return {output_width, output_height};
  }
  const auto width_scale =
      static_cast<long double>(SW_RENDERING_MAX_WIDTH) / output_width;
  const auto height_scale =
      static_cast<long double>(SW_RENDERING_MAX_HEIGHT) / output_height;
  const auto scale =
      (std::min)({static_cast<long double>(1), width_scale, height_scale});
  return {
      std::max<int64_t>(
          1, static_cast<int64_t>(static_cast<long double>(output_width) *
                                  scale)),
      std::max<int64_t>(
          1, static_cast<int64_t>(static_cast<long double>(output_height) *
                                  scale)),
  };
}
