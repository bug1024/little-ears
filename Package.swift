// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "LittleEars", platforms: [.macOS(.v14)],
    products: [.executable(name: "LittleEars", targets: ["LittleEars"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.0.0")],
    targets: [
        .executableTarget(name: "LittleEars", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LittleEarsTests", dependencies: ["LittleEars"], resources: [.copy("Fixtures")])
    ]
)
