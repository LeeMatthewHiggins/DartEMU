import 'dart:typed_data';

import 'package:dart_emu/src/net/ethernet_frame.dart';
import 'package:dart_emu/src/net/net_const.dart';

/// Handles ARP requests on the virtual network.
///
/// Responds to any ARP request for an IP on the 10.0.2.x subnet
/// with the gateway MAC address.
class ArpHandler {
  const ArpHandler({
    required this.gatewayMac,
    required this.gatewayIp,
  });

  final Uint8List gatewayMac;
  final Uint8List gatewayIp;

  /// Processes an ARP packet and returns a reply frame, or `null`.
  Uint8List? handlePacket(EthernetFrame frame) {
    final data = frame.payload;
    if (data.length < ArpConst.packetSize) return null;
    final view = ByteData.sublistView(data);
    if (view.getUint16(0) != ArpConst.hardwareTypeEthernet) {
      return null;
    }
    if (view.getUint16(_protocolTypeOffset) != ArpConst.protocolTypeIpv4) {
      return null;
    }
    if (view.getUint16(_operationOffset) != ArpOp.request) return null;

    final reply = Uint8List(ArpConst.packetSize)
      ..[_hwSizeOffset] = ArpConst.hardwareSize
      ..[_protoSizeOffset] = ArpConst.protocolSize
      // Sender = gateway
      ..setRange(
        _senderMacOffset,
        _senderMacOffset + ArpConst.hardwareSize,
        gatewayMac,
      )
      ..setRange(
        _senderIpOffset,
        _senderIpOffset + ArpConst.protocolSize,
        Uint8List.sublistView(
          data,
          _targetIpOffset,
          _targetIpOffset + ArpConst.protocolSize,
        ),
      )
      // Target = original sender
      ..setRange(
        _targetMacOffset,
        _targetMacOffset + ArpConst.hardwareSize,
        Uint8List.sublistView(
          data,
          _senderMacOffset,
          _senderMacOffset + ArpConst.hardwareSize,
        ),
      )
      ..setRange(
        _targetIpOffset,
        _targetIpOffset + ArpConst.protocolSize,
        Uint8List.sublistView(
          data,
          _senderIpOffset,
          _senderIpOffset + ArpConst.protocolSize,
        ),
      );
    ByteData.sublistView(reply)
      ..setUint16(0, ArpConst.hardwareTypeEthernet)
      ..setUint16(_protocolTypeOffset, ArpConst.protocolTypeIpv4)
      ..setUint16(_operationOffset, ArpOp.reply);

    return EthernetFrame(
      destinationMac: frame.sourceMac,
      sourceMac: gatewayMac,
      etherType: EtherType.arp,
      payload: reply,
    ).encode();
  }

  static const _protocolTypeOffset = 2;
  static const _hwSizeOffset = 4;
  static const _protoSizeOffset = 5;
  static const _operationOffset = 6;
  static const _senderMacOffset = 8;
  static const _senderIpOffset = 14;
  static const _targetMacOffset = 18;
  static const _targetIpOffset = 24;
}
