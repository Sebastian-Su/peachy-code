import Foundation

enum SafeFileTree {
    static func copyContents(
        from source: URL,
        to destination: URL,
        excluding excludedPaths: Set<String> = [],
        invalidPath: (String) -> any Error
    ) throws {
        let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let relative = try relativePath(of: item, under: source, invalidPath: invalidPath)
            guard !excludedPaths.contains(relative) else { continue }
            let target = destination.appendingPathComponent(relative)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    static func safeURL(
        relativePath: String,
        under directory: URL,
        resolveSymlinks: Bool,
        invalidPath: (String) -> any Error
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw invalidPath(relativePath)
        }
        let base = normalized(directory, resolveSymlinks: resolveSymlinks)
        let result = normalized(base.appendingPathComponent(relativePath), resolveSymlinks: resolveSymlinks)
        guard result.path.hasPrefix(base.path + "/") else {
            throw invalidPath(relativePath)
        }
        return result
    }

    static func relativePath(
        of item: URL,
        under directory: URL,
        invalidPath: (String) -> any Error
    ) throws -> String {
        let basePath = normalized(directory, resolveSymlinks: true).path
        let itemPath = normalized(item, resolveSymlinks: true).path
        guard itemPath.hasPrefix(basePath + "/") else {
            throw invalidPath(item.path)
        }
        return String(itemPath.dropFirst(basePath.count + 1))
    }

    private static func normalized(_ url: URL, resolveSymlinks: Bool) -> URL {
        let value = resolveSymlinks ? url.resolvingSymlinksInPath() : url
        return value.standardizedFileURL
    }
}
