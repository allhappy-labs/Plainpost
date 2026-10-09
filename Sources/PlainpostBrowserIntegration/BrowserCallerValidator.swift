import Foundation

public enum BrowserCallerValidator {
    public static let chromiumOrigin =
        "chrome-extension://fjhlbghobimgnakkhigjmjejahjackfo/"
    public static let geckoExtensionID = "quick-mail@plainpost.olhapi.com"

    public static func isAllowed(arguments: [String]) -> Bool {
        if arguments == [chromiumOrigin] {
            return true
        }
        return arguments.count == 2
            && NSString(string: arguments[0]).isAbsolutePath
            && arguments[1] == geckoExtensionID
    }
}
