import Foundation

/// Substitutes `{{var}}` placeholders inside a template string.
///
/// Supported variables:
///   - `{{date}}`     — `2026-05-05`
///   - `{{time}}`     — `14:32:08`
///   - `{{datetime}}` — `2026-05-05 14:32:08`
///   - `{{year}}`     — `2026`
///   - `{{filename}}` — base name without extension (e.g. `Untitled`)
///   - `{{author}}`   — value from Configuration.shared.author
enum TemplateRenderer {
    static func render(_ template: String, filename: String, author: String) -> String {
        let now = Date()
        let date = format(now, "yyyy-MM-dd")
        let time = format(now, "HH:mm:ss")
        let datetime = "\(date) \(time)"
        let year = format(now, "yyyy")

        var output = template
        let map: [String: String] = [
            "date": date,
            "time": time,
            "datetime": datetime,
            "year": year,
            "filename": filename,
            "author": author
        ]
        for (key, value) in map {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
