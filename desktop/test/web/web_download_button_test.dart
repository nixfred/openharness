@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/widgets/web_download_button.dart';

void main() {
  testWidgets('a click opens the download page through the new-tab opener', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: WebDownloadButton(
            open: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(WebDownloadButton));
    await tester.pump();
    expect(opened, [WebDownloadButton.uri]);
    // The default opener is the new-tab one, not a same-tab navigation.
    expect(const WebDownloadButton().open, openInNewTab);
  });
}
