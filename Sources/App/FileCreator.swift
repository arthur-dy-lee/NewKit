import Foundation

enum FileCreatorError: Error {
    case directoryNotWritable(URL)
    case writeFailed(URL, Error)
}

enum FileCreator {

    /// Creates a new file/folder of the given type in `directory`, auto-resolving name collisions.
    /// Returns the URL of the created item.
    @discardableResult
    static func create(_ type: FileType, in directory: URL) throws -> URL {
        let url = uniqueURL(in: directory, baseName: type.defaultName, ext: type.ext)

        do {
            if type.isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else if let override = readOverride(for: type.id), !override.isEmpty {
                let filename = url.deletingPathExtension().lastPathComponent
                let rendered = TemplateRenderer.render(override, filename: filename, author: readAuthor())
                try (rendered.data(using: .utf8) ?? Data()).write(to: url, options: .withoutOverwriting)
            } else if let bundled = type.bundledTemplateName,
                      let src = bundledResourceURL(named: bundled) {
                try FileManager.default.copyItem(at: src, to: url)
            } else {
                let raw = type.templateContent ?? ""
                let filename = url.deletingPathExtension().lastPathComponent
                let author = readAuthor()
                let rendered = TemplateRenderer.render(raw, filename: filename, author: author)
                let data = rendered.data(using: .utf8) ?? Data()
                try data.write(to: url, options: .withoutOverwriting)
            }
        } catch {
            throw FileCreatorError.writeFailed(url, error)
        }
        Log.info("Created: \(url.path)")
        return url
    }

    /// Reads `author` from UserDefaults synchronously without touching the MainActor singleton.
    /// Lets us render templates from any actor context (e.g. URLSchemeHandler).
    private static func readAuthor() -> String {
        UserDefaults.standard.string(forKey: "author") ?? NSFullUserName()
    }

    private static func readOverride(for id: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: "templateOverrides"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict[id]
    }

    /// Looks up a bundled resource (`blank.xlsx` etc.) regardless of file extension.
    private static func bundledResourceURL(named name: String) -> URL? {
        let url = name as NSString
        let stem = url.deletingPathExtension
        let ext = url.pathExtension
        return Bundle.main.url(forResource: stem, withExtension: ext)
    }

    /// Resolves "Foo.txt" → "Foo.txt", "Foo 2.txt", "Foo 3.txt", ...
    static func uniqueURL(in directory: URL, baseName: String, ext: String?) -> URL {
        var candidate = compose(directory: directory, name: baseName, ext: ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = compose(directory: directory, name: "\(baseName) \(index)", ext: ext)
            index += 1
        }
        return candidate
    }

    private static func compose(directory: URL, name: String, ext: String?) -> URL {
        let filename = (ext?.isEmpty == false) ? "\(name).\(ext!)" : name
        return directory.appendingPathComponent(filename)
    }
}
