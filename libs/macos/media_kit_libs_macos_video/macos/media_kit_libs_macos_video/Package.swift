// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let libmpvTargets = [
    "Ass",
    "Avcodec",
    "Avfilter",
    "Avformat",
    "Avutil",
    "Dav1d",
    "Freetype",
    "Fribidi",
    "Harfbuzz",
    "Mbedcrypto",
    "Mbedtls",
    "Mbedx509",
    "Mpv",
    "Png16",
    "Swresample",
    "Swscale",
    "Uchardet",
    "Xml2"
]

let libmpvArtifactBase = "https://github.com/D4rKai/libmpv-darwin-build/releases/download/v0.7.2-atlas-af2/libmpv-xcframeworks_v0.7.2-atlas-af2_macos-universal-video-default"
let libmpvChecksums = [
    "Ass": "5f63d50b9b4c6a52a30bfb956c1a859d095bc008f5ec3794d78b62ed3d03eacb",
    "Avcodec": "374a6a827fa4789fe382414d20a43e7b2bf61b9633ed2742239d889845f44d92",
    "Avfilter": "eac4847f4b436288d1f5b115403848011b0fde12bad96de024dab56fb0ca518d",
    "Avformat": "6bf5a79bbc0dc475f2a45f13573809f610bf6ccf0e8071250af8d8f9e31c8ad0",
    "Avutil": "ddbeb9b1f01e8beba3f170027bba3da212024015e887b2ad53487a2d54123d7b",
    "Dav1d": "fb2983a3cc0558c9aa5c45dc3c8d303815f471065d891ef171e7c1fdf6325d9a",
    "Freetype": "97edb593838d696875bd4a4846d65fbbcbef79ac57e64c6cc2d5d18ba564ff54",
    "Fribidi": "305abd0f07c8f4fd5613c377df717979db5c376ea6dd47db091a28195466fd39",
    "Harfbuzz": "f2a822a4ccb03fd660de850d49f4442180def70ccd43987b6102e582a6dbb151",
    "Mbedcrypto": "f2da8b718f1f156b8d318ea98c40a04e86844adce0b15f71b6732aa2287ef7b7",
    "Mbedtls": "09cadf2917baa28e25c21ff8246d0a67e398d8982e9b730aa51608aea9f2c9b5",
    "Mbedx509": "2754002b59129f6bbb74c806c9ddc44450b28eeac23ff299c6ddf56657b112f8",
    "Mpv": "50896cfc9af25107f26e557613e2197d4d7168fcf0b42b85feb538dc8581a80f",
    "Png16": "9a7c0a4f8f0a8b12e9f4537a4383d17c4354405e54a4b0566cbbd97cb221289c",
    "Swresample": "251b4f214313965a357ec42c2b7da65018c3a467f27d24b21033ca0c667f31aa",
    "Swscale": "3974b3cbd0f442f2e832a0d920612a0e20566c8d68b481636a78e7dbff17e0b6",
    "Uchardet": "b03706a663ceca87b210d489858624f775938f10cb8b21dfaf8c567e44d33570",
    "Xml2": "515c41bdb1854080a54512645587d8cbb35fe6fc047b3570854c131453725a2e"
]
let libmpvProductTargets: [String] = ["media_kit_libs_macos_video"] + libmpvTargets

let package = Package(
    name: "media_kit_libs_macos_video",
    platforms: [
        .macOS("10.9")
    ],
    products: [
        .library(name: "media-kit-libs-macos-video", targets: libmpvProductTargets),
        .library(name: "Mpv", targets: ["Mpv"])
    ],
    dependencies: [],
    targets: libmpvTargets.map { framework in
        .binaryTarget(
            name: framework,
            url: "\(libmpvArtifactBase)_\(framework).zip",
            checksum: libmpvChecksums[framework]!
        )
    } + [
        .target(
            name: "media_kit_libs_macos_video",
            dependencies: libmpvTargets.map { framework in .target(name: framework) },
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
