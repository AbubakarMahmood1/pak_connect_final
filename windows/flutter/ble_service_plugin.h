#ifndef BLE_SERVICE_PLUGIN_H_
#define BLE_SERVICE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>
#include <mutex>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Storage.Streams.h>

namespace pak_connect {

    class BleServicePlugin : public flutter::Plugin {
    public:
        static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

        BleServicePlugin(flutter::PluginRegistrarWindows* registrar);
        virtual ~BleServicePlugin();

    private:
        // Method channel handlers
        void HandleMethodCall(
                const flutter::MethodCall<flutter::EncodableValue>& method_call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

        // Event channels
        std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> scan_results_channel_;
        std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> connection_state_channel_;
        std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> bluetooth_state_channel_;

        // Event sinks
        std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> scan_results_sink_;
        std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> connection_state_sink_;
        std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> bluetooth_state_sink_;

        // BLE functionality
        winrt::Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher watcher_{nullptr};
        std::map<uint64_t, winrt::Windows::Devices::Bluetooth::BluetoothLEDevice> connected_devices_;
        std::map<std::string, winrt::event_token> notification_tokens_;
        std::mutex devices_mutex_;

        // Event registrations
        winrt::event_token watcher_received_token_;
        winrt::event_token watcher_stopped_token_;

        // Helper methods
        flutter::EncodableValue DeviceToMap(winrt::Windows::Devices::Bluetooth::BluetoothLEDevice device, int rssi);
        flutter::EncodableValue ServiceToMap(winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattDeviceService service);
        flutter::EncodableValue CharacteristicToMap(winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::GattCharacteristic characteristic);

        // BLE methods
        winrt::Windows::Foundation::IAsyncOperation<bool> InitializeBluetooth();
        winrt::Windows::Foundation::IAsyncOperation<bool> IsBluetoothAvailable();
        winrt::Windows::Foundation::IAsyncOperation<bool> StartScan(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<bool> StopScan();
        winrt::Windows::Foundation::IAsyncOperation<bool> ConnectToDevice(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<bool> DisconnectDevice(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<flutter::EncodableList> DiscoverServices(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<bool> WriteCharacteristic(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<flutter::EncodableValue> ReadCharacteristic(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<bool> SubscribeToCharacteristic(const flutter::EncodableMap& args);
        winrt::Windows::Foundation::IAsyncOperation<bool> UnsubscribeFromCharacteristic(const flutter::EncodableMap& args);

        // Method channel
        flutter::MethodChannel<flutter::EncodableValue> method_channel_;

        // Plugin registrar
        flutter::PluginRegistrarWindows* registrar_;
    };

}  // namespace pak_connect

#endif  // BLE_SERVICE_PLUGIN_H_