import Foundation

public enum PlainpostServiceXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PlainpostServiceXPCProtocol.self)
        PlainpostXPCInterfaceConfiguration.configureServiceInterface(interface)
        return interface
    }
}
