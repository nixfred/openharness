import 'dart:async';

import 'package:harness/auth/auth_session.dart';
import 'package:harness/core/config.dart';
import 'package:harness/state/account_devices.dart';
import 'package:harness/state/app_state.dart';

const fakeFingerprint = 'E2FB·0DF5·5FD8·E6C7';

/// An app whose account device list and removal are canned, so the Devices screens' own code runs
/// unmodified with no daemon.
class FakeDevicesApp extends AppNotifier {
  FakeDevicesApp()
    : super(
        config: AppConfig.dev,
        authSession: AuthSession(),
        configStore: null,
      );

  AccountDevices? devices;
  Completer<void>? loadGate;
  Object? loadError;
  String? removeError;
  final removed = <String>[];
  int loads = 0;

  @override
  Future<AccountDevices?> loadDevices() async {
    loads++;
    await loadGate?.future;
    if (loadError case final error?) throw error;
    return devices;
  }

  @override
  Future<String?> removeDevice(String pub) async {
    removed.add(pub);
    if (removeError == null) {
      newDevices.removeWhere((d) => d.pub == pub);
      devices = AccountDevices(
        devices: [
          for (final d in devices?.devices ?? const <AccountDevice>[])
            if (d.pub != pub) d,
        ],
      );
    }
    devicesRevision++;
    notifyListeners();
    return removeError;
  }
}

AccountDevice fakeDevice(
  String pub, {
  String label = 'iPad',
  String kind = 'viewer',
  bool self = false,
  DateTime? added,
  DateTime? seen,
  String fingerprint = fakeFingerprint,
}) => AccountDevice(
  pub: pub,
  label: label,
  kind: kind,
  machineId: kind == 'machine' ? 'abcdef0123456789' : '',
  addedAt: added ?? DateTime(2026, 9, 1, 9, 30),
  fingerprint: fingerprint,
  self: self,
  lastSeen: seen,
);
