package com.alexmercerind.mediakit

import org.junit.After
import org.junit.Before
import org.junit.Test

import java.nio.charset.StandardCharsets
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

import org.gradle.testfixtures.ProjectBuilder

import static org.junit.Assert.assertArrayEquals
import static org.junit.Assert.assertEquals
import static org.junit.Assert.assertFalse
import static org.junit.Assert.assertThrows
import static org.junit.Assert.assertTrue

class VerifiedAssetDownloaderTest {
    private static final byte[] VERIFIED_BYTES =
        'verified-native-jar'.getBytes(StandardCharsets.UTF_8)
    private static final byte[] WRONG_SAME_SIZE_BYTES =
        '1234567890123456789'.getBytes(StandardCharsets.UTF_8)
    private static final String VERIFIED_SHA256 =
        'a853515bb674e0eeea975b96c0f4e3b798e9d2c3a3db5c011177cb02dfe31657'
    private static final String FILE_NAME = 'default-arm64-v8a.jar'

    private Path fixtureRoot

    @Before
    void setUp() {
        fixtureRoot = Files.createTempDirectory('verified-assets-test-')
    }

    @After
    void tearDown() {
        if (fixtureRoot != null && Files.exists(fixtureRoot)) {
            Files.walk(fixtureRoot)
                .sorted(Comparator.reverseOrder())
                .forEach { Files.deleteIfExists(it) }
        }
    }

