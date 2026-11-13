import Carbon.HIToolbox

/// Phím tắt toàn cục qua Carbon RegisterEventHotKey: không cần quyền Accessibility.
final class HotKey {
    var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return noErr }
                Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4E54_4348), id: 1) // 'NTCH'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
