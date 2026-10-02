import 'dart:async';
import 'dart:typed_data';

import 'package:harness_mobile/auth/auth_session.dart';
import 'package:harness_mobile/core/config.dart';
import 'package:harness_mobile/e2ee/bytes.dart';
import 'package:harness_mobile/e2ee/keys.dart' as keys;
import 'package:harness_mobile/state/app_state.dart';
import 'package:harness_mobile/viewer/device_log.dart';
import 'package:harness_mobile/viewer/device_log_sync.dart';

/// A 32-byte key, distinct per [n], base64 — what a device log carries as `pub`.
String pubOf(int n) =>
    b64e(Uint8List.fromList(List.generate(32, (i) => (i * 7 + n) & 0xff)));

/// The key code the app shows for [pub].
String fpOf(String pub) => keys.fingerprint(b64d(pub));

DevLogMember member(
  String pub, {
  String label = 'Device',
  String kind = 'viewer',
  String machineId = '',
  required int addedAt,
  int seq = 1,
}) => DevLogMember(
  pub: pub,
  kind: kind,
  machineId: machineId,
  label: label,
  addedAt: addedAt,
  seq: seq,
);

DeviceLogRow row(DevLogMember m, {bool self = false}) =>
    DeviceLogRow(m, fingerprint: fpOf(m.pub), self: self);

/// An app whose device list, last-seen times and removal are canned, so a page test is about what the
/// page does with them.
class DevicesApp extends AppNotifier {
  DevicesApp({this.rows = const [], this.seen = const {}})
    : super(
        config: AppConfig.dev,
        authSession: AuthSession(),
        configStore: null,
      );

  List<DeviceLogRow> rows;
  Map<String, int> seen;

  /// What [removeDevice] answers: null is done, else why not.
  String? removeError;
  final removed = <String>[];

  /// When set, a removal waits on it — to see the page while the removal is in flight.
  Completer<void>? removeGate;

  @override
  Future<DeviceLogListing> deviceListing() async =>
      DeviceLogListing(members: rows, frozen: null, frozenPeers: const []);

  @override
  Future<Map<String, int>> devicesLastSeen() async => seen;

  @override
  Future<String?> removeDevice(String pub) async {
    removed.add(pub);
    await removeGate?.future;
    if (removeError == null) {
      rows = [
        for (final r in rows)
          if (r.member.pub != pub) r,
      ];
      newDevices.removeWhere((d) => d.pub == pub);
    }
    devicesRevision++;
    notifyListeners();
    return removeError;
  }
}
