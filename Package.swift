// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "JarvisPhone", platforms: [.iOS(.v17)],
    products: [.library(name: "JarvisPhone", targets: ["JarvisPhone"])],
    targets: [.target(name: "JarvisPhone", path: "JarvisPhone", exclude: ["Assets.xcassets","Info.plist","Resources"])])
