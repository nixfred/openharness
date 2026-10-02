import 'package:flutter_test/flutter_test.dart';
import 'package:harness/e2ee/bytes.dart';
import 'package:harness/e2ee/keys.dart' as keys;
import 'package:harness/state/account_devices.dart';

/// The Devices list's model (`lib/state/account_devices.dart`): what a daemon answers, and which apps
/// it offers to remove as unused.
void main() {
  final now = DateTime(2026, 10, 1);
  Map<String, Object?> row(String pub, {String kind = 'viewer', bool self = false}) => {
    'pub': pub, 'label': pub, 'kind': kind, 'machineId': kind == 'machine' ? 'a' * 32 : '',
    'addedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch, 'fingerprint': 'FP', 'self': self,
  };

  test('reads a daemon listing with its frozen state and when each key was last seen', () {
    final devices = AccountDevices.fromDaemon({
      'members': [row('old'), row('me', self: true), row('box', kind: 'machine'), {'bad': true}],
      'frozen': {'reason': 'fork'},
      'frozenPeers': ['box2'],
      'lastSeen': {'old': DateTime(2026, 5, 1).millisecondsSinceEpoch, 'junk': 'x'},
    })!;
    expect(devices.devices.map((d) => d.pub), ['old', 'me', 'box']);
    expect(devices.frozenReason, 'fork');
    expect(devices.frozen, isTrue);
    expect(devices.devices.first.lastSeen, DateTime(2026, 5, 1));
    expect(devices.devices[1].lastSeen, isNull);
  });

  test('a daemon row carrying seq and firstSeen (newer daemons) reads the same as one without', () {
    final devices = AccountDevices.fromDaemon({
      'members': [
        {...row('new'), 'seq': 3, 'firstSeen': DateTime(2026, 9, 30).millisecondsSinceEpoch},
        {...row('me', self: true), 'seq': 2},
      ],
    })!;
    expect(devices.devices.map((d) => d.pub), ['new', 'me']);
    expect(devices.devices.first.fingerprint, 'FP');
    expect(devices.devices.last.self, isTrue);
  });

  test('offers only apps seen long ago — never this one, a computer, or one never recorded', () {
    final long = DateTime(2026, 5, 1).millisecondsSinceEpoch;
    final devices = AccountDevices.fromDaemon({
      'members': [
        row('stale'), row('fresh'), row('never'), row('me', self: true), row('box', kind: 'machine'),
      ],
      'lastSeen': {
        'stale': long, 'me': long, 'box': long,
        'fresh': DateTime(2026, 9, 20).millisecondsSinceEpoch,
      },
    })!;
    expect(devices.unused(now).map((d) => d.pub), ['stale']);
  });
  AccountDevice device(String pub, {String? label, String kind = 'viewer', bool self = false, DateTime? added, DateTime? seen, String fp = 'E2FB·0DF5·5FD8·E6C7'}) => AccountDevice(
    pub: pub, label: label ?? pub, kind: kind, machineId: kind == 'machine' ? 'abcdef0123456789' : '',
    addedAt: added ?? DateTime(2026, 1, 1), fingerprint: fp, self: self, lastSeen: seen,
  );

  test('lists this device apart, then the new ones newest first, then the rest by last activity', () {
    final devices = AccountDevices(devices: [
      device('old-a', added: DateTime(2026, 2, 1)),
      device('me', self: true, seen: now),
      device('new-1', added: DateTime(2026, 9, 28)),
      device('busy', added: DateTime(2025, 1, 1), seen: DateTime(2026, 9, 30)),
      device('new-2', added: DateTime(2026, 9, 30)),
      device('old-b', added: DateTime(2026, 2, 1)),
      // In the new set but added long ago: new devices sort by when they were added, not by activity.
      device('new-old', added: DateTime(2025, 6, 1), seen: now),
    ]);
    expect(devices.self?.pub, 'me');
    expect(devices.listed({'new-1', 'new-2', 'new-old'}).map((d) => d.pub),
        ['new-2', 'new-1', 'new-old', 'busy', 'old-a', 'old-b']);
    // Nothing new: activity alone; equal times keep the log's order, whatever the sort does.
    expect(devices.listed({}).map((d) => d.pub), ['new-old', 'busy', 'new-2', 'new-1', 'old-a', 'old-b']);
    expect(const AccountDevices(devices: []).self, isNull);
  });

  test('a name shared by two devices (this one included, blank names alike) is a shared name', () {
    final devices = AccountDevices(devices: [
      device('a', label: 'iPhone '), device('b', label: 'iPhone'), device('c', label: 'box'),
      device('d', label: ''), device('e', label: '  '),
      // This device counts: its card shows its name, so a row going by the same name needs telling apart.
      device('me', label: 'MacBook', self: true), device('f', label: 'MacBook'),
    ]);
    expect(devices.sharedNames, {'iPhone', '', 'MacBook'});
  });

  test('a row says what and when, with only the start of the key code when its name is shared', () {
    final app = device('a', seen: now.subtract(const Duration(days: 2)));
    expect(deviceDetailLine(app, now: now, sameName: false), 'App · last active 2 days ago');
    expect(deviceDetailLine(app, now: now, sameName: true), 'App · last active 2 days ago · E2FB…');
    final box = device('b', kind: 'machine', seen: now.subtract(const Duration(minutes: 4)));
    expect(deviceDetailLine(box, now: now, sameName: false), 'Computer · active now');
    final quiet = device('c', added: now.subtract(const Duration(days: 21)));
    expect(deviceDetailLine(quiet, now: now, sameName: false), 'App · added 3 weeks ago');
    for (final line in [deviceDetailLine(app, now: now, sameName: true), deviceDetailLine(box, now: now, sameName: true)]) {
      expect(line, isNot(contains('0DF5')));
      expect(line, isNot(matches(RegExp(r'\d{4}-\d{2}-\d{2}'))));
    }
  });

  test('a notice shows the key code the frame carried, else the one its key works out to', () {
    final pub = b64e(List<int>.generate(32, (i) => i * 7 % 256));
    expect(const NewDeviceNotice(pub: 'x', label: 'iPad', kind: 'viewer', frameFingerprint: 'AAAA·BBBB·CCCC·DDDD').fingerprint,
        'AAAA·BBBB·CCCC·DDDD');
    final computed = NewDeviceNotice(pub: pub, label: 'iPad', kind: 'viewer').fingerprint;
    expect(computed, keys.fingerprint(b64d(pub)));
    expect(computed, matches(RegExp(r'^[0-9A-F]{4}(·[0-9A-F]{4}){3}$')));
    expect(NewDeviceNotice(pub: pub, label: 'iPad', kind: 'viewer', frameFingerprint: '').fingerprint, computed);
    expect(const NewDeviceNotice(pub: '%%not base64%%', label: '', kind: 'viewer').fingerprint, '');
  });
}
