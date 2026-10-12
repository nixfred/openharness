import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/relative_time.dart';
import 'account_devices.dart';
import 'app_state.dart';

/// What "Trust again" says when the list it would trust is another account's than the one signed in to.
const otherAccountMessage =
    'The device list now belongs to a different account than the one you signed in with. '
    'Sign in again to switch accounts.';

/// Asks the person one yes/no question: [title], [detail], and the confirming [action]. True only on
/// the confirming button.
typedef DeviceConfirm = Future<bool> Function(
  String title,
  String detail,
  String action,
);

/// The account's devices as the Machines picker lists them: every computer and app signed in to the
/// account. Signing in on one is what makes the others trust it (the device key log), so this is also
/// the one place to see a device that is not yours, and to take it out.
///
/// One per picker visit, read when it opens and again whenever the account's devices change
/// ([AppNotifier.devicesRevision]). Computers are matched to the machines they are by machine id;
/// phones, browsers and a signed-in computer with no machine record are rows of their own.
class MachineDevices extends ChangeNotifier {
  MachineDevices(this.app);

  final AppNotifier app;

  AccountDevices? devices;
  bool loaded = false;

  /// Bumped on every read that lands, so a row built from the last one knows it is stale.
  int stamp = 0;
  int _revision = -1;
  bool _started = false, _disposed = false, _reading = false, _again = false;

  /// Whether the first read marks the devices it shows as seen. True when the person opened
  /// Machines; false when the picker opened on its own (a machine asking to be linked), which nobody
  /// chose to look at.
  bool markSeen = true;
  bool _marked = false;

  /// The devices that were new when the list opened: they keep their `New` mark for the visit, though
  /// opening the list clears the banner that announced them.
  final Set<String> newPubs = {};
  final Set<String> removing = {};
  bool removingUnused = false;
  String? error;

  /// The error is a state to review again (another account, a list that changed), not a failure: amber.
  bool errorIsNotice = false;

