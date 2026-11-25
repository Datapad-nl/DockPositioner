import CoreAudio
import Darwin
import DockPositionerCore

/// The processes that have an audio output running, from Core Audio's process objects (no permission needed).
/// Processes without a running output are left out, so only those are looked up further.
@available(macOS 14.2, *)
func readSoundingAudioProcesses() -> [AudioProcess] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
    return objects.compactMap { object in
        guard let running: UInt32 = value(object, kAudioProcessPropertyIsRunningOutput), running != 0,
              let pid: pid_t = value(object, kAudioProcessPropertyPID)
        else { return nil }
        return AudioProcess(pid: pid, executablePath: executablePath(pid), bundleID: bundleID(object),
                            isRunningOutput: true)
    }
}

private func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func value<T: BinaryInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
    var address = propertyAddress(selector)
    var result: T = 0
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &result) { bytes in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
    }
    return status == noErr ? result : nil
}

@available(macOS 14.2, *)
private func bundleID(_ object: AudioObjectID) -> String? {
    var address = propertyAddress(kAudioProcessPropertyBundleID)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr,
          let id = result?.takeRetainedValue() as String?, !id.isEmpty
    else { return nil }
    return id
}

private func executablePath(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}
