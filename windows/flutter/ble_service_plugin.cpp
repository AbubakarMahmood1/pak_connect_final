#include "ble_service_plugin.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <sstream>
#include <Windows.h>
#include <string>
#include <map>
#include <vector>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Radios;
using namespace Windows::Storage::Streams;
using namespace Windows::Foundation;
using namespace Windows::Foundation::Collections;

namespace pak_connect {

// Static registration function
    void BleServicePlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
        auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                registrar->messenger(), "pak_connect/ble_windows",
                        &flutter::StandardMethodCodec::GetInstance());

        auto plugin = std::make_unique<BleServicePlugin>(registrar);
        channel->SetMethodCallHandler(
                [plugin_pointer = plugin.get()](const auto& call, auto result) {
                    plugin_pointer->HandleMethodCall(call, std::move(result));
                });

        registrar->AddPlugin(std::move(plugin));
    }

// Plugin constructor
    BleServicePlugin::BleServicePlugin(flutter::PluginRegistrarWindows* registrar)
            : registrar_(registrar),
              method_channel_(
                      flutter::MethodChannel<flutter::EncodableValue>(
                              registrar->messenger(), "pak_connect/ble_windows",
                              &flutter::StandardMethodCodec::GetInstance())) {

        // Create event channels for streaming data
        scan_results_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
                registrar->messenger(), "pak_connect/ble_windows/scan_results",
                        &flutter::StandardMethodCodec::GetInstance());

        connection_state_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
                registrar->messenger(), "pak_connect/ble_windows/connection_state",
                        &flutter::StandardMethodCodec::GetInstance());

        bluetooth_state_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
                registrar->messenger(), "pak_connect/ble_windows/bluetooth_state",
                        &flutter::StandardMethodCodec::GetInstance());

        // Set up event handlers for the channels
        scan_results_channel_->SetStreamHandler(
                std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
                        [this](
                                const flutter::EncodableValue* arguments,
                                std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
                            scan_results_sink_ = std::move(events);
                            return nullptr; // success
                        },
                                [this](const flutter::EncodableValue* arguments) {
                                    scan_results_sink_.reset();
                                    return nullptr; // success
                                }));

        connection_state_channel_->SetStreamHandler(
                std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
                        [this](
                                const flutter::EncodableValue* arguments,
                                std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
                            connection_state_sink_ = std::move(events);
                            return nullptr; // success
                        },
                                [this](const flutter::EncodableValue* arguments) {
                                    connection_state_sink_.reset();
                                    return nullptr; // success
                                }));

        bluetooth_state_channel_->SetStreamHandler(
                std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
                        [this](
                                const flutter::EncodableValue* arguments,
                                std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
                            bluetooth_state_sink_ = std::move(events);
                            return nullptr; // success
                        },
                                [this](const flutter::EncodableValue* arguments) {
                                    bluetooth_state_sink_.reset();
                                    return nullptr; // success
                                }));
    }

// Plugin destructor
    BleServicePlugin::~BleServicePlugin() {
        // Stop scanning if still active
        if (watcher_ != nullptr) {
            try {
                watcher_.Stop();
            } catch (...) {
                // Ignore any errors during cleanup
            }
        }

        // Clean up device connections
        std::lock_guard<std::mutex> lock(devices_mutex_);
        connected_devices_.clear();
    }

