import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'desktop_build.dart';

/// `navigator.userAgentData`: User-Agent Client Hints, which package:web does not declare yet.
extension type _UserAgentData._(JSObject _) implements JSObject {
  external String? get platform;
  external bool? get mobile;
  external JSPromise<_HighEntropyValues> getHighEntropyValues(
    JSArray<JSString> hints,
  );
}

extension type _HighEntropyValues._(JSObject _) implements JSObject {
  external String? get architecture;
  external String? get bitness;
}

extension on web.Navigator {
  external _UserAgentData? get userAgentData;
}

NavigatorSnapshot navigatorSnapshot() {
  final navigator = web.window.navigator;
  final data = navigator.userAgentData;
  return NavigatorSnapshot(
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    maxTouchPoints: navigator.maxTouchPoints,
    hints: data == null
        ? null
        : ClientHints(
            platform: data.platform ?? '',
            mobile: data.mobile ?? false,
            cpu: () async {
              final values = await data
                  .getHighEntropyValues(
                    ['architecture'.toJS, 'bitness'.toJS].toJS,
                  )
                  .toDart;
              return (
                architecture: values.architecture ?? '',
                bitness: values.bitness ?? '',
              );
            },
          ),
  );
}
