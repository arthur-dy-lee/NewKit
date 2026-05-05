import Foundation

// MARK: - CLI tool: `newkit`
//
// Commands:
//   newkit list                 — show all known file types
//   newkit new <id> [path]      — create a new file of <id> in [path] or current directory
//   newkit help                 — print usage
//
// The CLI reuses the main app's UserDefaults (suite domain "app.newkit.NewKit") for
// custom types and template overrides via the system-wide UserDefaults — when the
// user has run NewKit at least once, the CLI inherits that configuration.

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

switch command {
case "list":
    listTypes()
case "new":
    let typeID = args.dropFirst().first ?? ""
    let pathArg = args.dropFirst(2).first
    createFile(typeID: typeID, pathArg: pathArg)
case "help", "--help", "-h":
    printUsage()
default:
    fputs("newkit: unknown command '\(command)'\n", stderr)
    printUsage()
    exit(2)
}

// MARK: -

func printUsage() {
    print("""
    NewKit CLI

    Usage:
      newkit list                 List all known file types
      newkit new <id> [path]      Create a new file of <id> in [path] (default: current dir)
      newkit help                 Show this help

    Examples:
      newkit new py
      newkit new md ./notes
    """)
}

func listTypes() {
    for type in CLIRegistry.allTypes() {
        let badge = type.isBuiltIn ? "" : " [custom]"
        let ext = type.ext.map { ".\($0)" } ?? ""
        print("  \(type.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(ext)\(badge)")
    }
}

func createFile(typeID: String, pathArg: String?) {
    guard !typeID.isEmpty else {
        fputs("newkit: missing <id>\n", stderr)
        exit(2)
    }
    guard let type = CLIRegistry.allTypes().first(where: { $0.id == typeID }) else {
        fputs("newkit: unknown type '\(typeID)'. Run 'newkit list'.\n", stderr)
        exit(2)
    }
    let dir: URL
    if let arg = pathArg {
        dir = URL(fileURLWithPath: NSString(string: arg).expandingTildeInPath, isDirectory: true)
    } else {
        dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
    do {
        let url = try CLIFileCreator.create(type, in: dir)
        print(url.path)
    } catch {
        fputs("newkit: create failed: \(error)\n", stderr)
        exit(1)
    }
}
