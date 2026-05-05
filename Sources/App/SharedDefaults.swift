import Foundation

/// App-Group-shared UserDefaults — readable by the Finder Sync extension.
enum SharedDefaults {
    static let appGroupID = "XVZHPD648U.com.codearthur.matrixapps.newkit"

    /// Falls back to `.standard` if the App Group isn't available (e.g. unsigned local builds).
    static var store: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}
