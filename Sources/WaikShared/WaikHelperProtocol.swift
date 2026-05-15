import Foundation

@objc public protocol WaikHelperProtocol {
    func ping(reply: @escaping (String) -> Void)
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Int32) -> Void)
}
