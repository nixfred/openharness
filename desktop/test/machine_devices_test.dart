// The account's devices as Machines lists them (state/machine_devices.dart): opening the list is
// reviewing the devices the banner announced, the rows' order and marks, and the acts on the list —
// Remove, Remove unused apps, Got it, Trust again. Moved with the list from Settings ▸ Your devices.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/state/account_devices.dart';
import 'package:harness/state/machine_devices.dart';
import 'package:harness/viewer/device_log.dart' show DevLogHead;
import 'package:harness/viewer/device_log_sync.dart' show DeviceLogRebaseline;

import 'support/devices_app.dart';

/// A confirm that answers [answer] and records what it was asked.
class _Confirm {
  _Confirm([this.answer = true]);
  bool answer;
  final asked = <(String, String, String)>[];
  Future<bool> call(String title, String detail, String action) async {
    asked.add((title, detail, action));
    return answer;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('the daemon\'s OTHER_ACCOUNT answer and the viewer\'s are a refusal of another account\'s list', () {
    final daemon = DevicesRebaseline.fromDaemon({'error': 'OTHER_ACCOUNT'})!;
    expect(
      [daemon.otherAccount, daemon.logChanged, daemon.refused],
      [true, false, true],
    );
    expect(
      DevicesRebaseline.fromDaemon({'error': 'LOG_CHANGED'})!.otherAccount,
      isFalse,
    );
    final viewer = DevicesRebaseline.fromViewer(
      const DeviceLogRebaseline.otherAccount(),
    );
    expect(
      [viewer.otherAccount, viewer.logChanged, viewer.head],
      [true, false, null],
    );
  });

  test('a listing carries its departed keys, from the daemon and from the viewer alike', () {
    final fromDaemon = AccountDevices.fromDaemon({
      'members': <Object>[],
      'pending': <Object>[],
      'departed': [
        {
          'pub': 'gone',
          'label': 'Phone',
          'kind': 'viewer',
          'machineId': '',
          'fingerprint': 'AAAA',
          'addedAt': 1,
          'removedAt': 2,
          'removedBy': 'gone',
          'removedByLabel': 'Phone',
          'selfRemoved': true,
        },
      ],
    })!;
    expect(fromDaemon.departed, ['gone']);
    expect(
      AccountDevices.fromDaemon({'members': <Object>[], 'pending': <Object>[]})!
          .departed,
      isEmpty,
    );
    expect(fromDaemon.withLastSeen(const {}).departed, ['gone']);
  });

  group('the list', () {
    final now = DateTime.now();
    late FakeDevicesApp app;
    late MachineDevices devices;

    setUp(() {
      app = FakeDevicesApp()
        ..devices = AccountDevices(
          devices: [
            fakeDevice(
              'old',
              label: 'Old laptop',
              kind: 'machine',
              added: now.subtract(const Duration(days: 300)),
              seen: now.subtract(const Duration(days: 40)),
              fingerprint: 'AAAA·0001·0001·0001',
            ),
            fakeDevice(
              'me',
              label: 'Studio Mac',
              kind: 'machine',
              self: true,
              added: now.subtract(const Duration(days: 200)),
              seen: now,
              fingerprint: 'E2FB·0DF5·5FD8·E6C7',
            ),
            fakeDevice(
              'phone-a',
              label: 'Test iPhone',
              added: now.subtract(const Duration(days: 100)),
              seen: now.subtract(const Duration(minutes: 2)),
              fingerprint: 'BBBB·0002·0002·0002',
            ),
            fakeDevice(
              'phone-b',
              label: 'Test iPhone',
              added: now.subtract(const Duration(days: 50)),
              fingerprint: 'CCCC·0003·0003·0003',
            ),
            fakeDevice(
              'new',
              label: 'Test iPad',
              added: now.subtract(const Duration(hours: 3)),
              fingerprint: 'EEEE·0005·0005·0005',
            ),
          ],
        );
      app.newDevices.add(
        const NewDeviceNotice(pub: 'new', label: 'Test iPad', kind: 'viewer'),
      );
      devices = MachineDevices(app);
    });
    tearDown(() {
      devices.dispose();
      app.dispose();
    });

    Future<void> open([AccountDevices? list]) async {
      if (list != null) app.devices = list;
      devices.start();
      await _settle();
    }

    test('opening the list takes the new-device banner down', () async {
      await open();
      expect(app.newDevices, isEmpty);
      expect(app.seenPending, hasLength(1));
    });

    test('rows: new first, then by activity; this device is a machine row, not a device row', () async {
      await open();
      // `old` and `me` are machines with machine records; the rest are rows of their own.
      expect(devices.rows({'abcdef0123456789'}).map((d) => d.pub), [
        'new',
        'phone-a',
        'phone-b',
      ]);
      // With no machine record, a computer is a row of its own too.
      expect(devices.rows({}).map((d) => d.pub), [
        'me',
        'new',
        'phone-a',
        'old',
        'phone-b',
      ]);
      final phone = devices.byPub('phone-a')!;
      // Two devices go by one name: the start of the code tells them apart.
      expect(devices.detail(phone), 'App · active now · BBBB…');
      expect(devices.detail(devices.byPub('new')!), endsWith('New'));
      expect(devices.detail(devices.byPub('me')!), contains('This device'));
    });

    test('a device the daemon kept as pending is New though no banner is up, and so is one that turns up later', () async {
      app.newDevices.clear();
      await open(
        AccountDevices(
          devices: [fakeDevice('me', self: true), fakeDevice('kept')],
          pending: const ['kept'],
        ),
      );
      expect(devices.isNew(devices.byPub('kept')!), isTrue);
      app.devices = AccountDevices(
        devices: [
          fakeDevice('me', self: true),
          fakeDevice('kept'),
          fakeDevice('late'),
        ],
        pending: const ['kept', 'late'],
      );
      app.devicesRevision++;
      app.notifyListeners();
      await _settle();
      expect(devices.isNew(devices.byPub('late')!), isTrue);
    });

    test('a suspended device is marked Suspended instead of New', () async {
      await open(
        AccountDevices(
          devices: [
            fakeDevice('me', self: true),
            fakeDevice('fork', label: 'Forked', suspended: true, pending: true),
          ],
        ),
      );
      final detail = devices.detail(devices.byPub('fork')!);
      expect(detail, endsWith('Suspended'));
      expect(detail, isNot(contains('New')));
    });

    test(
      'the baseline names what was there before; Got it hides it and persists',
      () async {
        await open(
          AccountDevices(
            devices: [fakeDevice('me', self: true), fakeDevice('before')],
            baselineSeen: false,
            baselineKeys: const ['before'],
          ),
        );
        expect(devices.baselineShowing, isTrue);
        await devices.gotIt();
        expect(devices.baselineShowing, isFalse);
        expect(app.baselineSeenCalls, 1);
      },
    );

    test('no baseline once seen', () async {
      await open(
        AccountDevices(
          devices: [fakeDevice('me', self: true), fakeDevice('before')],
          baselineKeys: const ['before'],
        ),
      );
      expect(devices.baselineShowing, isFalse);
    });

    test('Trust again confirms the previewed head; a list that changed meanwhile is previewed again', () async {
      await open(
        AccountDevices(
          devices: [fakeDevice('me', self: true)],
          frozenReason: 'fork',
        ),
      );
      app.previews
        ..add(
          const DevicesRebaseline(
            added: ['iPad'],
            removed: [],
            head: DevLogHead(7, 'h7'),
          ),
        )
        ..add(
          const DevicesRebaseline(
            added: ['iPad', 'Mac'],
            removed: [],
            head: DevLogHead(8, 'h8'),
          ),
        );
      app.confirmAnswer = const DevicesRebaseline.changed();
      final confirm = _Confirm();
      var calls = 0;
      await devices.trustAgain((title, detail, action) {
        // The second preview is answered No, so this ends.
        confirm.answer = ++calls == 1;
        return confirm(title, detail, action);
      });
      expect(app.confirmedHeads.single?.seq, 7);
      expect(confirm.asked, hasLength(2));
      expect(confirm.asked.last.$2, contains('+ Mac'));
      expect(
        devices.error,
        'The device list changed while you were reviewing it. Review it again.',
      );
      expect(devices.errorIsNotice, isTrue);
    });

    test(
      'another account\'s list: at the preview, nothing to confirm',
      () async {
        await open(
          AccountDevices(
            devices: [fakeDevice('me', self: true)],
            frozenReason: 'invalid',
          ),
        );
        app.previews.add(const DevicesRebaseline.otherAccount());
        final confirm = _Confirm();
        await devices.trustAgain(confirm.call);
        expect(confirm.asked, isEmpty);
        expect(devices.error, otherAccountMessage);
        expect(devices.errorIsNotice, isTrue);
        expect(app.confirmedHeads, isEmpty);
      },
    );

    test(
      'another account\'s list at the confirm: said once, not previewed again',
      () async {
        await open(
          AccountDevices(
            devices: [fakeDevice('me', self: true)],
            frozenReason: 'invalid',
          ),
        );
        app.previews.add(
          const DevicesRebaseline(
            added: [],
            removed: [],
            head: DevLogHead(7, 'h7'),
          ),
        );
        app.confirmAnswer = const DevicesRebaseline.otherAccount();
        final confirm = _Confirm();
        await devices.trustAgain(confirm.call);
        expect(confirm.asked, hasLength(1));
        expect(devices.error, otherAccountMessage);
        expect(app.confirmedHeads, hasLength(1));
      },
    );

    test('failures: an unreadable list, a refused trust and a failed remove are errors, not notices', () async {
      await open(
        AccountDevices(
          devices: [fakeDevice('me', self: true), fakeDevice('b')],
          frozenReason: 'fork',
        ),
      );
      await devices.trustAgain(_Confirm().call);
      expect(
        devices.error,
        'Couldn’t read a valid device list. Try again later.',
      );
      expect(devices.errorIsNotice, isFalse);
      app.previews.add(
        const DevicesRebaseline(
          added: ['iPad'],
          removed: [],
          head: DevLogHead(7, 'h7'),
        ),
      );
      app.confirmAnswer = null;
      await devices.trustAgain(_Confirm().call);
      expect(
        devices.error,
        'Couldn’t trust the device list again. Try again later.',
      );
      app.removeError = 'UNAVAILABLE';
      await devices.remove(devices.byPub('b')!);
      expect(devices.error, 'Couldn’t remove iPad (UNAVAILABLE). Try again.');
      expect(devices.errorIsNotice, isFalse);
      // A later success clears the message.
      app.removeError = null;
      app.previews.add(
        const DevicesRebaseline(
          added: [],
          removed: [],
          head: DevLogHead(7, 'h7'),
        ),
      );
      app.confirmAnswer = const DevicesRebaseline(
        added: [],
        removed: [],
        head: DevLogHead(7, 'h7'),
      );
      await devices.trustAgain(_Confirm().call);
      expect(devices.error, isNull);
    });

    test(
      'opening marks seen only the banner as it was when the list was read',
      () async {
        final gate = Completer<void>();
        app.devices = AccountDevices(devices: [fakeDevice('me', self: true)]);
        app.newDevices
          ..clear()
          ..add(const NewDeviceNotice(pub: 'new', label: 'N', kind: 'viewer'));
        app.loadGate = gate;
        app.bannerAtRead = () => ['new'];
        devices.start();
        await _settle();
        app.newDevices.add(
          const NewDeviceNotice(pub: 'late', label: 'L', kind: 'viewer'),
        );
        gate.complete();
        await _settle();
        expect(app.seenShown.single, ['new']);
        expect(app.newDevices.map((d) => d.pub), ['late']);
      },
    );

    test('the departed keys the listing read are handed over', () async {
      await open(
        AccountDevices(
          devices: [fakeDevice('me', self: true)],
          departed: const ['gone'],
        ),
      );
      expect(app.seenDeparted.single, ['gone']);
    });

    test(
      'apps unused for 90 days are removed together, after asking',
      () async {
        await open(
          AccountDevices(
            devices: [
              fakeDevice('me', self: true),
              fakeDevice(
                'stale',
                label: 'Old browser',
                seen: now.subtract(const Duration(days: 120)),
              ),
              fakeDevice(
                'stale-pc',
                label: 'Old computer',
                kind: 'machine',
                seen: now.subtract(const Duration(days: 120)),
              ),
            ],
          ),
        );
        // Never a computer: its absence is plain in the machine list.
        expect(devices.unused().map((d) => d.pub), ['stale']);
        final confirm = _Confirm(false);
        await devices.removeUnused(confirm.call);
        expect(app.removed, isEmpty);
        confirm.answer = true;
        await devices.removeUnused(confirm.call);
        expect(confirm.asked.last.$1, 'Remove 1 unused app?');
        expect(app.removed, ['stale']);
      },
    );

    test(
      'a computer is signed out first; a record that cannot be deleted says so',
      () async {
        await open();
        final remote = devices.byPub('old')!;
        final failure = await devices.removeComputer(
          machineId: 'abcdef0123456789',
          name: 'Old laptop',
          device: remote,
        );
        // FakeDevicesApp has no machine record to delete: the base app says so.
        expect(app.removed, ['old']);
        expect(failure, contains('Old laptop is signed out'));
      },
    );

    test('a refused sign-out leaves the machine record alone', () async {
      await open();
      app.removeError = 'OFFLINE';
      final failure = await devices.removeComputer(
        machineId: 'abcdef0123456789',
        name: 'Old laptop',
        device: devices.byPub('old')!,
      );
      expect(failure, 'Couldn’t sign Old laptop out (OFFLINE). Try again.');
    });
  });
}