// Handle method calls from Dart
    void BleServicePlugin::HandleMethodCall(
            const flutter::MethodCall<flutter::EncodableValue>& method_call,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

        const auto& method_name = method_call.method_name();
        const auto* arguments = method_call.arguments();

        if (method_name == "initialize") {
            auto operation = InitializeBluetooth();
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("initialize_error", "Failed to initialize Bluetooth");
                }
            });
        } else if (method_name == "isBluetoothAvailable") {
            auto operation = IsBluetoothAvailable();
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("bluetooth_error", "Failed to check Bluetooth availability");
                }
            });
        } else if (method_name == "startScan") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = StartScan(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("scan_error", "Failed to start scanning");
                }
            });
        } else if (method_name == "stopScan") {
            auto operation = StopScan();
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("scan_error", "Failed to stop scanning");
                }
            });
        } else if (method_name == "connectToDevice") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = ConnectToDevice(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("connection_error", "Failed to connect to device");
                }
            });
        } else if (method_name == "disconnectDevice") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = DisconnectDevice(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("disconnect_error", "Failed to disconnect device");
                }
            });
        } else if (method_name == "discoverServices") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = DiscoverServices(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(operation.GetResults());
                } else {
                    result->Error("service_error", "Failed to discover services");
                }
            });
        } else if (method_name == "writeCharacteristic") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = WriteCharacteristic(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("write_error", "Failed to write characteristic");
                }
            });
        } else if (method_name == "readCharacteristic") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = ReadCharacteristic(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(operation.GetResults());
                } else {
                    result->Error("read_error", "Failed to read characteristic");
                }
            });
        } else if (method_name == "subscribeToCharacteristic") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = SubscribeToCharacteristic(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("subscribe_error", "Failed to subscribe to characteristic");
                }
            });
        } else if (method_name == "unsubscribeFromCharacteristic") {
            if (!arguments) {
                result->Error("argument_error", "Arguments required");
                return;
            }

            auto args_map = std::get<flutter::EncodableMap>(*arguments);
            auto operation = UnsubscribeFromCharacteristic(args_map);
            operation.Completed([result = std::move(result)](auto operation, auto status) {
                if (status == AsyncStatus::Completed) {
                    result->Success(flutter::EncodableValue(operation.GetResults()));
                } else {
                    result->Error("unsubscribe_error", "Failed to unsubscribe from characteristic");
                }
            });
        } else if (method_name == "startAdvertising") {
            // Windows doesn't fully support peripheral mode - return false
            result->Success(flutter::EncodableValue(false));
        } else if (method_name == "stopAdvertising") {
            // Windows doesn't fully support peripheral mode - return true
            result->Success(flutter::EncodableValue(true));
        } else if (method_name == "dispose") {
            // Clean up resources
            if (watcher_ != nullptr) {
                try {
                    watcher_.Stop();
                } catch (...) {
                    // Ignore errors during cleanup
                }
            }

            // Clean up device connections
            std::lock_guard<std::mutex> lock(devices_mutex_);
            connected_devices_.clear();

            result->Success(flutter::EncodableValue(true));
        } else {
            result->NotImplemented();
        }
    }

