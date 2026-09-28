import 'package:harness/state/app_state.dart';

/// Exercises guest boot and sign-out without starting or querying a real daemon.
class GuestTestApp extends AppNotifier {
  GuestTestApp({
    required super.config,
    required super.authSession,
    super.configStore,
    super.cliLogin,
    super.environmentProvisioner,
    super.localManualFixture,
  });

  @override
  Future<void> ensureCliDaemonReady() async {}

  @override
  Future<bool> refreshMachines() async => true;
}