    @Test
    void rejectsWrongSha256BeforePublishingDestination() {
        def downloader = downloader(sourceWriting(WRONG_SAME_SIZE_BYTES))

        assertThrows(IllegalStateException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
        assertNoPartials()
    }

    @Test
    void rejectsTruncatedInputBeforePublishingDestination() {
        def downloader = downloader(sourceWriting('short'.bytes))

        assertThrows(IllegalStateException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
        assertNoPartials()
    }

    @Test
    void rejectsOversizeInputBeforePublishingDestination() {
        def rejectedAtFirstExcessByte = new AtomicBoolean()
        def source = { URI ignored, OutputStream output, long expectedSize,
                       int ignoredConnect, int ignoredRead,
                       int ignoredRedirects ->
            assertEquals(VERIFIED_BYTES.length, expectedSize)
            output.write(VERIFIED_BYTES)
            try {
                output.write(0x7f)
            } catch (IllegalStateException error) {
                rejectedAtFirstExcessByte.set(true)
                throw error
            }
        } as VerifiedAssetDownloader.ByteSource
        def downloader = downloader(source)

        assertThrows(IllegalStateException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertTrue(rejectedAtFirstExcessByte.get())
        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
        assertNoPartials()
    }

    @Test
    void appliesBoundedConnectTimeoutAndCleansPartialInput() {
        def source = { URI ignored, OutputStream output, long ignoredSize,
                       int connectTimeoutMillis, int readTimeoutMillis,
                       int ignoredRedirects ->
            assertEquals(4_321, connectTimeoutMillis)
            assertEquals(8_765, readTimeoutMillis)
            output.write('partial'.bytes)
            throw new SocketTimeoutException('connect timed out')
        } as VerifiedAssetDownloader.ByteSource
        def downloader = new VerifiedAssetDownloader(
            source,
            VerifiedAssetDownloader.atomicPlacer(),
            4_321,
            8_765,
            3,
        )

        assertThrows(SocketTimeoutException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertNoPartials()
        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
    }

    @Test
    void appliesBoundedReadTimeoutAndCleansPartialInput() {
        def source = { URI ignored, OutputStream output, long ignoredSize,
                       int connectTimeoutMillis, int readTimeoutMillis,
                       int ignoredRedirects ->
            assertEquals(4_321, connectTimeoutMillis)
            assertEquals(8_765, readTimeoutMillis)
            output.write('partial'.bytes)
            throw new SocketTimeoutException('read timed out')
        } as VerifiedAssetDownloader.ByteSource
        def downloader = new VerifiedAssetDownloader(
            source,
            VerifiedAssetDownloader.atomicPlacer(),
            4_321,
            8_765,
            3,
        )

        assertThrows(SocketTimeoutException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertNoPartials()
        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
    }

    @Test
    void rejectsHttpsToHttpRedirectDowngrade() {
        def factory = { URI uri, int connectTimeoutMillis,
                        int readTimeoutMillis ->
            assertEquals('https', uri.scheme)
            assertTrue(connectTimeoutMillis > 0)
            assertTrue(readTimeoutMillis > 0)
            new VerifiedAssetDownloader.NetworkResponse(
                302,
                'http://example.invalid/unverified.jar',
                new ByteArrayInputStream(new byte[0]),
                {},
            )
        } as VerifiedAssetDownloader.ConnectionFactory
        def source = new VerifiedAssetDownloader.HttpsByteSource(factory)
        def downloader = downloader(source)

        assertThrows(SecurityException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertNoPartials()
        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
    }

    @Test
    void rejectsNonHttpsInitialAssetUrl() {
        def downloader = downloader(sourceWriting(VERIFIED_BYTES))
        def insecure = asset(
            FILE_NAME,
            'http://example.invalid/unverified.jar',
        )

        assertThrows(SecurityException) {
            downloader.ensureAssets(fixtureRoot, [insecure])
        }

        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
    }

    @Test
    void followsOnlyBoundedHttpsRedirectHops() {
        def opened = Collections.synchronizedList([])
        def factory = { URI uri, int ignoredConnect, int ignoredRead ->
            opened.add(uri.toString())
            if (opened.size() == 1) {
                return new VerifiedAssetDownloader.NetworkResponse(
                    302,
                    '/release/intermediate.jar',
                    new ByteArrayInputStream(new byte[0]),
                    {},
                )
            }
            if (opened.size() == 2) {
                return new VerifiedAssetDownloader.NetworkResponse(
                    307,
                    'https://downloads.example.invalid/final.jar',
                    new ByteArrayInputStream(new byte[0]),
                    {},
                )
            }
            new VerifiedAssetDownloader.NetworkResponse(
                200,
                null,
                new ByteArrayInputStream(VERIFIED_BYTES),
                {},
            )
        } as VerifiedAssetDownloader.ConnectionFactory
        def source = new VerifiedAssetDownloader.HttpsByteSource(factory)
        def downloader = new VerifiedAssetDownloader(
            source,
            VerifiedAssetDownloader.atomicPlacer(),
            5_000,
            10_000,
            2,
        )

        downloader.ensureAssets(fixtureRoot, [asset()])

        assertEquals(
            [
                'https://github.com/media-kit/libmpv-android-video-build/' +
                    'releases/download/v1.1.7/default-arm64-v8a.jar',
                'https://github.com/release/intermediate.jar',
                'https://downloads.example.invalid/final.jar',
            ],
            opened,
        )
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
    }

    @Test
    void rejectsRedirectChainsBeyondConfiguredMaximum() {
        def factory = { URI ignored, int ignoredConnect, int ignoredRead ->
            new VerifiedAssetDownloader.NetworkResponse(
                302,
                'https://downloads.example.invalid/next.jar',
                new ByteArrayInputStream(new byte[0]),
                {},
            )
        } as VerifiedAssetDownloader.ConnectionFactory
        def downloader = new VerifiedAssetDownloader(
            new VerifiedAssetDownloader.HttpsByteSource(factory),
            VerifiedAssetDownloader.atomicPlacer(),
            5_000,
            10_000,
            1,
        )

        assertThrows(IllegalStateException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertNoPartials()
    }

    @Test
    void rejectsNonSuccessHttpStatusAndInvalidRedirectLocations() {
        [
            [404, null],
            [302, null],
        ].each { responseFixture ->
            def factory = { URI ignored, int ignoredConnect, int ignoredRead ->
                new VerifiedAssetDownloader.NetworkResponse(
                    responseFixture[0] as int,
                    responseFixture[1] as String,
                    new ByteArrayInputStream(new byte[0]),
                    {},
                )
            } as VerifiedAssetDownloader.ConnectionFactory
            def downloader = downloader(
                new VerifiedAssetDownloader.HttpsByteSource(factory),
            )

            assertThrows(IllegalStateException) {
                downloader.ensureAssets(fixtureRoot, [asset()])
            }
            assertNoPartials()
        }

        def invalidFactory = {
            URI ignored, int ignoredConnect, int ignoredRead ->
                new VerifiedAssetDownloader.NetworkResponse(
                    302,
                    'https://exa mple.invalid/bad.jar',
                    new ByteArrayInputStream(new byte[0]),
                    {},
                )
        } as VerifiedAssetDownloader.ConnectionFactory
        def invalidDownloader = downloader(
            new VerifiedAssetDownloader.HttpsByteSource(invalidFactory),
        )
        assertThrows(IllegalArgumentException) {
            invalidDownloader.ensureAssets(fixtureRoot, [asset()])
        }
        assertNoPartials()
    }

    @Test
    void rejectsUnsafeOrDuplicateAssetManifestEntries() {
        def downloader = downloader(sourceWriting(VERIFIED_BYTES))
        def unsafeNames = [
            '../escape.jar',
            'nested/default.jar',
            '/absolute.jar',
            "nul\u0000name.jar",
            'not-a-jar.bin',
        ]

        unsafeNames.each { fileName ->
            assertThrows(IllegalArgumentException) {
                downloader.ensureAssets(
                    fixtureRoot,
                    [asset(fileName, 'https://example.invalid/default.jar')],
                )
            }
        }

        assertThrows(IllegalArgumentException) {
            downloader.ensureAssets(
                fixtureRoot,
                [
                    asset(FILE_NAME, 'https://example.invalid/one.jar'),
                    asset(FILE_NAME, 'https://example.invalid/two.jar'),
                ],
            )
        }
        assertThrows(IllegalArgumentException) {
            downloader.ensureAssets(
                fixtureRoot,
                [
                    asset(FILE_NAME, 'https://example.invalid/same.jar'),
                    asset(
                        'default-x86_64.jar',
                        'https://example.invalid/same.jar',
                    ),
                ],
            )
        }
    }

    @Test
    void replacesPoisonedCachedDestinationWithVerifiedBytes() {
        Files.write(fixtureRoot.resolve(FILE_NAME), WRONG_SAME_SIZE_BYTES)
        def calls = new AtomicInteger()
        def downloader = downloader(countingSource(calls, VERIFIED_BYTES))

        downloader.ensureAssets(fixtureRoot, [asset()])

        assertEquals(1, calls.get())
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
        assertNoPartials()
    }

    @Test
    void removesAbandonedPartialBeforeAcceptingVerifiedBytes() {
        Path abandoned = fixtureRoot.resolve(".${FILE_NAME}.abandoned.part")
        Files.write(abandoned, 'partial'.bytes)
        def downloader = downloader(sourceWriting(VERIFIED_BYTES))

        downloader.ensureAssets(fixtureRoot, [asset()])

        assertFalse(Files.exists(abandoned))
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
        assertNoPartials()
    }

    @Test
    void serializesConcurrentCacheAccessAndDownloadsOnlyOnce() {
        def calls = new AtomicInteger()
        def entered = new CountDownLatch(1)
        def release = new CountDownLatch(1)
        def source = { URI ignored, OutputStream output, long ignoredSize,
                       int ignoredConnect, int ignoredRead,
                       int ignoredRedirects ->
            calls.incrementAndGet()
            entered.countDown()
            assertTrue(release.await(10, TimeUnit.SECONDS))
            output.write(VERIFIED_BYTES)
        } as VerifiedAssetDownloader.ByteSource
        def first = downloader(source)
        def second = downloader(source)
        def executor = Executors.newFixedThreadPool(2)

        try {
            def firstFuture = executor.submit {
                first.ensureAssets(fixtureRoot, [asset()])
            }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            def secondFuture = executor.submit {
                second.ensureAssets(fixtureRoot, [asset()])
            }
            release.countDown()
            firstFuture.get(10, TimeUnit.SECONDS)
            secondFuture.get(10, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }

        assertEquals(1, calls.get())
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
        assertNoPartials()
    }

    @Test
    void waitsForOverlappingProcessLockAndRehashesCacheAfterAcquiringIt() {
        Path lockPath = fixtureRoot.resolve('.verified-assets.lock')
        def calls = new AtomicInteger()
        def downloader = downloader(countingSource(calls, VERIFIED_BYTES))
        def executor = Executors.newSingleThreadExecutor()

        FileChannel channel = FileChannel.open(
            lockPath,
            StandardOpenOption.CREATE,
            StandardOpenOption.WRITE,
        )
        def lock = channel.lock()
        try {
            def future = executor.submit {
                downloader.ensureAssets(fixtureRoot, [asset()])
            }
            Thread.sleep(250)
            assertFalse(
                'Downloader must wait instead of failing on overlapping lock.',
                future.isDone(),
            )
            Files.write(fixtureRoot.resolve(FILE_NAME), VERIFIED_BYTES)
            lock.release()
            channel.close()
            future.get(10, TimeUnit.SECONDS)
        } finally {
            if (lock.valid) {
                lock.release()
            }
            if (channel.open) {
                channel.close()
            }
            executor.shutdownNow()
        }

        assertEquals(0, calls.get())
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
    }

    @Test
    void revalidatesDestinationOnEveryInvocationDespitePriorSuccess() {
        def calls = new AtomicInteger()
        def downloader = downloader(countingSource(calls, VERIFIED_BYTES))

        downloader.ensureAssets(fixtureRoot, [asset()])
        Files.write(fixtureRoot.resolve(FILE_NAME), WRONG_SAME_SIZE_BYTES)
        downloader.ensureAssets(fixtureRoot, [asset()])

        assertEquals(2, calls.get())
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
    }

    @Test
    void rejectsStaleExtraJarWithoutDownloadingAnything() {
        Files.write(fixtureRoot.resolve(FILE_NAME), VERIFIED_BYTES)
        Files.write(fixtureRoot.resolve('stale-unreviewed.jar'), VERIFIED_BYTES)
        def calls = new AtomicInteger()
        def downloader = downloader(countingSource(calls, VERIFIED_BYTES))

        assertThrows(IllegalStateException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertEquals(0, calls.get())
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
    }

    @Test
    void refusesNonAtomicPlacementInsteadOfFallingBack() {
        def nonAtomic = { Path source, Path destination ->
            throw new AtomicMoveNotSupportedException(
                source.toString(),
                destination.toString(),
                'fixture rejects atomic placement',
            )
        } as VerifiedAssetDownloader.AtomicPlacer
        def downloader = new VerifiedAssetDownloader(
            sourceWriting(VERIFIED_BYTES),
            nonAtomic,
            5_000,
            10_000,
            4,
        )

        assertThrows(AtomicMoveNotSupportedException) {
            downloader.ensureAssets(fixtureRoot, [asset()])
        }

        assertFalse(Files.exists(fixtureRoot.resolve(FILE_NAME)))
        assertNoPartials()
    }

    @Test
    void atomicallyPublishesOnlyVerifiedBytes() {
        def durableBeforePlacement = []
        def placements = new AtomicInteger()
        def durabilitySync = {
            FileChannel channel, boolean metadata ->
                assertTrue(channel.open)
                assertTrue(metadata)
                channel.force(metadata)
                durableBeforePlacement.add('fsync')
        } as VerifiedAssetDownloader.DurabilitySync
        def atomic = { Path source, Path destination ->
            placements.incrementAndGet()
            durableBeforePlacement.add('atomic-place')
            Files.move(
                source,
                destination,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING,
            )
        } as VerifiedAssetDownloader.AtomicPlacer
        def downloader = new VerifiedAssetDownloader(
            sourceWriting(VERIFIED_BYTES),
            atomic,
            5_000,
            10_000,
            4,
            durabilitySync,
        )

        downloader.ensureAssets(fixtureRoot, [asset()])

        assertEquals(1, placements.get())
        assertEquals(['fsync', 'atomic-place'], durableBeforePlacement)
        assertArrayEquals(
            VERIFIED_BYTES,
            Files.readAllBytes(fixtureRoot.resolve(FILE_NAME)),
        )
        assertNoPartials()
    }

    @Test
    void usesUniqueSameDirectoryTemporaryFilesForEveryAsset() {
        def temporaryPaths = []
        def atomic = { Path source, Path destination ->
            temporaryPaths.add(source)
            assertEquals(destination.parent, source.parent)
            Files.move(
                source,
                destination,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING,
            )
        } as VerifiedAssetDownloader.AtomicPlacer
        def downloader = new VerifiedAssetDownloader(
            sourceWriting(VERIFIED_BYTES),
            atomic,
            5_000,
            10_000,
            4,
        )

        downloader.ensureAssets(
            fixtureRoot,
            [
                asset(
                    FILE_NAME,
                    'https://example.invalid/default-arm64-v8a.jar',
                ),
                asset(
                    'default-x86_64.jar',
                    'https://example.invalid/default-x86_64.jar',
                ),
            ],
        )

        assertEquals(2, temporaryPaths.size())
        assertEquals(2, temporaryPaths.toSet().size())
        assertTrue(temporaryPaths.every { it.parent == fixtureRoot })
        assertNoPartials()
    }

    @Test
    void verifiedAssetTaskCanNeverBecomeGradleUpToDate() {
        def project = ProjectBuilder.builder()
            .withProjectDir(fixtureRoot.toFile())
            .build()
        def task = project.tasks.create('downloadVerifiedAssets')
        VerifiedAssetDownloader.requireExecution(task)

        assertFalse(task.outputs.upToDateSpec.isSatisfiedBy(task))
    }

    private VerifiedAssetDownloader downloader(
        VerifiedAssetDownloader.ByteSource source
    ) {
        new VerifiedAssetDownloader(
            source,
            VerifiedAssetDownloader.atomicPlacer(),
            5_000,
            10_000,
            4,
        )
    }

    private static VerifiedAssetDownloader.Asset asset() {
        asset(
            FILE_NAME,
            'https://github.com/media-kit/libmpv-android-video-build/' +
                'releases/download/v1.1.7/default-arm64-v8a.jar',
        )
    }

    private static VerifiedAssetDownloader.Asset asset(
        String fileName,
        String uri
    ) {
        new VerifiedAssetDownloader.Asset(
            new URI(uri),
            fileName,
            VERIFIED_BYTES.length,
            VERIFIED_SHA256,
        )
    }

    private static VerifiedAssetDownloader.ByteSource sourceWriting(
        byte[] bytes
    ) {
        { URI ignored, OutputStream output, long ignoredSize,
          int ignoredConnect, int ignoredRead, int ignoredRedirects ->
            output.write(bytes)
        } as VerifiedAssetDownloader.ByteSource
    }

    private static VerifiedAssetDownloader.ByteSource countingSource(
        AtomicInteger calls,
        byte[] bytes
    ) {
        { URI ignored, OutputStream output, long ignoredSize,
          int ignoredConnect, int ignoredRead, int ignoredRedirects ->
            calls.incrementAndGet()
            output.write(bytes)
        } as VerifiedAssetDownloader.ByteSource
    }

    private void assertNoPartials() {
        def partials = []
        Files.list(fixtureRoot).withCloseable { stream ->
            partials.addAll(
                stream.filter {
                    it.fileName.toString().endsWith('.part')
                }.toList(),
            )
        }
        assertTrue("Unexpected partial files: ${partials}", partials.empty)
    }
}
