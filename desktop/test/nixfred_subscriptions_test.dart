import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/nixfred/subscriptions/subscriptions_model.dart';
import 'package:harness/nixfred/subscriptions/subscriptions_section.dart';

Map<String, Object?> card(String id, {String state = 'ok', double used = 0.3, double banked = 0.2, String tone = 'banked', bool pick = false, bool enabled = true}) => {
      'id': id,
      'name': id[0].toUpperCase() + id.substring(1),
      'state': state,
      'enabled': enabled,
      'plan': 'Pro',
      'snapshot': false,
      'status': '',
      'help': '',
      'isPick': pick,
      'blocked': false,
      'primary': state != 'ok'
          ? null
          : {
              'label': 'Weekly (7-day)',
              'used': used,
              'resetsInMs': 3 * 86400000,
              'windowMs': 7 * 86400000,
              'elapsed': used + banked,
              'bankedSigned': banked,
              'bankedMs': banked * 7 * 86400000,
              'comeBackMs': banked < 0 ? 3600000 : 0,
              'spent': false,
              'over': banked < -0.01,
              'tone': tone,
              'sentence': 'On pace. Resets in 3d.',
              'pace': {
                'series': [
                  [0.1, 0.05],
                  [0.5, used],
                ],
              },
            },
    };

final payload = {
  'at': 1,
  'guide': {'verdict': 'Use Grok next.', 'pick': 'grok', 'urgent': false},
  'subs': [
    card('claude'),
    card('codex', used: 0.16, banked: -0.1, tone: 'red'),
    card('grok', used: 0.03, banked: 0.8, pick: true),
    card('kimi', state: 'not-detected'),
  ],
};

class FakeSource implements SubscriptionsSource {
  final toggles = <String>[];
  @override
  Future<SubsPayload> fetch() async => SubsPayload.fromJson(payload);
  @override
  Future<void> setEnabled(String id, bool on) async => toggles.add('$id:$on');
}

void main() {
  test('parses the daemon payload and ignores junk', () {
    final p = SubsPayload.fromJson(payload);
    expect(p.subs.map((s) => s.id), ['claude', 'codex', 'grok', 'kimi']);
    expect(p.subs[1].primary!.tone, SubTone.red);
    expect(p.subs[2].isPick, isTrue);
    expect(p.subs[3].detected, isFalse);
    expect(p.subs[0].primary!.series.length, 2);
    expect(SubsPayload.fromJson('nope').subs, isEmpty);
    expect(SubsPayload.fromJson({'subs': [1, null, {'id': ''}]}).subs, isEmpty);
  });

  test('labels and clocks read like Burn Bar', () {
    expect(bankedLabel(0.063), '+6% banked');
    expect(bankedLabel(-0.098), '10% over pace');
    expect(bankedLabel(0.001), 'on pace');
    expect(spanWords(3 * 86400000 + 10 * 3600000 + 22 * 60000), '3d 10h');
    expect(spanWords(20000), 'under a minute');
    expect(clockSpan(7 * 3600000 + 13 * 60000 + 22000), '7:13:22');
    expect(clockSpan(-5), '0:00');
  });

  for (final size in [const Size(1400, 820), const Size(900, 760), const Size(520, 1100)]) {
    testWidgets('all four cards fit without a scroll view at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = FakeSource();
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: true),
          child: Scaffold(body: SubscriptionsSection(source: source)),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Use Grok next.'), findsOneWidget);
      expect(find.text('USE NEXT'), findsOneWidget);
      expect(find.text('Not detected'), findsOneWidget);
      expect(find.text('10% over pace'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(source.toggles, ['claude:false']);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
