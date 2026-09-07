import Foundation

/// Download caches of every package manager found on the machine. Each one is
/// refilled on demand, and the tool's own prune command is used when it has one
/// so its bookkeeping stays consistent.
struct PackageProbe: StorageProbe {
    private struct Cache {
        let id: String
        let name: String
        let url: URL
        let tool: String?
        let arguments: [String]
        let detail: String
        var safety: Safety = .safe
    }

    func probe() async -> [StorageItem] {
        var caches: [Cache] = [
            Cache(id: "brew", name: "Homebrew downloads", url: .home("Library/Caches/Homebrew"),
                  tool: "brew", arguments: ["cleanup", "--prune=all", "-s"], detail: "Bottles and source tarballs."),
            Cache(id: "npm", name: "npm cache", url: .home(".npm/_cacache"),
                  tool: "npm", arguments: ["cache", "clean", "--force"], detail: "Package tarballs and metadata."),
            Cache(id: "yarn", name: "Yarn cache", url: .home("Library/Caches/Yarn"),
                  tool: "yarn", arguments: ["cache", "clean"], detail: "Package tarballs."),
            Cache(id: "pip", name: "pip cache", url: .home("Library/Caches/pip"),
                  tool: "pip3", arguments: ["cache", "purge"], detail: "Wheels and HTTP cache."),
            Cache(id: "uv", name: "uv cache", url: .home(".cache/uv"),
                  tool: "uv", arguments: ["cache", "clean"], detail: "Python wheels and interpreters."),
            Cache(id: "pods", name: "CocoaPods cache", url: .home("Library/Caches/CocoaPods"),
                  tool: "pod", arguments: ["cache", "clean", "--all"], detail: "Pod specs and sources."),
            Cache(id: "gradle", name: "Gradle caches", url: .home(".gradle/caches"),
                  tool: nil, arguments: [], detail: "Dependency jars and build cache. Re-downloaded on the next build."),
            Cache(id: "cargo", name: "Cargo registry", url: .home(".cargo/registry"),
                  tool: nil, arguments: [], detail: "Crate sources and downloads."),
            Cache(id: "swiftpm", name: "SwiftPM cache", url: .home("Library/Caches/org.swift.swiftpm"),
                  tool: nil, arguments: [], detail: "Package repository clones."),
            Cache(id: "go", name: "Go build cache", url: .home("Library/Caches/go-build"),
                  tool: nil, arguments: [], detail: "Compiled Go packages."),
            Cache(id: "cypress", name: "Cypress binaries", url: .home("Library/Caches/Cypress"),
                  tool: nil, arguments: [], detail: "Downloaded Cypress versions."),
            Cache(id: "playwright", name: "Playwright browsers", url: .home("Library/Caches/ms-playwright"),
                  tool: nil, arguments: [], detail: "Downloaded browser builds. Reinstalled by `npx playwright install`."),
        ]

        if let pnpm = Shell.which("pnpm") {
            if let result = try? await Shell.run(pnpm, ["store", "path"], mergeStderr: false),
               result.succeeded {
                let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                caches.append(Cache(id: "pnpm", name: "pnpm store", url: URL(fileURLWithPath: path),
                                    tool: "pnpm", arguments: ["store", "prune"],
                                    detail: "Unreferenced packages in the content-addressable store."))
            }
        } else if let store = Self.defaultPnpmStore {
            caches.append(Cache(id: "pnpm", name: "pnpm store", url: store, tool: nil, arguments: [],
                                detail: "pnpm was not found on this Mac, so nothing appears to be using this store. If you run pnpm through a version manager, it is still in use.",
                                safety: .review))
        }

        var items: [StorageItem] = []
        for cache in caches {
            let action: ReclaimAction
            if let tool = cache.tool, let executable = Shell.which(tool) {
                action = .command(executable: executable, arguments: cache.arguments)
            } else {
                action = .emptyDirectories([cache.url])
            }
            if let item = await ProbeSupport.directoryItem(
                id: "pkg-\(cache.id)", category: .packages, name: cache.name, detail: cache.detail,
                url: cache.url, safety: cache.safety, action: action, minimumBytes: ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        for prefix in ["/opt/homebrew", "/usr/local"] {
            let url = URL(fileURLWithPath: prefix)
            guard url.appending(path: "bin/brew").exists else { continue }
            let rawDetail = "\(prefix): every formula and cask installed with brew. Remove what you no longer use."
            if let item = await ProbeSupport.directoryItem(
                id: "pkg-homebrew-\(prefix)", category: .packages, name: "Homebrew installation",
                detail: rawDetail,
                url: url, safety: .manual,
                action: .manual("brew leaves            # formulae you asked for\nbrew list --cask\nbrew uninstall <formula>\nbrew uninstall --cask <name>\nbrew autoremove"),
                minimumBytes: 100 * ProbeSupport.megabyte,
                displayDetail: L("%@: every formula and cask installed with brew. Remove what you no longer use.", prefix)
            ) {
                items.append(item)
            }
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    static var defaultPnpmStore: URL? {
        [URL.home("Library/pnpm/store"), URL.home(".local/share/pnpm/store"), URL.home(".pnpm-store")]
            .first { $0.exists }
    }
}
