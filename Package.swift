// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zippie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Zippie", targets: ["Zippie"]),
        .executable(name: "zippie-cli", targets: ["ZippieCLI"]),
        .executable(name: "zippie-snap", targets: ["ZippieSnap"]),
    ],
    targets: [
        // 빠른 deflate 엔진 (https://github.com/ebiggers/libdeflate, MIT)
        .target(
            name: "CLibdeflate",
            exclude: ["LICENSE", "VERSION.txt"],
            cSettings: [.unsafeFlags(["-O3", "-w"]), .define("NDEBUG")]
        ),
        .target(name: "ZipCore", dependencies: ["CLibdeflate"]),
        // 앱 화면 (상태 모델 + SwiftUI 뷰). 앱과 화면 확인 도구가 함께 쓴다.
        .target(name: "ZippieUI", dependencies: ["ZipCore"]),
        .executableTarget(name: "Zippie", dependencies: ["ZipCore", "ZippieUI"]),
        .executableTarget(name: "ZippieCLI", dependencies: ["ZipCore"]),
        // 화면 상태를 PNG로 그려 보는 확인 도구
        .executableTarget(name: "ZippieSnap", dependencies: ["ZipCore", "ZippieUI"]),
    ]
)
