import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_write_adapter.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import '../../helpers/ble/ble_fakes.dart';
import '../../helpers/ble/mock_ble_write_client.dart';

class _FakeStateManager extends BLEStateManager {
  bool peripheralMode = false;
  bool paired = true;
  _FakeStateManager() : super(identityManager: null);
  @override
  bool get isPeripheralMode => peripheralMode;
  @override
  bool get isPaired => paired;
  @override
  String getIdType() => paired ? 'persistent' : 'ephemeral';
}

class _FakeCentralManager implements CentralManager {
  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakePeripheralManager implements PeripheralManager {
  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  late _FakeStateManager stateManager;
  late FakeBleWriteClient writeClient;
  late BleWriteAdapter adapter;

  setUp(() {
    stateManager = _FakeStateManager();
    writeClient = FakeBleWriteClient();
    adapter = BleWriteAdapter(
      contactRepository: ContactRepository(),
      stateManagerProvider: () => stateManager,
      writeClient: writeClient,
    );
  });

  test('central send returns false when write client throws', () async {
    writeClient.throwCentral = true;

    final result = await adapter.sendCentralMessage(
      centralManager: _FakeCentralManager(),
      connectedDevice: Peripheral(uuid: makeUuid(1)),
      messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(2)),
      recipientKey: 'recipient',
      content: 'hi',
      mtuSize: 20,
    );

    expect(result, isFalse);
  });

  test('peripheral send short-circuits when not in peripheral mode', () async {
    stateManager.peripheralMode = false;

    final result = await adapter.sendPeripheralMessage(
      peripheralManager: _FakePeripheralManager(),
      connectedCentral: Central(uuid: makeUuid(3)),
      messageCharacteristic: FakeGATTCharacteristic(uuid: makeUuid(4)),
      senderKey: 'sender',
      content: 'hello',
      mtuSize: 20,
    );

    expect(result, isFalse);
    expect(writeClient.lastPeripheralValue, isNull);
  });
}
