import Foundation

public struct ScannedConnection: Sendable, Hashable {
    public let pid: Int32
    public let processName: String
    public let remoteAddress: String
    public let remotePort: UInt16
    public let bytesInBuffer: UInt32

    public init(
        pid: Int32,
        processName: String,
        remoteAddress: String,
        remotePort: UInt16,
        bytesInBuffer: UInt32
    ) {
        self.pid = pid
        self.processName = processName
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.bytesInBuffer = bytesInBuffer
    }
}
