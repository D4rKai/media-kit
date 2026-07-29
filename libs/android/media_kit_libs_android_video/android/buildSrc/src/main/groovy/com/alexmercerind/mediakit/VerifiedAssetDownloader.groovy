package com.alexmercerind.mediakit

import org.gradle.api.Task

import javax.net.ssl.HttpsURLConnection
import java.nio.channels.Channels
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

class VerifiedAssetDownloader {
    private static final int DEFAULT_CONNECT_TIMEOUT_MILLIS = 15_000
    private static final int DEFAULT_READ_TIMEOUT_MILLIS = 30_000
    private static final int DEFAULT_MAX_REDIRECTS = 5
    private static final long LOCK_TIMEOUT_NANOS =
        TimeUnit.MINUTES.toNanos(2)
    private static final ConcurrentHashMap<String, ReentrantLock> JVM_LOCKS =
        new ConcurrentHashMap<>()

    private final ByteSource byteSource
    private final AtomicPlacer atomicPlacer
    private final DurabilitySync durabilitySync
    private final int connectTimeoutMillis
    private final int readTimeoutMillis
    private final int maxRedirects

    static final class Asset {
        final URI uri
        final String fileName
        final long size
        final String sha256

        Asset(URI uri, String fileName, long size, String sha256) {
            this.uri = uri
            this.fileName = fileName
            this.size = size
            this.sha256 = sha256
        }
    }

    @FunctionalInterface
    static interface ByteSource {
        void copy(
            URI uri,
            OutputStream output,
            long expectedSize,
            int connectTimeoutMillis,
            int readTimeoutMillis,
            int maxRedirects
        ) throws IOException
    }

    @FunctionalInterface
    static interface AtomicPlacer {
        void place(Path source, Path destination) throws IOException
    }

    @FunctionalInterface
    static interface DurabilitySync {
        void sync(FileChannel channel, boolean metadata) throws IOException
    }

    @FunctionalInterface
    static interface ConnectionFactory {
        NetworkResponse open(
            URI uri,
            int connectTimeoutMillis,
            int readTimeoutMillis
        ) throws IOException
    }

    static final class NetworkResponse implements Closeable {
        final int statusCode
        final String location
        final InputStream body
        private final Closure<?> closeAction

        NetworkResponse(
            int statusCode,
            String location,
            InputStream body,
            Closure<?> closeAction
        ) {
            this.statusCode = statusCode
            this.location = location
            this.body = body
            this.closeAction = closeAction
        }

        @Override
        void close() {
            try {
                body?.close()
            } finally {
                closeAction?.call()
            }
        }
    }

    static final class HttpsByteSource implements ByteSource {
        private static final Set<Integer> REDIRECT_STATUSES =
            [301, 302, 303, 307, 308] as Set<Integer>

        private final ConnectionFactory connectionFactory

        HttpsByteSource(ConnectionFactory connectionFactory) {
            this.connectionFactory = Objects.requireNonNull(connectionFactory)
        }

        @Override
        void copy(
            URI uri,
            OutputStream output,
            long expectedSize,
            int connectTimeoutMillis,
            int readTimeoutMillis,
            int maxRedirects
        ) {
            URI current = requireHttps(uri)
            int redirects = 0

            while (true) {
                NetworkResponse response = connectionFactory.open(
                    current,
                    connectTimeoutMillis,
                    readTimeoutMillis,
                )
                try {
                    if (response.statusCode == 200) {
                        if (response.body == null) {
                            throw new IllegalStateException(
                                "HTTPS response has no body: ${current}",
                            )
                        }
                        byte[] buffer = new byte[64 * 1024]
                        int count
                        while ((count = response.body.read(buffer)) != -1) {
                            output.write(buffer, 0, count)
                        }
                        return
                    }

                    if (!REDIRECT_STATUSES.contains(response.statusCode)) {
                        throw new IllegalStateException(
                            "Unexpected HTTPS status ${response.statusCode} " +
                                "for ${current}",
                        )
                    }
                    if (response.location == null ||
                        response.location.trim().isEmpty()) {
                        throw new IllegalStateException(
                            "HTTPS redirect has no Location: ${current}",
                        )
                    }
                    if (redirects >= maxRedirects) {
                        throw new IllegalStateException(
                            "Too many HTTPS redirects for ${uri}",
                        )
                    }

                    URI location
                    try {
                        location = new URI(response.location)
                    } catch (URISyntaxException error) {
                        throw new IllegalArgumentException(
                            "Invalid HTTPS redirect Location: " +
                                "${response.location}",
                            error,
                        )
                    }
                    current = requireHttps(current.resolve(location))
                    redirects++
                } finally {
                    response.close()
                }
            }
        }
    }

