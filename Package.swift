// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clothespeg",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(
            name: "Clothespeg",
            path: "Sources/Clothespeg",
            exclude: ["Resources"],
            // Quick Look renders a document card, in the view form: the panel
            // form wants the key window, which a strip floating over the top
            // of the screen cannot take. Linked by hand because SwiftPM does
            // not link it on its own.
            linkerSettings: [.linkedFramework("QuickLookUI")])
    ]
)