import AppKit
import Foundation

@main
enum ApplicationLinkProbe {
    static func main() {
        let links = [
            ("codex://threads/00000000-0000-0000-0000-000000000000", "com.openai.codex"),
            ("claude://resume?session=00000000-0000-0000-0000-000000000000", "com.anthropic.claudefordesktop"),
        ]

        for (rawURL, expectedBundleIdentifier) in links {
            guard let url = URL(string: rawURL),
                  let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
                  let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
            else {
                fatalError("No installed application handles \(rawURL)")
            }
            guard bundleIdentifier == expectedBundleIdentifier else {
                fatalError("\(rawURL) resolves to \(bundleIdentifier), expected \(expectedBundleIdentifier)")
            }
        }

        print("Codex and Claude conversation links resolve to their installed desktop apps")
    }
}
