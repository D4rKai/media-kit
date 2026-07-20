/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'package:flutter/foundation.dart';

/// Tracks native video output surface attachments.
class VideoOutputSurfaceState {
  /// Whether the platform currently reports an attached output surface.
  final ValueNotifier<bool> attached = ValueNotifier<bool>(false);

  /// Monotonic counter incremented for every non-zero surface attachment.
  final ValueNotifier<int> epoch = ValueNotifier<int>(0);

  /// Updates the state from a native window identifier.
  void update(int wid) {
    final isAttached = wid != 0;
    attached.value = isAttached;
    if (isAttached) {
      epoch.value++;
    }
  }

  /// Releases the state notifiers.
  void dispose() {
    attached.dispose();
    epoch.dispose();
  }
}
