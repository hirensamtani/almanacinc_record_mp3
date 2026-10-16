// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "almanacinc_record_mp3",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(
            name: "almanacinc-record-mp3",
            targets: ["almanacinc_record_mp3"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "almanacinc_record_mp3",
            dependencies: [],
            path: "../Classes",
            resources: [
                .process("../Resources/PrivacyInfo.xcprivacy")
            ],
            cSettings: [
                .headerSearchPath("lame"),
                .headerSearchPath("lame/include")
            ]
        )
    ]
)
