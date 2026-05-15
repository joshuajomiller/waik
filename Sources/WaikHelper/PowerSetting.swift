import Foundation
import Darwin

private typealias IOPMSetSystemPowerSettingFn =
    @convention(c) (CFString, CFTypeRef) -> Int32

private let _setSystemPowerSetting: IOPMSetSystemPowerSettingFn? = {
    let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
    guard let handle = dlopen(path, RTLD_NOW) else { return nil }
    guard let sym = dlsym(handle, "IOPMSetSystemPowerSetting") else { return nil }
    return unsafeBitCast(sym, to: IOPMSetSystemPowerSettingFn.self)
}()

@discardableResult
func setSleepDisabledRaw(_ disabled: Bool) -> Int32 {
    guard let fn = _setSystemPowerSetting else { return -1 }
    let key = "SleepDisabled" as CFString
    let value: CFTypeRef = disabled ? kCFBooleanTrue : kCFBooleanFalse
    return fn(key, value)
}
