/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.Locale;
import java.util.Objects;

import io.flutter.view.TextureRegistry;

public class VideoOutput implements TextureRegistry.SurfaceProducer.Callback {
    private static final String TAG = "VideoOutput";
    private static final Method newGlobalObjectRef;
    private static final Method deleteGlobalObjectRef;
    private static final HashSet<Long> deletedGlobalObjectRefs = new HashSet<>();
    private static final Handler handler = new Handler(Looper.getMainLooper());

    static {
        try {
            // com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper is part of package:media_kit_libs_android_video & package:media_kit_libs_android_audio packages.
            // Use reflection to invoke methods of com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }
    }

    private long id = 0;
    private long wid = 0;
    private boolean disposed = false;

    private final TextureUpdateCallback textureUpdateCallback;

    private final TextureRegistry.SurfaceProducer surfaceProducer;

    private final Object lock = new Object();

    VideoOutput(TextureRegistry textureRegistryReference, TextureUpdateCallback textureUpdateCallback) {
        this.textureUpdateCallback = textureUpdateCallback;

        surfaceProducer = textureRegistryReference.createSurfaceProducer();
        surfaceProducer.setCallback(this);
    }

    /**
     * The {@link TextureRegistry.SurfaceProducer} owns its surface: release the
     * producer, never the surface it hands out (on ImageReader-backed producers
     * {@code getSurface()} may even create a fresh surface just to release it).
     * mpv is told the surface is gone (wid = 0) before the producer goes, not
     * after, and nothing reads the released producer's size.
     */
    public void dispose() {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            disposed = true;
            detachSurface(true);
            try {
                surfaceProducer.release();
            } catch (Throwable e) {
                Log.e(TAG, "dispose", e);
            }
        }
    }

    public void setSurfaceSize(int width, int height) {
        setSurfaceSize(width, height, false);
    }

    private void setSurfaceSize(int width, int height, boolean force) {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            try {
                if (!force && wid != 0 && surfaceProducer.getWidth() == width && surfaceProducer.getHeight() == height) {
                    return;
                }
                surfaceProducer.setSize(width, height);
                onSurfaceAvailable();
            } catch (Throwable e) {
                Log.e(TAG, "setSurfaceSize", e);
            }
        }
    }

    @Override
    public void onSurfaceAvailable() {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            Log.i(TAG, "onSurfaceAvailable");
            // Each call hands mpv a new global reference; the one it held before
            // (a resize calls this too) is released once mpv has moved on.
            final long previous = wid;
            id = surfaceProducer.id();
            wid = newGlobalObjectRef(surfaceProducer.getSurface());
            textureUpdateCallback.onTextureUpdate(id, wid, surfaceProducer.getWidth(), surfaceProducer.getHeight());
            if (previous != 0 && previous != wid) {
                deleteGlobalObjectRefLater(previous);
            }
        }
    }

    @Override
    public void onSurfaceCleanup() {
        synchronized (lock) {
            if (disposed) {
                return;
            }
            Log.i(TAG, "onSurfaceCleanup");
            detachSurface(false);
        }
    }

    /**
     * Tells mpv its surface is gone (wid = 0) and releases the global reference
     * it held once mpv has moved on. With {@code fromDispose} the producer is about to be
     * released, so its size is not read.
     */
    private void detachSurface(boolean fromDispose) {
        final long widReference = wid;
        wid = 0;
        int width = 0;
        int height = 0;
        if (!fromDispose) {
            try {
                width = surfaceProducer.getWidth();
                height = surfaceProducer.getHeight();
            } catch (Throwable e) {
                Log.e(TAG, "detachSurface", e);
            }
        }
        textureUpdateCallback.onTextureUpdate(id, 0, width, height);
        if (widReference != 0) {
            deleteGlobalObjectRefLater(widReference);
        }
    }

    private static void deleteGlobalObjectRefLater(long ref) {
        handler.postDelayed(() -> deleteGlobalObjectRef(ref), 5000);
    }

    private static long newGlobalObjectRef(Object object) {
        Log.i(TAG, String.format(Locale.ENGLISH, "newGlobalRef: object = %s", object));
        try {
            return (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));
        } catch (Throwable e) {
            Log.e(TAG, "newGlobalRef", e);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long ref) {
        if (deletedGlobalObjectRefs.contains(ref)) {
            Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d ALREADY DELETED", ref));
            return;
        }
        if (deletedGlobalObjectRefs.size() > 100) {
            deletedGlobalObjectRefs.clear();
        }
        deletedGlobalObjectRefs.add(ref);
        Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d", ref));
        try {
            deleteGlobalObjectRef.invoke(null, ref);
        } catch (Throwable e) {
            Log.e(TAG, "deleteGlobalObjectRef", e);
        }
    }
}
