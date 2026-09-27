import 'support/open_harness.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/screens/swarm_screen.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/shortcuts/app_keymap.dart';
import 'package:harness/state/session_content_search.dart';
import 'package:harness/state/swarm_catalog.dart';
import 'package:harness/state/swarm_navigation.dart';
import 'package:harness/widgets/swarm_switcher.dart';

import 'keymap_host_test.dart' show MemoryKeymap;
import 'session_content_search_test.dart' show SearchConnection;
import 'swarm_state_test.dart' show createApp;

void main() {
  testWidgets(
    'a harness found by what was said in it shows where, in place of its context',
    (tester) async {
      final connection = SearchConnection({
        'retention cohorts': [
          {
            'agentId': 'a7',
            'sessionId': 's7',
            'field': 'ask',
            'snippet':
                'compare ${kSnippetMarkOpen}retention$kSnippetMarkClose by '
                '$kSnippetMarkOpen${'cohort'}$kSnippetMarkClose',
            'together': true,
            'score': .9,
          },
        ],
      });
      final app = createApp(
        connected: true,
        connectionForTest: (_) => connection,
      );
      final map = MemoryKeymap();
      final projects = SwarmProjectStore();
      addTearDown(map.dispose);
      addTearDown(projects.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: grid.buildAppTheme(brightness: Brightness.dark),
          builder: (_, child) => grid.BrightnessScope(
            child: KeymapProvider(keymap: map, child: child!),
          ),
          home: SwarmScreen(
            notifier: app,
            nativeTabs: false,
            projectStore: projects,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await openHarnessPicker(tester);
      await tester.enterText(
        find.byKey(const ValueKey('swarm-search-input')),
        'retention cohorts',
      );
      // Past the pause-in-typing debounce, then the reply.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 50));
      final search = tester
          .widget<SwarmSearchResults>(find.byType(SwarmSearchResults))
          .search;
      expect(search.selected!.agentId, 'a7');
      final snippet = find.byKey(
        ValueKey('session-snippet:${agentDestinationId('m', 'a7')}'),
      );
      expect(snippet, findsOneWidget);
      expect(
        tester.widget<Text>(snippet).textSpan!.toPlainText(),
        '> compare retention by cohort',
      );
      final found = find.byKey(
        ValueKey('preview-found:${agentDestinationId('m', 'a7')}'),
      );
      expect(found, findsOneWidget);
      final foundText = find.descendant(of: found, matching: find.byType(Text));
      expect(
        tester.widget<Text>(foundText).textSpan!.toPlainText(),
        '> compare retention by cohort',
      );
      expect(tester.widget<Text>(foundText).maxLines, isNull);
      expect(find.text('Found in what you asked'), findsOneWidget);
      app.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
