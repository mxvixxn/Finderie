// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zippie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Zippie", targets: ["Zippie"]),
        .executable(name: "zippie-cli", targets: ["ZippieCLI"]),
    ],
    targets: [
        // 빠른 deflate 엔진 (https://github.com/ebiggers/libdeflate, MIT)
        .target(
            name: "CLibdeflate",
            exclude: ["LICENSE", "VERSION.txt"],
            cSettings: [.unsafeFlags(["-O3", "-w"]), .define("NDEBUG")]
        ),
        .target(name: "ZipCore", dependencies: ["CLibdeflate"]),
        .executableTarget(name: "Zippie", dependencies: ["ZipCore"]),
        .executableTarget(name: "ZippieCLI", dependencies: ["ZipCore"]),
    ]
)
