import Darwin
import Foundation
import ForgeMenuCore

@main
private enum ForgeRuntimeLeaseTestHelper {
    static func main() {
        guard CommandLine.arguments.count == 5,
              let mode = Mode(rawValue: CommandLine.arguments[2])
        else {
            FileHandle.standardError.write(
                Data("usage: ForgeRuntimeLeaseTestHelper <runtime-root> <shared|exclusive> <marker> <exit|hold>\n".utf8)
            )
            exit(64)
        }

        do {
            let rootURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let lease = RuntimeStoreLease(rootURL: rootURL)
            let token = try lease.acquire(mode.leaseMode)
            let markerURL = URL(fileURLWithPath: CommandLine.arguments[3])
            try Data("locked".utf8).write(to: markerURL, options: .withoutOverwriting)
            if CommandLine.arguments[4] == "hold" {
                while true { pause() }
            }
            token.release()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private enum Mode: String {
        case shared
        case exclusive

        var leaseMode: RuntimeStoreLease.Mode {
            switch self {
            case .shared: return .sharedExecution
            case .exclusive: return .exclusiveMutation
            }
        }
    }
}
