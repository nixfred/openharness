import 'dart:async';

import 'desktop_build.dart';
import 'navigator_snapshot_native.dart'
    if (dart.library.js_interop) 'navigator_snapshot_web.dart';

/// The download link for this browser, detected once per page load.
///
/// Client Hints answer asynchronously, but the click has to open its tab at once: a tab opened after
/// an await is outside the user's gesture, and browsers block it as a popup. So detection starts the
/// first time the link is read (a Download app button's first build) and the click takes the best
/// answer so far — the user agent's, until the hints arrive moments later.
abstract final class DesktopDownload {
  static Future<void>? _detecting;
  static DesktopBuild? _detected;
  static var _done = false;

  /// Starts detection if nothing has; completes when it has answered.
  static Future<void> warm() =>
      _detecting ??= detectDesktopBuild(navigatorSnapshot()).then(_settle);

  static void _settle(DesktopBuild? build) {
    _detected = build;
    _done = true;
  }

  static Uri get uri {
    unawaited(warm());
    return desktopDownloadUri(
      _done ? _detected : buildFromUserAgent(navigatorSnapshot()),
    );
  }
}
