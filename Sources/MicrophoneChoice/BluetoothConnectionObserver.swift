import Foundation
import IOBluetooth

/// Tracks the radio connection independently of Core Audio's occasionally stale device list.
final class BluetoothConnectionObserver: NSObject {
    var onDisconnect: ((String) -> Void)?
    var onConnect: (() -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var devices: [String: IOBluetoothDevice] = [:]
    private var lastConnected: [String: Bool] = [:]
    private var trustedKeys = Set<String>()

    func start(watching keys: Set<String>) {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        watch(keys)
    }

    /// Unknown address formats continue to use Core Audio's connection tracking.
    func availableKeys(from keys: Set<String>) -> Set<String> {
        watch(keys)
        return Set(keys.filter { key in
            guard let device = devices[key] else { return true }
            let connected = device.isConnected()
            if connected { trustedKeys.insert(key) }
            if lastConnected[key] == true && !connected {
                onDisconnect?(key)
            }
            lastConnected[key] = connected
            return connected || !trustedKeys.contains(key)
        })
    }

    private func watch(_ keys: Set<String>) {
        for key in keys where devices[key] == nil {
            guard bluetoothAddressKey(key) != nil,
                  let device = IOBluetoothDevice(addressString: key.replacingOccurrences(of: "-", with: ":"))
            else { continue }
            devices[key] = device
            let connected = device.isConnected()
            lastConnected[key] = connected
            if connected { trustedKeys.insert(key) }
            disconnectNotifications[key] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification,
                                        device: IOBluetoothDevice) {
        DispatchQueue.main.async { [self] in
            guard let key = bluetoothAddressKey(device.addressString) else { return }
            watch([key])
            lastConnected[key] = true
            trustedKeys.insert(key)
            onConnect?()
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification,
                                           device: IOBluetoothDevice) {
        DispatchQueue.main.async { [self] in
            guard let key = bluetoothAddressKey(device.addressString) else { return }
            lastConnected[key] = false
            onDisconnect?(key)
        }
    }
}