    private static final class JdkHttpsConnectionFactory
        implements ConnectionFactory {
        @Override
        NetworkResponse open(
            URI uri,
            int connectTimeoutMillis,
            int readTimeoutMillis
        ) {
            URI secureUri = requireHttps(uri)
            def rawConnection = secureUri.toURL().openConnection()
            if (!(rawConnection instanceof HttpsURLConnection)) {
                throw new SecurityException(
                    "Only HTTPS connections are allowed: ${secureUri}",
                )
            }

            HttpsURLConnection connection =
                (HttpsURLConnection) rawConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.useCaches = false
            connection.doInput = true
            connection.setRequestProperty(
                'User-Agent',
                'media-kit-verified-asset-downloader/1',
            )

            try {
                int statusCode = connection.responseCode
                String location = connection.getHeaderField('Location')
                InputStream body = statusCode == 200
                    ? connection.inputStream
                    : InputStream.nullInputStream()
                return new NetworkResponse(
                    statusCode,
                    location,
                    body,
                    { connection.disconnect() },
                )
            } catch (Throwable error) {
                connection.disconnect()
                throw error
            }
        }
    }

    private static final class BoundedOutputStream extends OutputStream {
        private final OutputStream delegate
        private final long limit
        private long count

        BoundedOutputStream(OutputStream delegate, long limit) {
            this.delegate = Objects.requireNonNull(delegate)
            this.limit = limit
        }

        long getCount() {
            count
        }

        @Override
        void write(int value) {
            requireCapacity(1)
            delegate.write(value)
            count++
        }

        @Override
        void write(byte[] bytes, int offset, int length) {
            Objects.checkFromIndexSize(offset, length, bytes.length)
            requireCapacity(length)
            delegate.write(bytes, offset, length)
            count += length
        }

        @Override
        void flush() {
            delegate.flush()
        }

        private void requireCapacity(int additionalBytes) {
            if (additionalBytes < 0 ||
                count > limit - (long) additionalBytes) {
                throw new IllegalStateException(
                    "Asset exceeds reviewed byte length ${limit}",
                )
            }
        }
    }

    VerifiedAssetDownloader(
        ByteSource byteSource,
        AtomicPlacer atomicPlacer,
        int connectTimeoutMillis,
        int readTimeoutMillis,
        int maxRedirects
    ) {
        this(
            byteSource,
            atomicPlacer,
            connectTimeoutMillis,
            readTimeoutMillis,
            maxRedirects,
            durabilitySync(),
        )
    }

    VerifiedAssetDownloader(
        ByteSource byteSource,
        AtomicPlacer atomicPlacer,
        int connectTimeoutMillis,
        int readTimeoutMillis,
        int maxRedirects,
        DurabilitySync durabilitySync
    ) {
        this.byteSource = Objects.requireNonNull(byteSource)
        this.atomicPlacer = Objects.requireNonNull(atomicPlacer)
        this.durabilitySync = Objects.requireNonNull(durabilitySync)
        if (connectTimeoutMillis <= 0 || readTimeoutMillis <= 0) {
            throw new IllegalArgumentException(
                'Connect and read timeouts must be positive.',
            )
        }
        if (maxRedirects < 0 || maxRedirects > 16) {
            throw new IllegalArgumentException(
                'Redirect limit must be between 0 and 16.',
            )
        }
        this.connectTimeoutMillis = connectTimeoutMillis
        this.readTimeoutMillis = readTimeoutMillis
        this.maxRedirects = maxRedirects
    }