// Initialize Bluetooth functionality
    IAsyncOperation<bool> BleServicePlugin::InitializeBluetooth() {
        try {
            // Create advertisement watcher
            watcher_ = BluetoothLEAdvertisementWatcher();
            watcher_.ScanningMode(BluetoothLEScanningMode::Active);

            // Set up watcher events
            watcher_received_token_ = watcher_.Received([this](BluetoothLEAdvertisementWatcher sender,
                                                               BluetoothLEAdvertisementReceivedEventArgs args) {
                // Create a device info map to send through the stream
                flutter::EncodableMap device_map;
                device_map[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(winrt::to_string(args.BluetoothAddress()));

                auto advertisement = args.Advertisement();
                hstring device_name = advertisement.LocalName();
                std::string name = winrt::to_string(device_name);

                device_map[flutter::EncodableValue("name")] = flutter::EncodableValue(name.empty() ? "Unknown Device" : name);
                device_map[flutter::EncodableValue("rssi")] = flutter::EncodableValue(args.RawSignalStrengthInDBm());

                // Add service UUIDs if available
                flutter::EncodableList service_uuids;
                for (auto service_uuid : advertisement.ServiceUuids()) {
                    service_uuids.push_back(flutter::EncodableValue(winrt::to_string(service_uuid)));
                }
                device_map[flutter::EncodableValue("serviceUuids")] = flutter::EncodableValue(service_uuids);

                // Add to current scan results
                if (scan_results_sink_) {
                    std::vector<flutter::EncodableValue> devices;

                    std::lock_guard<std::mutex> lock(devices_mutex_);
                    bool exists = false;

                    // Check if we already have this device in our list
                    if (!exists) {
                        devices.push_back(flutter::EncodableValue(device_map));
                    }

                    if (!devices.empty()) {
                        scan_results_sink_->Success(flutter::EncodableValue(flutter::EncodableList(devices)));
                    }
                }
            });

            watcher_stopped_token_ = watcher_.Stopped([this](BluetoothLEAdvertisementWatcher sender,
                                                             BluetoothLEAdvertisementWatcherStoppedEventArgs args) {
                flutter::EncodableMap data;
                data[flutter::EncodableValue("isScanning")] = flutter::EncodableValue(false);

                // Notify UI that scanning has stopped
                method_channel_.InvokeMethod("onScanStateChanged",
                                             std::make_unique<flutter::EncodableValue>(data));
            });

            co_return true;
        } catch (...) {
            co_return false;
        }
    }

// Check if Bluetooth is available and enabled
    IAsyncOperation<bool> BleServicePlugin::IsBluetoothAvailable() {
        try {
            // Find the Bluetooth adapter
            auto adapter = co_await BluetoothAdapter::GetDefaultAsync();
            if (adapter) {
                // Check if the adapter is powered on
                return adapter.IsPoweredOn();
            }
            co_return false;
        } catch (...) {
            co_return false;
        }
    }

// Start scanning for BLE devices
    IAsyncOperation<bool> BleServicePlugin::StartScan(const flutter::EncodableMap& args) {
        try {
            // Stop any existing scan
            if (watcher_ != nullptr && watcher_.Status() == BluetoothLEAdvertisementWatcherStatus::Started) {
                watcher_.Stop();
            }

            // Check for timeout parameter
            int timeout_ms = 10000; // Default 10 seconds
            auto timeout_it = args.find(flutter::EncodableValue("timeoutMs"));
            if (timeout_it != args.end()) {
                timeout_ms = std::get<int>(timeout_it->second);
            }

            // Start the watcher
            watcher_.Start();

            // Notify UI that scanning has started
            flutter::EncodableMap data;
            data[flutter::EncodableValue("isScanning")] = flutter::EncodableValue(true);
            method_channel_.InvokeMethod("onScanStateChanged",
                                         std::make_unique<flutter::EncodableValue>(data));

            // Set up timer to stop scan after timeout
            if (timeout_ms > 0) {
                // In real implementation, you'd use a Windows timer to call StopScan after timeout_ms
                // For simplicity, we're not implementing the timer here
            }

            co_return true;
        } catch (...) {
            co_return false;
        }
    }

// Stop scanning for BLE devices
    IAsyncOperation<bool> BleServicePlugin::StopScan() {
        try {
            if (watcher_ != nullptr && watcher_.Status() == BluetoothLEAdvertisementWatcherStatus::Started) {
                watcher_.Stop();

                // Notify UI that scanning has stopped
                flutter::EncodableMap data;
                data[flutter::EncodableValue("isScanning")] = flutter::EncodableValue(false);
                method_channel_.InvokeMethod("onScanStateChanged",
                                             std::make_unique<flutter::EncodableValue>(data));
            }
            co_return true;
        } catch (...) {
            co_return false;
        }
    }

// Connect to a device
    IAsyncOperation<bool> BleServicePlugin::ConnectToDevice(const flutter::EncodableMap& args) {
        try {
            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            if (device_id_it == args.end()) {
                co_return false;
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            // Get the device
            auto device = co_await BluetoothLEDevice::FromBluetoothAddressAsync(device_address);
            if (!device) {
                co_return false;
            }

            // Store the connected device
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                connected_devices_[device_address] = device;
            }

            // Send connection state update
            if (connection_state_sink_) {
                flutter::EncodableMap state_map;
                state_map[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(device_id_str);
                state_map[flutter::EncodableValue("state")] = flutter::EncodableValue("connected");
                state_map[flutter::EncodableValue("isConnected")] = flutter::EncodableValue(true);

                connection_state_sink_->Success(flutter::EncodableValue(state_map));
            }

            co_return true;
        } catch (...) {
            co_return false;
        }
    }

// Disconnect from a device
    IAsyncOperation<bool> BleServicePlugin::DisconnectDevice(const flutter::EncodableMap& args) {
        try {
            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            if (device_id_it == args.end()) {
                co_return false;
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            // Remove the device from connected devices
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                connected_devices_.erase(device_address);
            }

            // Send connection state update
            if (connection_state_sink_) {
                flutter::EncodableMap state_map;
                state_map[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(device_id_str);
                state_map[flutter::EncodableValue("state")] = flutter::EncodableValue("disconnected");
                state_map[flutter::EncodableValue("isConnected")] = flutter::EncodableValue(false);

                connection_state_sink_->Success(flutter::EncodableValue(state_map));
            }

            co_return true;
        } catch (...) {
            co_return false;
        }
    }

// Discover services for a device
    IAsyncOperation<flutter::EncodableList> BleServicePlugin::DiscoverServices(const flutter::EncodableMap& args) {
        try {
            flutter::EncodableList service_list;

            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            if (device_id_it == args.end()) {
                co_return service_list;
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            // Get the device
            BluetoothLEDevice device = nullptr;
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                auto it = connected_devices_.find(device_address);
                if (it != connected_devices_.end()) {
                    device = it->second;
                }
            }

            if (!device) {
                co_return service_list;
            }

            // Get services
            auto services = co_await device.GetGattServicesAsync();
            if (services.Status() != GattCommunicationStatus::Success) {
                co_return service_list;
            }

            for (auto service : services.Services()) {
                flutter::EncodableMap service_map;
                service_map[flutter::EncodableValue("uuid")] =
                        flutter::EncodableValue(winrt::to_string(service.Uuid()));

                flutter::EncodableList characteristics_list;
                auto characteristics = co_await service.GetCharacteristicsAsync();
                if (characteristics.Status() == GattCommunicationStatus::Success) {
                    for (auto characteristic : characteristics.Characteristics()) {
                        flutter::EncodableMap char_map;
                        char_map[flutter::EncodableValue("uuid")] =
                                flutter::EncodableValue(winrt::to_string(characteristic.Uuid()));

                        flutter::EncodableList properties_list;
                        GattCharacteristicProperties props = characteristic.CharacteristicProperties();

                        if ((props & GattCharacteristicProperties::Read) == GattCharacteristicProperties::Read) {
                            properties_list.push_back(flutter::EncodableValue("read"));
                        }
                        if ((props & GattCharacteristicProperties::Write) == GattCharacteristicProperties::Write) {
                            properties_list.push_back(flutter::EncodableValue("write"));
                        }
                        if ((props & GattCharacteristicProperties::Notify) == GattCharacteristicProperties::Notify) {
                            properties_list.push_back(flutter::EncodableValue("notify"));
                        }

                        char_map[flutter::EncodableValue("properties")] = flutter::EncodableValue(properties_list);
                        characteristics_list.push_back(flutter::EncodableValue(char_map));
                    }
                }

                service_map[flutter::EncodableValue("characteristics")] =
                        flutter::EncodableValue(characteristics_list);
                service_list.push_back(flutter::EncodableValue(service_map));
            }

            co_return service_list;
        } catch (...) {
            co_return flutter::EncodableList();
        }
    }

// Write data to a characteristic
    IAsyncOperation<bool> BleServicePlugin::WriteCharacteristic(const flutter::EncodableMap& args) {
        try {
            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            auto service_uuid_it = args.find(flutter::EncodableValue("serviceUuid"));
            auto char_uuid_it = args.find(flutter::EncodableValue("characteristicUuid"));
            auto data_it = args.find(flutter::EncodableValue("data"));
            auto with_response_it = args.find(flutter::EncodableValue("withResponse"));

            if (device_id_it == args.end() || service_uuid_it == args.end() ||
                char_uuid_it == args.end() || data_it == args.end()) {
                co_return false;
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            std::string service_uuid_str = std::get<std::string>(service_uuid_it->second);
            std::string char_uuid_str = std::get<std::string>(char_uuid_it->second);

            // Get the device
            BluetoothLEDevice device = nullptr;
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                auto it = connected_devices_.find(device_address);
                if (it != connected_devices_.end()) {
                    device = it->second;
                }
            }

            if (!device) {
                co_return false;
            }

            // Find the service
            auto services = co_await device.GetGattServicesForUuidAsync(winrt::guid(service_uuid_str));
            if (services.Status() != GattCommunicationStatus::Success || services.Services().Size() == 0) {
                co_return false;
            }

            auto service = services.Services().GetAt(0);

            // Find the characteristic
            auto characteristics = co_await service.GetCharacteristicsForUuidAsync(winrt::guid(char_uuid_str));
            if (characteristics.Status() != GattCommunicationStatus::Success || characteristics.Characteristics().Size() == 0) {
                co_return false;
            }

            auto characteristic = characteristics.Characteristics().GetAt(0);

            // Write the data
            auto data_bytes = std::get<std::vector<uint8_t>>(data_it->second);

            // Create a buffer with the data
            DataWriter writer;
            for (auto byte : data_bytes) {
                writer.WriteByte(byte);
            }

            IBuffer buffer = writer.DetachBuffer();

            // Determine write type
            GattWriteOption write_option = GattWriteOption::WriteWithResponse;
            if (with_response_it != args.end()) {
                bool with_response = std::get<bool>(with_response_it->second);
                if (!with_response) {
                    write_option = GattWriteOption::WriteWithoutResponse;
                }
            }

            // Write to the characteristic
            auto result = co_await characteristic.WriteValueAsync(buffer, write_option);
            co_return result == GattCommunicationStatus::Success;
        } catch (...) {
            co_return false;
        }
    }

// Read data from a characteristic
    IAsyncOperation<flutter::EncodableValue> BleServicePlugin::ReadCharacteristic(const flutter::EncodableMap& args) {
        try {
            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            auto service_uuid_it = args.find(flutter::EncodableValue("serviceUuid"));
            auto char_uuid_it = args.find(flutter::EncodableValue("characteristicUuid"));

            if (device_id_it == args.end() || service_uuid_it == args.end() || char_uuid_it == args.end()) {
                co_return flutter::EncodableValue();
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            std::string service_uuid_str = std::get<std::string>(service_uuid_it->second);
            std::string char_uuid_str = std::get<std::string>(char_uuid_it->second);

            // Get the device
            BluetoothLEDevice device = nullptr;
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                auto it = connected_devices_.find(device_address);
                if (it != connected_devices_.end()) {
                    device = it->second;
                }
            }

            if (!device) {
                co_return flutter::EncodableValue();
            }

            // Find the service
            auto services = co_await device.GetGattServicesForUuidAsync(winrt::guid(service_uuid_str));
            if (services.Status() != GattCommunicationStatus::Success || services.Services().Size() == 0) {
                co_return flutter::EncodableValue();
            }

            auto service = services.Services().GetAt(0);

            // Find the characteristic
            auto characteristics = co_await service.GetCharacteristicsForUuidAsync(winrt::guid(char_uuid_str));
            if (characteristics.Status() != GattCommunicationStatus::Success || characteristics.Characteristics().Size() == 0) {
                co_return flutter::EncodableValue();
            }

            auto characteristic = characteristics.Characteristics().GetAt(0);

            // Read the value
            auto value_result = co_await characteristic.ReadValueAsync();
            if (value_result.Status() != GattCommunicationStatus::Success) {
                co_return flutter::EncodableValue();
            }

            // Convert the value to a byte array
            DataReader reader = DataReader::FromBuffer(value_result.Value());
            std::vector<uint8_t> result_bytes;
            result_bytes.resize(reader.UnconsumedBufferLength());
            reader.ReadBytes(winrt::array_view<uint8_t>(result_bytes));

            co_return flutter::EncodableValue(result_bytes);
        } catch (...) {
            co_return flutter::EncodableValue();
        }
    }

// Subscribe to characteristic notifications
    IAsyncOperation<bool> BleServicePlugin::SubscribeToCharacteristic(const flutter::EncodableMap& args) {
        try {
            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            auto service_uuid_it = args.find(flutter::EncodableValue("serviceUuid"));
            auto char_uuid_it = args.find(flutter::EncodableValue("characteristicUuid"));
            auto notification_channel_it = args.find(flutter::EncodableValue("notificationChannel"));

            if (device_id_it == args.end() || service_uuid_it == args.end() ||
                char_uuid_it == args.end() || notification_channel_it == args.end()) {
                co_return false;
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            std::string service_uuid_str = std::get<std::string>(service_uuid_it->second);
            std::string char_uuid_str = std::get<std::string>(char_uuid_it->second);
            std::string channel_name = std::get<std::string>(notification_channel_it->second);

            // Get the device
            BluetoothLEDevice device = nullptr;
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                auto it = connected_devices_.find(device_address);
                if (it != connected_devices_.end()) {
                    device = it->second;
                }
            }

            if (!device) {
                co_return false;
            }

            // Find the service
            auto services = co_await device.GetGattServicesForUuidAsync(winrt::guid(service_uuid_str));
            if (services.Status() != GattCommunicationStatus::Success || services.Services().Size() == 0) {
                co_return false;
            }

            auto service = services.Services().GetAt(0);

            // Find the characteristic
            auto characteristics = co_await service.GetCharacteristicsForUuidAsync(winrt::guid(char_uuid_str));
            if (characteristics.Status() != GattCommunicationStatus::Success || characteristics.Characteristics().Size() == 0) {
                co_return false;
            }

            auto characteristic = characteristics.Characteristics().GetAt(0);

            // Check if the characteristic supports notifications
            if ((characteristic.CharacteristicProperties() & GattCharacteristicProperties::Notify) != GattCharacteristicProperties::Notify) {
                co_return false;
            }

            // Create an event channel for notifications
            auto notification_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
                    registrar_->messenger(), channel_name,
                            &flutter::StandardMethodCodec::GetInstance());

            auto notification_sink = std::make_shared<flutter::EventSink<flutter::EncodableValue>*>(nullptr);

            // Set up event handler for notifications
            notification_channel->SetStreamHandler(
                    std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
                            [notification_sink](
                                    const flutter::EncodableValue* arguments,
                                    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
                                *notification_sink = events.release();
                                return nullptr; // success
                            },
                                    [notification_sink](const flutter::EncodableValue* arguments) {
                                        if (*notification_sink) {
                                            delete *notification_sink;
                                            *notification_sink = nullptr;
                                        }
                                        return nullptr; // success
                                    }));

            // Set up notification descriptor
            auto status = co_await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
                    GattClientCharacteristicConfigurationDescriptorValue::Notify);

            if (status != GattCommunicationStatus::Success) {
                co_return false;
            }

            // Set up value changed event
            auto token = characteristic.ValueChanged([notification_sink, device_id_str](
                    GattCharacteristic sender,
                    GattValueChangedEventArgs args) {

                if (*notification_sink) {
                    DataReader reader = DataReader::FromBuffer(args.CharacteristicValue());
                    std::vector<uint8_t> data;
                    data.resize(reader.UnconsumedBufferLength());
                    reader.ReadBytes(winrt::array_view<uint8_t>(data));

                    (*notification_sink)->Success(flutter::EncodableValue(data));
                }
            });

            // Store the token for cleanup
            std::string key = device_id_str + "_" + service_uuid_str + "_" + char_uuid_str;
            notification_tokens_[key] = token;

            co_return true;
        } catch (...) {
            co_return false;
        }
    }

