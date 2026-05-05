import Foundation

// Lightweight, dependency-free re-implementations of the data model and creation logic
// suitable for a command-line target (no AppKit, no MainActor).

struct CLIFileType: Codable {
    let id: String
    let ext: String?
    let symbolName: String?
    let templateContent: String?
    let bundledTemplateName: String?
    let isFolder: Bool
    let isBuiltIn: Bool
    let menuTitleKey: String?
    let menuTitleLiteral: String?
    let defaultNameKey: String?
    let defaultNameLiteral: String?

    var defaultName: String {
        if let lit = defaultNameLiteral, !lit.isEmpty { return lit }
        if let key = defaultNameKey {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        return "Untitled"
    }
}

enum CLIRegistry {
    static let builtIns: [CLIFileType] = [
        CLIFileType(id: "txt",  ext: "txt",  symbolName: nil, templateContent: nil, bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: "menu.newfile.txt", menuTitleLiteral: nil,
                    defaultNameKey: "newfile.txt", defaultNameLiteral: "Untitled"),
        CLIFileType(id: "md",   ext: "md",   symbolName: nil, templateContent: nil, bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: "menu.newfile.md", menuTitleLiteral: nil,
                    defaultNameKey: "newfile.md", defaultNameLiteral: "Untitled"),
        CLIFileType(id: "py",   ext: "py",   symbolName: nil,
                    templateContent: "#!/usr/bin/env python3\n", bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "js",   ext: "js",   symbolName: nil, templateContent: nil, bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "ts",   ext: "ts",   symbolName: nil, templateContent: nil, bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "json", ext: "json", symbolName: nil, templateContent: "{}\n", bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "html", ext: "html", symbolName: nil,
                    templateContent: "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"UTF-8\">\n  <title></title>\n</head>\n<body>\n</body>\n</html>\n",
                    bundledTemplateName: nil, isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "css",  ext: "css",  symbolName: nil, templateContent: nil, bundledTemplateName: nil,
                    isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "sh",   ext: "sh",   symbolName: nil,
                    templateContent: "#!/usr/bin/env bash\nset -euo pipefail\n\n",
                    bundledTemplateName: nil, isFolder: false, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "Untitled"),
        CLIFileType(id: "folder", ext: nil, symbolName: nil, templateContent: nil, bundledTemplateName: nil,
                    isFolder: true, isBuiltIn: true,
                    menuTitleKey: nil, menuTitleLiteral: nil,
                    defaultNameKey: nil, defaultNameLiteral: "untitled folder"),
    ]

    /// Built-ins plus any custom types persisted by the GUI app.
    static func allTypes() -> [CLIFileType] {
        builtIns + loadCustomTypes()
    }

    private static func loadCustomTypes() -> [CLIFileType] {
        guard let data = UserDefaults.standard.data(forKey: "customFileTypes"),
              let list = try? JSONDecoder().decode([CLIFileType].self, from: data)
        else { return [] }
        return list
    }
}

enum CLIFileCreator {
    static func create(_ type: CLIFileType, in directory: URL) throws -> URL {
        let url = uniqueURL(in: directory, baseName: type.defaultName, ext: type.ext)
        if type.isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        if let bundled = type.bundledTemplateName,
           let src = Bundle.main.url(forResource: (bundled as NSString).deletingPathExtension,
                                     withExtension: (bundled as NSString).pathExtension) {
            try FileManager.default.copyItem(at: src, to: url)
            return url
        }
        let raw = readOverride(for: type.id) ?? type.templateContent ?? ""
        let filename = url.deletingPathExtension().lastPathComponent
        let rendered = renderTemplate(raw, filename: filename, author: readAuthor())
        try (rendered.data(using: .utf8) ?? Data()).write(to: url, options: .withoutOverwriting)
        return url
    }

    private static func uniqueURL(in directory: URL, baseName: String, ext: String?) -> URL {
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

    private static func readAuthor() -> String {
        UserDefaults.standard.string(forKey: "author") ?? NSFullUserName()
    }

    private static func readOverride(for id: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: "templateOverrides"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict[id]
    }

    private static func renderTemplate(_ template: String, filename: String, author: String) -> String {
        let now = Date()
        let date = format(now, "yyyy-MM-dd")
        let time = format(now, "HH:mm:ss")
        var output = template
        for (k, v) in [
            "date": date, "time": time, "datetime": "\(date) \(time)",
            "year": format(now, "yyyy"), "filename": filename, "author": author
        ] {
            output = output.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return output
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