    void ensureAssets(Path outputDirectory, List<Asset> assets) {
        Path directory = validateOutputDirectory(outputDirectory)
        List<Asset> manifest = validateManifest(assets)
        Files.createDirectories(directory)
        if (Files.isSymbolicLink(directory) ||
            !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) {
            throw new SecurityException(
                "Asset output is not a regular directory: ${directory}",
            )
        }

        Path lockPath = directory.resolve('.verified-assets.lock')
        if (Files.isSymbolicLink(lockPath)) {
            throw new SecurityException(
                "Asset lock must not be a symbolic link: ${lockPath}",
            )
        }

        String lockKey = lockPath.toAbsolutePath().normalize().toString()
        ReentrantLock jvmLock = JVM_LOCKS.computeIfAbsent(
            lockKey,
            { new ReentrantLock() },
        )
        jvmLock.lockInterruptibly()
        try {
            FileChannel lockChannel = FileChannel.open(
                lockPath,
                StandardOpenOption.CREATE,
                StandardOpenOption.WRITE,
            )
            try {
                FileLock processLock = acquireProcessLock(lockChannel)
                try {
                    cleanAbandonedPartials(directory, manifest)
                    rejectStaleJars(directory, manifest)
                    manifest.each { Asset asset ->
                        Path destination = directory.resolve(asset.fileName)
                        if (!isVerified(destination, asset)) {
                            downloadAndPublish(directory, destination, asset)
                        }
                    }
                    rejectStaleJars(directory, manifest)
                    manifest.each { Asset asset ->
                        Path destination = directory.resolve(asset.fileName)
                        if (!isVerified(destination, asset)) {
                            throw new IllegalStateException(
                                "Verified asset changed after placement: " +
                                    "${destination}",
                            )
                        }
                    }
                } finally {
                    processLock.release()
                }
            } finally {
                lockChannel.close()
            }
        } finally {
            jvmLock.unlock()
        }
    }

    static AtomicPlacer atomicPlacer() {
        { Path source, Path destination ->
            Files.move(
                source,
                destination,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } as AtomicPlacer
    }

    static DurabilitySync durabilitySync() {
        { FileChannel channel, boolean metadata ->
            channel.force(metadata)
        } as DurabilitySync
    }

    static VerifiedAssetDownloader production() {
        new VerifiedAssetDownloader(
            new HttpsByteSource(new JdkHttpsConnectionFactory()),
            atomicPlacer(),
            DEFAULT_CONNECT_TIMEOUT_MILLIS,
            DEFAULT_READ_TIMEOUT_MILLIS,
            DEFAULT_MAX_REDIRECTS,
            durabilitySync(),
        )
    }

    static void requireExecution(Task task) {
        Objects.requireNonNull(task).outputs.upToDateWhen { false }
    }

    private void downloadAndPublish(
        Path directory,
        Path destination,
        Asset asset
    ) {
        if (Files.isSymbolicLink(destination)) {
            throw new SecurityException(
                "Asset destination must not be a symbolic link: ${destination}",
            )
        }

        Path temporary = Files.createTempFile(
            directory,
            ".${asset.fileName}.",
            '.part',
        )
        if (temporary.parent != directory) {
            Files.deleteIfExists(temporary)
            throw new IllegalStateException(
                'Temporary asset was not created beside its destination.',
            )
        }

        try {
            FileChannel channel = FileChannel.open(
                temporary,
                StandardOpenOption.WRITE,
                StandardOpenOption.TRUNCATE_EXISTING,
            )
            try {
                BoundedOutputStream output = new BoundedOutputStream(
                    Channels.newOutputStream(channel),
                    asset.size,
                )
                byteSource.copy(
                    asset.uri,
                    output,
                    asset.size,
                    connectTimeoutMillis,
                    readTimeoutMillis,
                    maxRedirects,
                )
                output.flush()
                if (output.count != asset.size) {
                    throw new IllegalStateException(
                        "Asset ${asset.fileName} has ${output.count} bytes; " +
                            "expected ${asset.size}.",
                    )
                }
                durabilitySync.sync(channel, true)
            } finally {
                channel.close()
            }

            if (!isVerified(temporary, asset)) {
                throw new IllegalStateException(
                    "SHA-256 verification failed for ${asset.fileName}",
                )
            }
            atomicPlacer.place(temporary, destination)
            if (!isVerified(destination, asset)) {
                Files.deleteIfExists(destination)
                throw new IllegalStateException(
                    "Placed asset failed re-verification: ${asset.fileName}",
                )
            }
        } finally {
            Files.deleteIfExists(temporary)
        }
    }

    private static List<Asset> validateManifest(List<Asset> assets) {
        if (assets == null || assets.isEmpty()) {
            throw new IllegalArgumentException(
                'At least one verified asset is required.',
            )
        }

        Set<String> names = new LinkedHashSet<>()
        Set<String> urls = new LinkedHashSet<>()
        assets.each { Asset asset ->
            if (asset == null) {
                throw new IllegalArgumentException(
                    'Verified assets must not contain null.',
                )
            }
            if (asset.fileName == null ||
                !(asset.fileName ==~
                    /[A-Za-z0-9][A-Za-z0-9._-]*\.jar/)) {
                throw new IllegalArgumentException(
                    "Unsafe verified asset file name: ${asset.fileName}",
                )
            }
            if (!names.add(asset.fileName)) {
                throw new IllegalArgumentException(
                    "Duplicate verified asset file name: ${asset.fileName}",
                )
            }
            URI secureUri = requireHttps(asset.uri)
            if (!urls.add(secureUri.normalize().toASCIIString())) {
                throw new IllegalArgumentException(
                    "Duplicate verified asset URL: ${secureUri}",
                )
            }
            if (asset.size <= 0) {
                throw new IllegalArgumentException(
                    "Invalid reviewed size for ${asset.fileName}",
                )
            }
            if (asset.sha256 == null ||
                !(asset.sha256 ==~ /[0-9a-f]{64}/)) {
                throw new IllegalArgumentException(
                    "Invalid SHA-256 for ${asset.fileName}",
                )
            }
        }
        Collections.unmodifiableList(new ArrayList<>(assets))
    }

    private static Path validateOutputDirectory(Path outputDirectory) {
        if (outputDirectory == null) {
            throw new IllegalArgumentException(
                'Asset output directory is required.',
            )
        }
        Path directory = outputDirectory.toAbsolutePath().normalize()
        if (Files.exists(directory, LinkOption.NOFOLLOW_LINKS) &&
            (Files.isSymbolicLink(directory) ||
                !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS))) {
            throw new SecurityException(
                "Asset output is not a regular directory: ${directory}",
            )
        }
        directory
    }

