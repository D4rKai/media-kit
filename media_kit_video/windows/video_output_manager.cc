// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output_manager.h"

VideoOutputManager::VideoOutputManager(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

void VideoOutputManager::Create(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback,
    std::function<void()> first_frame_callback) {
  operation_thread_pool_->Post(
      [this, handle, configuration, texture_update_callback,
       first_frame_callback]() {
        if (video_outputs_.find(handle) == video_outputs_.end()) {
          auto instance = std::make_unique<VideoOutput>(
              handle, configuration, registrar_, thread_pool_.get(),
              first_frame_callback);
          instance->SetTextureUpdateCallback(texture_update_callback);
          video_outputs_.insert(std::make_pair(handle, std::move(instance)));
        }
      });
}

void VideoOutputManager::Refresh(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback,
    std::function<void()> first_frame_callback) {
  operation_thread_pool_->Post(
      [this, handle, configuration, texture_update_callback,
       first_frame_callback]() {
        const auto existing = video_outputs_.find(handle);
        if (existing == video_outputs_.end()) {
          return;
        }
        existing->second->Refresh(configuration, texture_update_callback,
                                  first_frame_callback);
      });
}

void VideoOutputManager::SetSize(int64_t handle,
                                 std::optional<int64_t> width,
                                 std::optional<int64_t> height) {
  operation_thread_pool_->Post([this, handle, width, height]() {
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_[handle]->SetSize(width, height);
    }
  });
}

void VideoOutputManager::Dispose(int64_t handle) {
  operation_thread_pool_->Post([this, handle]() {
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_.erase(handle);
    }
  });
}

VideoOutputManager::~VideoOutputManager() {
  // Drain every ordered manager operation before releasing render resources.
  operation_thread_pool_->Post([this]() { video_outputs_.clear(); }).wait();
}
