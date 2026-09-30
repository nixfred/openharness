import '../../state/swarm_search.dart';

/// One clickable scope of the picker: the query prefix a key would type, and
/// what the scope lists.
typedef WebPickerScope = ({String prefix, String label});

/// The scopes the picker's `@ # : * >` prefixes reach, in their hint order.
const List<WebPickerScope> kWebPickerScopes = [
  (prefix: '', label: 'Agents'),
  (prefix: '@', label: 'Machines'),
  (prefix: '#', label: 'Projects'),
  (prefix: ':', label: 'Models'),
  (prefix: '*', label: 'Store'),
  (prefix: '>', label: 'Commands'),
];

/// The scopes this picker offers: Commands only where it has commands.
List<WebPickerScope> webPickerScopes(SwarmSearchController search) => [
  for (final scope in kWebPickerScopes)
    if (scope.prefix != '>' || search.commands != null) scope,
];

/// The query a click types for [scope] — what its key would have typed.
String webPickerQuery(WebPickerScope scope) =>
    scope.prefix.isEmpty || scope.prefix == '>'
    ? scope.prefix
    : '${scope.prefix} ';
