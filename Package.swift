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
        // WebP 인코더 (https://github.com/webmproject/libwebp, BSD). macOS는 WebP를 읽기만 한다.
        .target(
            name: "CWebP",
            exclude: ["LICENSE", "PATENTS", "VERSION.txt"],
            cSettings: [.headerSearchPath("."), .unsafeFlags(["-O2", "-w"]), .define("NDEBUG")]
        ),
        // 사진 형식 바꾸기 (JPG · PNG · HEIC · WebP · AVIF · TIFF, SVG 읽기)
        .target(name: "ConvertCore", dependencies: ["ZipCore", "CWebP"]),
        // 용량 줄이기 (사진, 영상, PDF, Office 문서, 소리)
        .target(name: "ShrinkCore", dependencies: ["ZipCore"]),
        // 앱 화면 (상태 모델 + SwiftUI 뷰). 앱과 화면 확인 도구가 함께 쓴다.
        .target(name: "FinderieUI", dependencies: ["ZipCore", "ShrinkCore", "ConvertCore"]),
        .executableTarget(name: "Finderie", dependencies: ["ZipCore", "FinderieUI"]),
        .executableTarget(name: "FinderieCLI", dependencies: ["ZipCore", "ShrinkCore", "ConvertCore"]),
        // 화면 상태를 PNG로 그려 보는 확인 도구
        .executableTarget(name: "FinderieSnap", dependencies: ["ZipCore", "FinderieUI"]),
    ]
)