// Unsubscribe from characteristic notifications
    IAsyncOperation<bool> BleServicePlugin::UnsubscribeFromCharacteristic(const flutter::EncodableMap& args) {
        try {
            auto device_id_it = args.find(flutter::EncodableValue("deviceId"));
            auto service_uuid_it = args.find(flutter::EncodableValue("serviceUuid"));
            auto char_uuid_it = args.find(flutter::EncodableValue("characteristicUuid"));

            if (device_id_it == args.end() || service_uuid_it == args.end() || char_uuid_it == args.end()) {
                co_return false;
            }

            std::string device_id_str = std::get<std::string>(device_id_it->second);
            uint64_t device_address;
            std::stringstream ss;
            ss << std::hex << device_id_str;
            ss >> device_address;

            std::string service_uuid_str = std::get<std::string>(service_uuid_it->second);
            std::string char_uuid_str = std::get<std::string>(char_uuid_it->second);

            // Get the device
            BluetoothLEDevice device = nullptr;
            {
                std::lock_guard<std::mutex> lock(devices_mutex_);
                auto it = connected_devices_.find(device_address);
                if (it != connected_devices_.end()) {
                    device = it->second;
                }
            }

            if (!device) {
                co_return false;
            }

            // Find the service
            auto services = co_await device.GetGattServicesForUuidAsync(winrt::guid(service_uuid_str));
            if (services.Status() != GattCommunicationStatus::Success || services.Services().Size() == 0) {
                co_return false;
            }

            auto service = services.Services().GetAt(0);

            // Find the characteristic
            auto characteristics = co_await service.GetCharacteristicsForUuidAsync(winrt::guid(char_uuid_str));
            if (characteristics.Status() != GattCommunicationStatus::Success || characteristics.Characteristics().Size() == 0) {
                co_return false;
            }

            auto characteristic = characteristics.Characteristics().GetAt(0);

            // Disable notifications
            auto status = co_await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
                    GattClientCharacteristicConfigurationDescriptorValue::None);

            // Remove the notification token
            std::string key = device_id_str + "_" + service_uuid_str + "_" + char_uuid_str;
            if (notification_tokens_.count(key) > 0) {
                characteristic.ValueChanged(notification_tokens_[key]);
                notification_tokens_.erase(key);
            }

            co_return status == GattCommunicationStatus::Success;
        } catch (...) {
            co_return false;
        }
    }