  /// "Got it" was pressed on the baseline notice: hidden at once, whatever the write takes.
  bool baselineDone = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    newPubs.addAll(app.newDevices.map((d) => d.pub));
    app.addListener(_appChanged);
    unawaited(load());
  }

  void _appChanged() {
    if (app.devicesRevision != _revision) unawaited(load());
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed) return;
    if (_reading) {
      _again = true;
      return;
    }
    _reading = true;
    _revision = app.devicesRevision;
    List<String>? banner;
    AccountDevices? next;
    var read = false;
    try {
      if (app.accountDevicesReadable) {
        next = await app.loadDevices(onListed: (b) => banner = b);
        read = true;
      }
    } catch (_) {
      next = null;
    }
    _reading = false;
    if (_disposed) return;
    devices = next;
    loaded = true;
    stamp++;
    // What the log kept as new (it outlives the banner and a restart) is marked alongside the
    // banner's — on every read, so a device that turns up while the list is open is marked too.
    if (next != null) newPubs.addAll(next.pending);
    newPubs.addAll(app.newDevices.map((d) => d.pub));
    _changed();
    // Looking at the list IS reviewing the new devices: the banner that pointed here is done. After
    // the first read that answered, so the pending keys are in [newPubs] before they are marked seen.
    if (read && next != null && markSeen && !_marked) {
      _marked = true;
      app.seenNewDevices(
        pending: next.pending,
        shown: banner,
        departed: next.departed,
      );
    }
    if (_again) {
      _again = false;
      unawaited(load());
    }
  }

  AccountDevice? get self => devices?.self;

  /// The account's key for the machine [machineId], when it has one.
  AccountDevice? forMachine(String machineId) {
    if (machineId.isEmpty) return null;
    for (final d in devices?.devices ?? const <AccountDevice>[]) {
      if (d.isMachine && d.machineId == machineId) return d;
    }
    return null;
  }

  AccountDevice? byPub(String pub) {
    for (final d in devices?.devices ?? const <AccountDevice>[]) {
      if (d.pub == pub) return d;
    }
    return null;
  }

  /// Every device the picker lists as a row of its own, in the list's order (new first, then by
  /// activity): phones and browsers, and computers whose id is none of [machineIds] — signed in, but
  /// with no machine record. This device first when it is one of them.
  List<AccountDevice> rows(Set<String> machineIds) {
    final list = devices;
    if (list == null) return const [];
    bool own(AccountDevice d) =>
        !d.isMachine || !machineIds.contains(d.machineId);
    return [
      if (list.self case final self? when own(self)) self,
      for (final d in list.listed(newPubs))
        if (own(d)) d,
    ];
  }

  bool isNew(AccountDevice d) => newPubs.contains(d.pub) || d.pending;

  /// What the row under the device's name says: `App · active now`, `Computer · added 2 days ago`, and
  /// whether it is this one, new or suspended.
  String detail(AccountDevice d, {DateTime? now}) => [
    deviceDetailLine(
      d,
      now: now ?? DateTime.now(),
      sameName: devices?.sharedNames.contains(d.label.trim()) ?? false,
    ),
    if (d.self) 'This device',
    if (d.suspended) 'Suspended' else if (isNew(d)) 'New',
  ].join(' · ');

  List<AccountDevice> unused([DateTime? now]) =>
      devices?.unused(now ?? DateTime.now()) ?? const [];

  /// The "Already on your account" notice is up: the devices that were on the account before this one
  /// joined, which it never announced.
  bool get baselineShowing {
    final list = devices;
    return list != null &&
        !list.baselineSeen &&
        !baselineDone &&
        !app.baselineSeenLocally &&
        list.baseline.isNotEmpty;
  }

  Future<void> gotIt() async {
    baselineDone = true;
    _changed();
    await app.seeDeviceBaseline();
  }

  /// "It's mine" on a device that is new: it stops being announced. A suspension it shows is lifted.
  void mine(AccountDevice d) {
    app.dismissNewDevice(d.pub, liftSuspension: d.suspended);
    newPubs.remove(d.pub);
    _changed();
  }

  void _say(String? message, {bool notice = false}) {
    error = message;
    errorIsNotice = notice;
  }

  /// Signs [d] out of the account on every device. Null when done, else why not.
  Future<String?> remove(AccountDevice d) async {
    final name = d.label.trim().isEmpty ? 'this device' : d.label.trim();
    removing.add(d.pub);
    _say(null);
    _changed();
    String? failure;
    try {
      failure = await app.removeDevice(d.pub);
    } catch (_) {
      failure = 'UNREACHABLE';
    }
    removing.remove(d.pub);
    if (failure != null) _say('Couldn’t remove $name ($failure). Try again.');
    _changed();
    return failure == null ? null : error;
  }

  /// A computer out of the account: signs [device] out when it is known, then deletes the machine
  /// record [machineId]. Null when both are done, else why not. A sign-out that fails stops before the
  /// record is touched.
  Future<String?> removeComputer({
    required String machineId,
    required String name,
    AccountDevice? device,
  }) async {
    if (device != null) {
      removing.add(device.pub);
      _changed();
      String? failure;
      try {
        failure = await app.removeDevice(device.pub);
      } catch (_) {
        failure = 'UNREACHABLE';
      }
      removing.remove(device.pub);
      _changed();
      if (failure != null) {
        return 'Couldn’t sign $name out ($failure). Try again.';
      }
    }
    final failure = await app.deleteMachine(machineId);
    if (failure == null) return null;
    return device == null
        ? failure
        : '$name is signed out, but its machine record could not be deleted ($failure). Try again.';
  }

  /// Signs out every app unused for 90 days, after [confirm].
  Future<void> removeUnused(DeviceConfirm confirm) async {
    final list = unused();
    if (list.isEmpty || removingUnused) return;
    final confirmed = await confirm(
      'Remove ${list.length} unused app${list.length == 1 ? '' : 's'}?',
      [
        for (final d in list)
          '${d.label.isEmpty ? 'Unnamed app' : d.label} — last active ${relativeAgo(d.lastSeen!, DateTime.now())}',
      ].join('\n'),
      'Remove',
    );
    if (!confirmed || _disposed) return;
    removingUnused = true;
    _say(null);
    _changed();
    final failed = <String>[];
    for (final d in list) {
      String? failure;
      try {
        failure = await app.removeDevice(d.pub);
      } catch (_) {
        failure = 'UNREACHABLE';
      }
      if (failure != null) failed.add(d.label.isEmpty ? 'an app' : d.label);
    }
    removingUnused = false;
    _say(
      failed.isEmpty
          ? null
          : 'Couldn’t remove ${failed.join(', ')}. Try again.',
    );
    _changed();
  }

  /// Trusts the device list the account serves again, after the person reviews what it changes — the
  /// one way out of a frozen list.
  Future<void> trustAgain(DeviceConfirm confirm) async {
    final preview = await app.rebaselineDevices(confirm: false);
    if (_disposed) return;
    if (preview == null) {
      _say('Couldn’t read a valid device list. Try again later.');
      _changed();
      return;
    }
    if (preview.otherAccount) {
      _say(otherAccountMessage, notice: true);
      _changed();
      return;
    }
    final lines = [
      for (final name in preview.added) '+ $name',
      for (final name in preview.removed) '− $name',
    ];
    final confirmed = await confirm(
      'Trust this device list again?',
      lines.isEmpty
          ? 'It changes no device. Continue only if you expected this.'
          : 'Only if every device added below is yours:\n\n${lines.join('\n')}',
      'Trust again',
    );
    if (!confirmed || _disposed) return;
    final done = await app.rebaselineDevices(confirm: true, head: preview.head);
    if (_disposed) return;
    if (done == null) {
      _say('Couldn’t trust the device list again. Try again later.');
    } else if (done.otherAccount) {
      _say(otherAccountMessage, notice: true);
    } else if (!done.logChanged) {
      _say(null);
    } else {
      // What was reviewed is no longer what the account serves: nothing was trusted. Show it again.
      _say(
        'The device list changed while you were reviewing it. Review it again.',
        notice: true,
      );
      _changed();
      await trustAgain(confirm);
      return;
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) app.removeListener(_appChanged);
    super.dispose();
  }
}
