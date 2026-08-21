import Foundation

enum AppResourceLocator {

    static func requiredToolURL(named name: String) throws -> URL {
        guard let url = toolURL(named: name) else {
            throw RestoreError.missingTool(name)
        }
        return url
    }

    static func pythonToolEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for root in resourceRoots {
            for relative in ["Tools/python", "Resources/Tools/python"] {
                let directory = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: directory.path) {
                    let existing = environment["PYTHONPATH"].flatMap { $0.isEmpty ? nil : $0 }
                    environment["PYTHONPATH"] = [directory.path, existing].compactMap { $0 }.joined(separator: ":")
                    return environment
                }
            }
        }
        return environment
    }

    static func resourceURL(name: String, extension fileExtension: String?, subdirectories: [String]) -> URL? {
        let filename = fileExtension.map { "\(name).\($0)" } ?? name
        var candidates: [URL] = []
        for root in resourceRoots {
            for subdirectory in subdirectories {
                candidates.append(root.appendingPathComponent(subdirectory).appendingPathComponent(filename))
            }
        }
        for sourceResources in sourceResourceRoots {
            for subdirectory in subdirectories {
                candidates.append(sourceResources.appendingPathComponent(subdirectory).appendingPathComponent(filename))
            }
        }
        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func toolURL(named name: String) -> URL? {
        candidateToolURLs(named: name)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var selectedArchitectureDirectory: String {
        #if arch(x86_64)
        return "x86_64"
        #else
        return "arm64"
        #endif
    }

    private static func candidateToolURLs(named name: String) -> [URL] {
        var urls: [URL] = []

        for root in resourceRoots {
            for relativePath in bundledRelativePaths(named: name) {
                urls.append(root.appendingPathComponent(relativePath))
            }
        }

        // Development fallback for both `swift run` and Xcode DerivedData launches.
        for sourceResources in sourceResourceRoots {
            for relativePath in sourceRelativePaths(named: name) {
                urls.append(sourceResources.appendingPathComponent(relativePath))
            }
        }

        // Last-resort developer compatibility. A distributed app resolves bundled tools first.
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            urls.append(URL(fileURLWithPath: directory).appendingPathComponent(name))
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func bundledRelativePaths(named name: String) -> [String] {
        if name == "usbliter8ctl" {
            return [
                "Tools/usbliter8ctl",
                "Resources/Tools/usbliter8ctl",
                "Tools/x86_64/usbliter8ctl",
                "Resources/Tools/x86_64/usbliter8ctl"
            ]
        }
        if name == "irecovery" {
            return ["Tools/irecovery", "Resources/Tools/irecovery"]
        }
        #if arch(x86_64)
        return ["Tools/x86_64/\(name)", "Resources/Tools/x86_64/\(name)"]
        #else
        return ["Tools/arm64/\(name)", "Resources/Tools/arm64/\(name)"]
        #endif
    }

    private static func sourceRelativePaths(named name: String) -> [String] {
        if name == "usbliter8ctl" {
            return ["Tools/usbliter8ctl", "Tools/x86_64/usbliter8ctl"]
        }
        if name == "irecovery" {
            return ["Tools/irecovery"]
        }
        #if arch(x86_64)
        return ["Tools/x86_64/\(name)"]
        #else
        return ["Tools/arm64/\(name)"]
        #endif
    }

    private static var sourceResourceRoots: [URL] {
        let sourceAdjacent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/usbliter8Remote/Resources", isDirectory: true)
        var seen = Set<String>()
        return [sourceAdjacent, currentDirectory]
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static var resourceRoots: [URL] {
        var roots = [Bundle.main.bundleURL]
        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
