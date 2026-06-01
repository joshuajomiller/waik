import Foundation
import CProcInfo
import WaikCore

enum SocketScanner {
    private static let maxConnections = 4096

    static func scan() -> [ScannedConnection] {
        var buffer = [WaikConnection](
            repeating: WaikConnection(),
            count: maxConnections
        )
        let count: Int = buffer.withUnsafeMutableBufferPointer { ptr in
            Int(waik_scan_connections(ptr.baseAddress, maxConnections))
        }
        if count <= 0 { return [] }

        var results: [ScannedConnection] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let raw = buffer[i]
            let name = withCString(of: raw.process_name)
            let addr = withCString(of: raw.remote_address)
            results.append(ScannedConnection(
                pid: raw.pid,
                processName: name,
                remoteAddress: addr,
                remotePort: raw.remote_port,
                bytesInBuffer: raw.bytes_in_buffer
            ))
        }
        return results
    }

    private static func withCString<T>(of tuple: T) -> String {
        // Reinterpret a fixed C char[] tuple as a null-terminated C string.
        var copy = tuple
        return withUnsafePointer(to: &copy) { ptr in
            ptr.withMemoryRebound(to: CChar.self,
                                  capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
