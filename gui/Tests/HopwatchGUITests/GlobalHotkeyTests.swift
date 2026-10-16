import Foundation
import Carbon
import Testing
@testable import HopwatchGUI

@Suite struct GlobalHotkeyTests {

    @Test @MainActor func defaultConfiguration() {
        let manager = GlobalHotkeyManager()
        #expect(manager.keyCode == GlobalHotkeyManager.defaultKeyCode)
        #expect(manager.modifiers == GlobalHotkeyManager.defaultModifiers)
        #expect(manager.isEnabled == false)
        #expect(manager.isRegistered == false)
        #expect(manager.shortcutDisplayString == "⌥⌘N")
    }

    @Test @MainActor func registrationAndUnregistration() {
        let manager = GlobalHotkeyManager()
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)

        let success = manager.register()
        #expect(success)
        #expect(manager.isEnabled)
        #expect(manager.isRegistered)

        // Idempotent registration
        let duplicateSuccess = manager.register()
        #expect(duplicateSuccess)
        #expect(manager.isEnabled)
        #expect(manager.isRegistered)

        manager.unregister()
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)

        // Idempotent unregistration
        manager.unregister()
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)
    }

    @Test @MainActor func isEnabledToggling() {
        let manager = GlobalHotkeyManager()
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)

        manager.isEnabled = true
        #expect(manager.isEnabled)
        #expect(manager.isRegistered)

        manager.isEnabled = false
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)

        manager.isEnabled.toggle()
        #expect(manager.isEnabled)
        #expect(manager.isRegistered)

        manager.isEnabled.toggle()
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)
    }

    @Test @MainActor func directCallbackInvocation() {
        let manager = GlobalHotkeyManager()
        var callCount = 0
        manager.onHotkeyPressed = {
            callCount += 1
        }

        #expect(callCount == 0)
        manager.trigger()
        #expect(callCount == 1)

        manager.trigger()
        #expect(callCount == 2)
    }

    @Test @MainActor func carbonEventPipelineDispatch() {
        let manager = GlobalHotkeyManager()
        var triggered = false
        manager.onHotkeyPressed = {
            triggered = true
        }

        #expect(manager.register())
        #expect(manager.isRegistered)

        let dispatched = manager.dispatchSyntheticCarbonEvent()
        #expect(dispatched)
        #expect(triggered)

        // After unregistering, synthetic events shouldn't be delivered to this manager
        manager.unregister()
        triggered = false
        let secondDispatch = manager.dispatchSyntheticCarbonEvent()
        #expect(!secondDispatch)
        #expect(!triggered)
    }

    @Test @MainActor func customShortcutAndDynamicReRegistration() {
        let manager = GlobalHotkeyManager(keyCode: GlobalHotkeyManager.alternativeKeyCode)
        #expect(manager.keyCode == 4)
        #expect(manager.shortcutDisplayString == "⌥⌘H")

        #expect(manager.register())
        #expect(manager.isRegistered)

        // Changing keyCode dynamically re-registers while active
        manager.keyCode = 45
        #expect(manager.isRegistered)
        #expect(manager.shortcutDisplayString == "⌥⌘N")

        // Changing modifiers dynamically re-registers
        manager.modifiers = UInt32(cmdKey)
        #expect(manager.isRegistered)
        #expect(manager.shortcutDisplayString == "⌘N")

        manager.unregister()
        #expect(!manager.isRegistered)
    }

    @Test @MainActor func sharedSingletonAvailable() {
        let shared = GlobalHotkeyManager.shared
        #expect(shared.keyCode == GlobalHotkeyManager.defaultKeyCode)
    }

    @Test @MainActor func lifecycleDeallocation() {
        var callCount = 0
        do {
            let scopedManager = GlobalHotkeyManager()
            scopedManager.onHotkeyPressed = {
                callCount += 1
            }
            #expect(scopedManager.register())
            #expect(scopedManager.isRegistered)
            scopedManager.trigger()
            #expect(callCount == 1)
        }
        // Scope exited; deinit cleaned up without crashing
        #expect(callCount == 1)
    }
}
