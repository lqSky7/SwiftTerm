// swift-tools-version: 6.2
import PackageDescription

// The layout is Warp's: `app/` is the application, `crates/` are the subsystems it is built from.
// One target rather than one per crate, because a Swift module boundary would mean marking the
// whole emulator API `package` for no gain — the purity rule is already enforced by the harnesses,
// which compile the model sources on their own and would fail if AppKit ever leaked into them.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftTerm",
            path: ".",
            // Everything that is not the binary: documentation, scripts, harnesses, and the source
            // Info.plist, which Scripts/build-app.sh copies into the bundle itself.
            exclude: [
                "Tests", "docs", "Scripts", "dist",
                "app/Info.plist", "app/SwiftTerm.entitlements",
                "README.md", "READ_ME.md", "EDITOR.md", "index.md",
                "AGENTS.md", "tinycast_architecture_and_rules.md", "warp_features.md",
                // Every directory carries an index.md for the next agent to read. SwiftPM has no
                // glob, so each one is named — which is also the honest list of what is not code.
                "app/index.md",
                "app/src/index.md",
                "app/src/workspace/index.md",
                "app/src/terminal/index.md",
                "app/src/terminal/model/index.md",
                "app/src/terminal/view/index.md",
                "crates/index.md",
                "crates/warp_terminal/index.md",
                "crates/warp_terminal/src/index.md",
                "crates/warp_terminal/src/model/index.md",
                "crates/warp_terminal/src/local_tty/index.md",
                "crates/warp_terminal/src/shell/index.md",
                "crates/warp_terminal/src/bootstrap/index.md",
                "crates/warpui_core/index.md",
                "crates/warpui_core/src/index.md",
            ],
            sources: [
                "app/src",
                "crates/warp_terminal/src",
                "crates/warpui_core/src",
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