// Helper method to convert device to map
    flutter::EncodableValue BleServicePlugin::DeviceToMap(BluetoothLEDevice device, int rssi) {
        flutter::EncodableMap device_map;

        device_map[flutter::EncodableValue("deviceId")] =
                flutter::EncodableValue(std::to_string(device.BluetoothAddress()));

        device_map[flutter::EncodableValue("name")] =
                flutter::EncodableValue(winrt::to_string(device.Name()));

        device_map[flutter::EncodableValue("rssi")] =
                flutter::EncodableValue(rssi);

        return flutter::EncodableValue(device_map);
    }

// Helper method to convert service to map
    flutter::EncodableValue BleServicePlugin::ServiceToMap(GattDeviceService service) {
        flutter::EncodableMap service_map;

        service_map[flutter::EncodableValue("uuid")] =
                flutter::EncodableValue(winrt::to_string(service.Uuid()));

        return flutter::EncodableValue(service_map);
    }

// Helper method to convert characteristic to map
    flutter::EncodableValue BleServicePlugin::CharacteristicToMap(GattCharacteristic characteristic) {
        flutter::EncodableMap char_map;

        char_map[flutter::EncodableValue("uuid")] =
                flutter::EncodableValue(winrt::to_string(characteristic.Uuid()));

        flutter::EncodableList properties_list;
        GattCharacteristicProperties props = characteristic.CharacteristicProperties();

        if ((props & GattCharacteristicProperties::Read) == GattCharacteristicProperties::Read) {
            properties_list.push_back(flutter::EncodableValue("read"));
        }
        if ((props & GattCharacteristicProperties::Write) == GattCharacteristicProperties::Write) {
            properties_list.push_back(flutter::EncodableValue("write"));
        }
        if ((props & GattCharacteristicProperties::Notify) == GattCharacteristicProperties::Notify) {
            properties_list.push_back(flutter::EncodableValue("notify"));
        }

        char_map[flutter::EncodableValue("properties")] = flutter::EncodableValue(properties_list);

        return flutter::EncodableValue(char_map);
    }

}  // namespace pak_connect

// Plugin registration function
void BleServicePluginRegisterWithRegistrar(
        flutter::PluginRegistrarWindows* registrar) {
    pak_connect::BleServicePlugin::RegisterWithRegistrar(registrar);
}