    private static URI requireHttps(URI uri) {
        if (uri == null ||
            !uri.absolute ||
            !'https'.equalsIgnoreCase(uri.scheme) ||
            uri.host == null ||
            uri.host.trim().isEmpty() ||
            uri.rawUserInfo != null ||
            uri.rawFragment != null) {
            throw new SecurityException(
                "Only absolute HTTPS asset URLs are allowed: ${uri}",
            )
        }
        uri
    }

    private static FileLock acquireProcessLock(FileChannel channel) {
        long deadline = System.nanoTime() + LOCK_TIMEOUT_NANOS
        while (true) {
            try {
                FileLock lock = channel.tryLock()
                if (lock != null) {
                    return lock
                }
            } catch (OverlappingFileLockException ignored) {
                // Another downloader in this JVM owns the OS-level lock.
            }

            if (System.nanoTime() >= deadline) {
                throw new IllegalStateException(
                    'Timed out waiting for verified asset lock.',
                )
            }
            try {
                Thread.sleep(25)
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt()
                InterruptedIOException interrupted =
                    new InterruptedIOException(
                        'Interrupted while waiting for verified asset lock.',
                    )
                interrupted.initCause(error)
                throw interrupted
            }
        }
    }

    private static void cleanAbandonedPartials(
        Path directory,
        List<Asset> assets
    ) {
        Set<String> prefixes = assets.collect {
            ".${it.fileName}."
        } as Set<String>
        Files.list(directory).withCloseable { stream ->
            stream.forEach { Path entry ->
                String name = entry.fileName.toString()
                if (name.endsWith('.part') &&
                    prefixes.any { name.startsWith(it) }) {
                    Files.deleteIfExists(entry)
                }
            }
        }
    }

    private static void rejectStaleJars(
        Path directory,
        List<Asset> assets
    ) {
        Set<String> expected = assets.collect {
            it.fileName
        } as Set<String>
        Files.list(directory).withCloseable { stream ->
            stream.forEach { Path entry ->
                String name = entry.fileName.toString()
                if (name.endsWith('.jar') && !expected.contains(name)) {
                    throw new IllegalStateException(
                        "Unreviewed stale JAR in verified output: ${name}",
                    )
                }
            }
        }
    }

    private static boolean isVerified(Path path, Asset asset) {
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            return false
        }
        if (Files.isSymbolicLink(path) ||
            !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new SecurityException(
                "Verified asset is not a regular file: ${path}",
            )
        }
        if (Files.size(path) != asset.size) {
            return false
        }
        sha256(path) == asset.sha256
    }

    private static String sha256(Path path) {
        MessageDigest digest = MessageDigest.getInstance('SHA-256')
        Files.newInputStream(path).withCloseable { input ->
            byte[] buffer = new byte[64 * 1024]
            int count
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count)
            }
        }
        HexFormat.of().formatHex(digest.digest())
    }
}
