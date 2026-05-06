import Foundation

/// A file type that NewKit can create. May be built-in or user-defined.
struct FileType: Codable, Identifiable, Hashable {
    /// Stable identifier. Built-in types use short slugs ("txt"). Custom types use UUID strings.
    let id: String
    /// File extension (nil for folder).
    let ext: String?
    /// SF Symbol name for the menu icon (optional).
    let symbolName: String?
    /// Optional template content written to the new file.
    let templateContent: String?
    /// Optional name of a bundled binary template resource (e.g. `blank.xlsx`).
    /// When set, the file is created by copying this resource verbatim — `templateContent` is ignored.
    let bundledTemplateName: String?
    let isFolder: Bool
    let isBuiltIn: Bool

    // For built-ins, these reference Localizable.strings keys. For custom types, the strings are
    // user-provided and stored verbatim.
    let menuTitleKey: String?
    let menuTitleLiteral: String?
    let defaultNameKey: String?
    let defaultNameLiteral: String?

    // Backward-compatible decoding so older custom types (without bundledTemplateName) still load.
    enum CodingKeys: String, CodingKey {
        case id, ext, symbolName, templateContent, bundledTemplateName
        case isFolder, isBuiltIn
        case menuTitleKey, menuTitleLiteral, defaultNameKey, defaultNameLiteral
    }

    init(id: String, ext: String?, symbolName: String?, templateContent: String?,
         bundledTemplateName: String? = nil, isFolder: Bool, isBuiltIn: Bool,
         menuTitleKey: String?, menuTitleLiteral: String?,
         defaultNameKey: String?, defaultNameLiteral: String?) {
        self.id = id
        self.ext = ext
        self.symbolName = symbolName
        self.templateContent = templateContent
        self.bundledTemplateName = bundledTemplateName
        self.isFolder = isFolder
        self.isBuiltIn = isBuiltIn
        self.menuTitleKey = menuTitleKey
        self.menuTitleLiteral = menuTitleLiteral
        self.defaultNameKey = defaultNameKey
        self.defaultNameLiteral = defaultNameLiteral
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.ext = try c.decodeIfPresent(String.self, forKey: .ext)
        self.symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
        self.templateContent = try c.decodeIfPresent(String.self, forKey: .templateContent)
        self.bundledTemplateName = try c.decodeIfPresent(String.self, forKey: .bundledTemplateName)
        self.isFolder = try c.decode(Bool.self, forKey: .isFolder)
        self.isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        self.menuTitleKey = try c.decodeIfPresent(String.self, forKey: .menuTitleKey)
        self.menuTitleLiteral = try c.decodeIfPresent(String.self, forKey: .menuTitleLiteral)
        self.defaultNameKey = try c.decodeIfPresent(String.self, forKey: .defaultNameKey)
        self.defaultNameLiteral = try c.decodeIfPresent(String.self, forKey: .defaultNameLiteral)
    }

    var menuTitle: String {
        if let key = menuTitleKey { return L10n.string(key) }
        return menuTitleLiteral ?? id
    }

    var defaultName: String {
        if let key = defaultNameKey { return L10n.string(key) }
        return defaultNameLiteral ?? "Untitled"
    }
}

extension FileType {
    /// Convenience initializer for built-in types.
    static func builtIn(
        id: String,
        ext: String?,
        symbol: String? = nil,
        template: String? = nil,
        bundledTemplate: String? = nil,
        isFolder: Bool = false
    ) -> FileType {
        FileType(
            id: id,
            ext: ext,
            symbolName: symbol,
            templateContent: template,
            bundledTemplateName: bundledTemplate,
            isFolder: isFolder,
            isBuiltIn: true,
            menuTitleKey: "menu.newfile.\(id)",
            menuTitleLiteral: nil,
            defaultNameKey: "newfile.\(id)",
            defaultNameLiteral: nil
        )
    }
}

enum FileTypeRegistry {
    /// Full default catalog (V1.0 scope, minus Office formats which arrive with templates in M3).
    static let builtIns: [FileType] = [
        .builtIn(id: "txt",    ext: "txt",   symbol: "doc.text"),
        .builtIn(id: "md",     ext: "md",    symbol: "doc.richtext"),
        .builtIn(id: "py",     ext: "py",    symbol: "chevron.left.forwardslash.chevron.right",
                 template: "#!/usr/bin/env python3\n"),
        .builtIn(id: "js",     ext: "js",    symbol: "curlybraces"),
        .builtIn(id: "ts",     ext: "ts",    symbol: "curlybraces"),
        .builtIn(id: "json",   ext: "json",  symbol: "curlybraces.square", template: "{}\n"),
        .builtIn(id: "html",   ext: "html",  symbol: "globe",
                 template: "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"UTF-8\">\n  <title></title>\n</head>\n<body>\n</body>\n</html>\n"),
        .builtIn(id: "css",    ext: "css",   symbol: "paintbrush"),
        .builtIn(id: "sh",     ext: "sh",    symbol: "terminal", template: "#!/usr/bin/env bash\nset -euo pipefail\n\n"),
        .builtIn(id: "xlsx",   ext: "xlsx",  symbol: "tablecells", bundledTemplate: "blank.xlsx"),
        .builtIn(id: "docx",   ext: "docx",  symbol: "doc.text.fill", bundledTemplate: "blank.docx"),
        .builtIn(id: "pptx",   ext: "pptx",  symbol: "rectangle.on.rectangle", bundledTemplate: "blank.pptx"),
        .builtIn(id: "folder", ext: nil,     symbol: "folder", isFolder: true),
    ]

    static func builtIn(id: String) -> FileType? {
        builtIns.first { $0.id == id }
    }
}
