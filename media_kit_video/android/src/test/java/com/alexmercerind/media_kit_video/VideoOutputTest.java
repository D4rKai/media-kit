package com.alexmercerind.media_kit_video;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.longThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.view.Surface;

import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.LooperMode;

import java.lang.reflect.Field;

import io.flutter.view.TextureRegistry;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
@LooperMode(LooperMode.Mode.PAUSED)
public class VideoOutputTest {
    private TextureRegistry.SurfaceProducer surfaceProducer;
    private TextureUpdateCallback textureUpdateCallback;
    private VideoOutput videoOutput;

    @Before
    public void setUp() {
        final TextureRegistry textureRegistry = mock(TextureRegistry.class);
        surfaceProducer = mock(TextureRegistry.SurfaceProducer.class);
        textureUpdateCallback = mock(TextureUpdateCallback.class);
        final Surface surface = mock(Surface.class);

        when(textureRegistry.createSurfaceProducer()).thenReturn(surfaceProducer);
        when(surfaceProducer.getSurface()).thenReturn(surface);
        when(surfaceProducer.id()).thenReturn(7L);
        when(surfaceProducer.getWidth()).thenReturn(1920);
        when(surfaceProducer.getHeight()).thenReturn(1080);

        videoOutput = new VideoOutput(textureRegistry, textureUpdateCallback);
    }

    @Test
    public void onSurfaceCleanupClearsStoredWid() throws Exception {
        videoOutput.onSurfaceAvailable();
        assertNotEquals(0L, storedWid(videoOutput));

        videoOutput.onSurfaceCleanup();

        assertEquals(0L, storedWid(videoOutput));
    }

    @Test
    public void sameSizeRequestReattachesWhenSurfaceIsDetached() {
        videoOutput.onSurfaceAvailable();
        videoOutput.onSurfaceCleanup();
        reset(textureUpdateCallback);

        videoOutput.setSurfaceSize(1920, 1080);

        verify(surfaceProducer).setSize(1920, 1080);
        verify(textureUpdateCallback).onTextureUpdate(
                eq(7L), longThat(wid -> wid != 0L), eq(1920), eq(1080));
    }

    private static long storedWid(VideoOutput output) throws Exception {
        final Field field = VideoOutput.class.getDeclaredField("wid");
        field.setAccessible(true);
        return field.getLong(output);
    }
}
