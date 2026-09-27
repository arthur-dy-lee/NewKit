import Foundation

/// App-Group-shared UserDefaults — readable by the Finder Sync extension.
enum SharedDefaults {
    static let appGroupID = "XVZHPD648U.com.codearthur.matrixapps.newkit"

    /// Ad-hoc Debug builds have no Team ID, so they cannot claim the release App Group.
    static var store: UserDefaults {
#if DEBUG
        .standard
#else
        UserDefaults(suiteName: appGroupID) ?? .standard
#endif
    }
}
