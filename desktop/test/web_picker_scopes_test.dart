import 'package:flutter_test/flutter_test.dart';
import 'package:harness/web/picker/web_picker_scopes.dart';

void main() {
  test('a scope click types what its prefix key would', () {
    final queries = {
      for (final scope in kWebPickerScopes) scope.label: webPickerQuery(scope),
    };
    expect(queries, {
      'Agents': '',
      'Machines': '@ ',
      'Projects': '# ',
      'Models': ': ',
      'Store': '* ',
      'Commands': '>',
    });
  });
}
