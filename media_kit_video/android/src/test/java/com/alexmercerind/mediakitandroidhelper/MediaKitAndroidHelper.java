package com.alexmercerind.mediakitandroidhelper;

public final class MediaKitAndroidHelper {
    private static long nextReference = 100;

    private MediaKitAndroidHelper() {
    }

    public static long newGlobalObjectRef(Object object) {
        return nextReference++;
    }

    public static void deleteGlobalObjectRef(long reference) {
    }
}
