import 'dart:typed_data';

abstract interface class IBleMeshEnginePort {
  Future<void> startMesh();
  Future<void> stopMesh();
  Future<void> requestConnect(String peerId);
  Future<void> disconnect(String peerId);
  Future<void> sendBytes(String peerId, Uint8List bytes);
}
