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

let libmpvArtifactBase = "https://github.com/D4rKai/libmpv-darwin-build/releases/download/v0.7.2-atlas-af1/libmpv-xcframeworks_v0.7.2-atlas-af1_macos-universal-video-default"
let libmpvChecksums = [
    "Ass": "e033c5feaa9e1c8783e0262844673c7640aca4b21a669564849a38139cb2304f",
    "Avcodec": "3f0037c8acb783819a93ce125472f3c935cedea5421fd56ed423dab10a71f880",
    "Avfilter": "69c8c7d21546e0cee64877a2b45d73b587a69f0e4c263ba12801d4c9aea74d34",
    "Avformat": "ef6395fb1c3b83a19a8a1fb99394d7f243a865cc953e0c5c9168cd4246884412",
    "Avutil": "3a9e8d5e968fdd831a46778613bf794e371f037a3b65bc0293477b85d7efeb90",
    "Dav1d": "6bede5e31a58cdfa37d8db3c6940dd24309b6cbca70e9ca6568816146e2d9dfd",
    "Freetype": "94d8cad03804f5793c4602a5feb58c9177cc9f98010b6d7493f5baf9c50a374b",
    "Fribidi": "14b7ed3bc116145385d160ce9b21e59a83b4e1f6b38a288c3b4a05933b05b45e",
    "Harfbuzz": "28619cc2c18cb933ca39659f7059c07a1e1a8d57e9aa1ce2df25d2dbc7d62f6c",
    "Mbedcrypto": "ead7d07e141e305f66fb0ec8126c647057241b8e9695376778df2e3b1f0c1d44",
    "Mbedtls": "38219ed2e2b4700e2318d9c3d4b63c7ebd6427ecebb1125a322c4d654c9b6e4f",
    "Mbedx509": "7f9606baaacea0cb0b71caeb20582e30462ff741ffba3ded64ebf0018953f6c3",
    "Mpv": "026a5317ef3f070218b08ea0af0d3a710fb92e125bc4fbe9815fbc336d98b4b4",
    "Png16": "1a84956f3897ddb49326731dd855fa061784e5e93af340d13743ba926b4eb8df",
    "Swresample": "df1c71e6a4a4437c294338039fb1363026d1520715cc7cba53b4cf69ab8d7f7d",
    "Swscale": "160de04b2d03976e0b0661e6dad82823d9a9cc52072232e8c0e697026925c950",
    "Uchardet": "7316ffed88d4beadd5e34df9519b246c78b34538958eecc13bff4f53903acb84",
    "Xml2": "0a88ad4eed13b71fce30b9e9885682278c807fc2c5f0656052c4dd9f06107d6b"
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
