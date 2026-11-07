// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clothespeg",
    platforms: [.macOS(.v14)],
    dependencies: [
        // A local SwiftPM dependency: the licence-verification library
        // (Ed25519 verify + Keychain) is linked into the app, so the built
        // .app needs no other repository at run time. Building does; see the
        // "Build from source" section of the README.
        .package(path: "../LicenseKit")
    ],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(
            name: "Clothespeg",
            dependencies: [.product(name: "LicenseKit", package: "LicenseKit")],
            path: "Sources/Clothespeg",
            exclude: ["Resources"],
            // Quick Look renders a document card, in the view form: the panel
            // form wants the key window, which a strip floating over the top
            // of the screen cannot take. Linked by hand because SwiftPM does
            // not link it on its own.
            linkerSettings: [.linkedFramework("QuickLookUI")])
    ]
)