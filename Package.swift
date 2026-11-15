// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "JarvisPhone", platforms: [.iOS(.v17)],
    products: [.executable(name: "JarvisPhone", targets: ["JarvisPhone"])],
    targets: [.executableTarget(name: "JarvisPhone", path: "JarvisPhone", exclude: ["Assets.xcassets","Info.plist","Resources"])])
