import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Toggles the floating "new file" panel.
    static let toggleFloatingPanel = Self("toggleFloatingPanel")

    /// Toggles the built-in display on/off. Default Cmd+Ctrl+Shift+Z is
    /// chosen to avoid the common Cmd+Shift+Z (Redo) collision while still
    /// being something the user can hit blind — important because if the
    /// built-in panel is currently the only visible screen, this shortcut
    /// is the user's emergency way back.
    static let toggleBuiltInDisplay = Self(
        "toggleBuiltInDisplay",
        default: .init(.z, modifiers: [.command, .control, .shift])
    )
}
