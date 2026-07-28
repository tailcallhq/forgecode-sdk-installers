import Darwin
import Foundation

public struct LoopbackEndpoint: Equatable, Sendable {
    public static let host = "127.0.0.1"

    public let port: UInt16

    public init(port: UInt16) {
        self.port = port
    }

    public var address: String { "\(Self.host):\(port)" }

    public var webSocketURL: URL {
        URL(string: "ws://\(address)")!
    }
}

public protocol LoopbackEndpointAllocating: Sendable {
    func allocate() throws -> LoopbackEndpoint
}

public struct SystemLoopbackEndpointAllocator: LoopbackEndpointAllocating {
    public static let preferredPort: UInt16 = 9_753

    public init() {}

    public func allocate() throws -> LoopbackEndpoint {
        // Allocate deterministically from the ForgeCode frontend's historical
        // default: 9753, 9754, 9755, and so on. Existing listeners are only
        // probed and are never stopped or otherwise modified.
        for candidate in UInt32(Self.preferredPort)...UInt32(UInt16.max) {
            let port = UInt16(candidate)
            if try isAvailable(port) {
                return LoopbackEndpoint(port: port)
            }
        }

        throw ForgeCoreError.portAllocation("no available loopback port was found in 9753–65535")
    }

    private func isAvailable(_ port: UInt16) throws -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ForgeCoreError.portAllocation(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var value = Int32(1)
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(LoopbackEndpoint.host))

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}
