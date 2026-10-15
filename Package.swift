// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Finderie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Finderie", targets: ["Finderie"]),
        .executable(name: "finderie-cli", targets: ["FinderieCLI"]),
        .executable(name: "finderie-snap", targets: ["FinderieSnap"]),
    ],
    targets: [
        // 빠른 deflate 엔진 (https://github.com/ebiggers/libdeflate, MIT)
        .target(
            name: "CLibdeflate",
            exclude: ["LICENSE", "VERSION.txt"],
            cSettings: [.unsafeFlags(["-O3", "-w"]), .define("NDEBUG")]
        ),
        .target(name: "ZipCore", dependencies: ["CLibdeflate"]),
        // 용량 줄이기 (사진, 영상, PDF, Office 문서, 소리)
        .target(name: "ShrinkCore", dependencies: ["ZipCore"]),
        // 앱 화면 (상태 모델 + SwiftUI 뷰). 앱과 화면 확인 도구가 함께 쓴다.
        .target(name: "FinderieUI", dependencies: ["ZipCore", "ShrinkCore"]),
        .executableTarget(name: "Finderie", dependencies: ["ZipCore", "FinderieUI"]),
        .executableTarget(name: "FinderieCLI", dependencies: ["ZipCore", "ShrinkCore"]),
        // 화면 상태를 PNG로 그려 보는 확인 도구
        .executableTarget(name: "FinderieSnap", dependencies: ["ZipCore", "FinderieUI"]),
    ]
)
