import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../shared/widgets/qr_code_view.dart';
import '../api/api_client.dart';
import '../core/phone_app_links.dart';
import '../screens/login_screen.dart' show showSignInSheet;
import '../shared/theme/app_icons.dart';
import '../shared/theme/app_theme.dart' as grid;
import '../shortcuts/app_keymap.dart';
import '../state/account_devices.dart' show NewDeviceNotice;
import '../state/app_state.dart';
import '../ws/ws_conn.dart' show WsRequestFailure, WsRequestTimeout;
import 'desktop_chrome.dart';
import 'desktop_prompt_surface.dart';
import 'terminal_prompt.dart';

/// Harness ▸ Add Phone… — how a phone comes to manage this account's agents.
///
/// **The phone signs in, and that is all (owner, 2026-10-12).** The phone's
/// onboarding (mobile `phone_welcome.dart`, `your_computer.dart`) puts a phone
/// on the account by its own sign-in: the account's device key log makes every
/// computer signed in to it trust the phone, so it finds this one with nothing
/// to scan. So the dialog says what to do on the phone — install Harness, sign
/// in with this account — and watches the account for it to join
/// ([AppNotifier.deviceJoins]). A computer with no account signs in first.
///
/// **The QR is the way in for what that does not cover** — a phone app from
/// before the onboarding, or a phone that does not turn up — put away under
/// "Not showing up? Scan a code instead", and armed only while it is up:
///
/// 1. **The QR** ([phonePairLink]) tells the phone who to sign in as, which
///    machine to pair with, and the one-time pairing code.
/// 2. **The sign-in code** ([PhoneSignInCodeCall]), which the QR also carries:
///    the phone redeems it for a session of its own, so the scan signs it in
///    with no emailed code. Renewed every minute while the code is up — see
///    [_AddPhoneDialogState._renewSignIn].
/// 3. **Arming the daemon.** The phone, once signed in, sends this machine an
///    `e2e_pair_intent`; the daemon runs the handshake only when somebody on
///    THIS computer hands it the same code (`POST /api/pair`, the call
///    `harness pair <code>` makes). So while the code is up the dialog keeps
///    handing it over — see [_AddPhoneDialogState._loop] — and the code is
///    live exactly as long as the QR is on screen.
///
/// [pair] and [signInCode] are the transport, injectable so a test needs no
/// daemon; by default they are this app's own loopback client
/// ([phonePairOverDaemon], [ApiClient.phoneSignInCode]).
Future<void> showAddPhoneDialog(
  BuildContext context,
  AppNotifier app, {
  AppKeymap? keymap,
  PhonePairCall? pair,
  PhoneSignInCodeCall? signInCode,
  VoidCallback? onConnectMachine,
  VoidCallback? onManageDevices,
}) => showTerminalPrompt<void>(
  context,
  keymap: keymap,
  builder: (_) => AddPhoneDialog(
    app: app,
    pair: pair,
    signInCode: signInCode ?? app.api.phoneSignInCode,
    onConnectMachine: onConnectMachine,
    onManageDevices: onManageDevices,
  ),
);

/// Where the QR points. The phone's `ConnectCode` (mobile
/// `lib/phone/welcome/connect_code.dart`) parses exactly this.
const kPhonePairHost = 'harness.autonomous.ai';
const kPhonePairPath = '/pair';

/// The characters a pairing code is drawn from: no `0 O 1 I L`, which read
/// alike — and no `U` either.
///
/// ⚠️ `U` is left out on purpose, although it reads fine. The daemon feeds
/// the code through core.ts `normalizeCode`, which maps `U` to `V` (Crockford
/// base32); the phone's `normalizePairCode` only uppercases and strips
/// separators. A code with a `U` in it would therefore reach CPace as two
/// different secrets and fail as `CODE_MISMATCH` every time — for a 16-letter
/// code, about four scans in ten. Without it both sides agree whatever either
/// normaliser does, at 30 symbols: 78 bits over 16 characters, far past what
/// three guesses per five minutes (the daemon's rate limit) could dent.
const kPhonePairCodeAlphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
const kPhonePairCodeLength = 16;

/// A fresh one-time pairing code, from a cryptographically secure source.
///
/// It is the whole secret the pairing rests on — the backend relays the
/// handshake and must learn nothing from it — so never `Random()`.
/// [random] exists for tests; `Random.secure().nextInt` is uniform, so no
/// symbol is likelier than another.
String newPhonePairCode({math.Random? random}) {
  final source = random ?? math.Random.secure();
  return String.fromCharCodes([
    for (var i = 0; i < kPhonePairCodeLength; i++)
      kPhonePairCodeAlphabet.codeUnitAt(
        source.nextInt(kPhonePairCodeAlphabet.length),
      ),
  ]);
}

/// `https://harness.autonomous.ai/pair#e=<email>&m=<machineId>&c=<code>&h=<sign-in code>`.
///
/// ⚠️ EVERYTHING rides in the FRAGMENT, never the query. The code is the
/// out-of-band secret end-to-end encryption rests on, and a browser never
/// sends a fragment to the server — so a link opened in Safari (no app
/// installed yet, a desktop camera, a curious person) still keeps the code
/// off our servers and out of every access log between here and there. The
/// email and machine id go with it: nothing in this link is the server's
/// business.
///
/// Encoded as a query string inside the fragment, with
/// [Uri.encodeQueryComponent], because the phone reads it back with
/// [Uri.splitQueryString] — a `+` in an address has to arrive as a `+`.
///
/// [signIn] (`h`) is the one-time code that signs the phone in; without it —
/// or on a phone app that predates it — the phone signs in with an emailed
/// code, as before. It is the account's credential for its minute, which is
/// one more reason all of this rides in the fragment.
Uri phonePairLink({
  required String email,
  required String machineId,
  required String code,
  String? signIn,
}) => Uri(
  scheme: 'https',
  host: kPhonePairHost,
  path: kPhonePairPath,
  fragment:
      'e=${Uri.encodeQueryComponent(email)}'
      '&m=${Uri.encodeQueryComponent(machineId)}'
      '&c=$code'
      '${signIn != null ? '&h=${Uri.encodeQueryComponent(signIn)}' : ''}',
);

/// What one `POST /api/pair` came to, as far as this dialog cares.
@immutable
class PhonePairAnswer {
  /// The phone is paired; [label] is its own name for itself.
  const PhonePairAnswer.paired(String this.label) : error = null;

  /// The daemon's error code (`NO_INTENT`, `CODE_MISMATCH`, …), or
  /// [unavailable] for a daemon that cannot pair at all.
  const PhonePairAnswer.failed(String this.error) : label = null;

  final String? label;
  final String? error;

  /// The daemon has no pairing to offer: it said so (a build without E2EE),
  /// it predates `/api/pair` (404), or nobody is listening. Asking again will
  /// not change that.
  static const unavailable = 'PAIRING_UNAVAILABLE';

  @override
  String toString() =>
      label != null ? 'PhonePairAnswer.paired($label)' : 'failed($error)';
}

/// Hand the daemon [code] once. [cancel] is cancelled when the dialog closes:
/// the transport should give up waiting on its long poll then.
typedef PhonePairCall = Future<PhonePairAnswer> Function(
  String code,
  CancelToken cancel,
);

/// [PhonePairCall] over this app's own loopback client — the daemon's Unix
/// socket, or its port (see [ApiClient]).
PhonePairCall phonePairOverDaemon(ApiClient api) => (code, cancel) async {
  try {
    final (:status, :body) = await api.pair(code, cancelToken: cancel);
    final error = body['error'];
    if (status >= 200 && status < 300 && error == null) {
      final label = body['label'];
      return PhonePairAnswer.paired(
        label is String && label.trim().isNotEmpty ? label.trim() : 'phone',
      );
    }
    // A daemon from before `/api/pair` answers its catch-all 404, which is
    // `{error: 'not found'}` — a code, but not one of the pairing's.
    if (status == 404) {
      return const PhonePairAnswer.failed(PhonePairAnswer.unavailable);
    }
    return PhonePairAnswer.failed(
      error is String && error.isNotEmpty ? error : 'HTTP_$status',
    );
  } on DioException catch (error) {
    return PhonePairAnswer.failed(switch (error.type) {
      // Nobody on the port or the socket.
      DioExceptionType.connectionError => PhonePairAnswer.unavailable,
      DioExceptionType.unknown when error.error is SocketException =>
        PhonePairAnswer.unavailable,
      // Our own 60 s ran out on a handshake: the phone went quiet.
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.connectionTimeout => 'TIMEOUT',
      _ => 'UNREACHABLE',
    });
  }
};

/// The browser already holds the machine's trusted identity. Arm that machine over its encrypted
/// connection; the account service never receives the QR's pairing secret.
PhonePairCall phonePairOverRelay(AppNotifier app, String machineId) =>
    (code, cancel) async {
      if (cancel.isCancelled) return const PhonePairAnswer.failed('CANCELLED');
      try {
        final answer = await Future.any([
          app.pairPhone(machineId, code),
          cancel.whenCancel.then(
            (_) => <String, dynamic>{'error': 'CANCELLED'},
          ),
        ]);
        if (answer['ok'] == true) {
          final label = answer['label'];
          return PhonePairAnswer.paired(
            label is String && label.trim().isNotEmpty ? label.trim() : 'phone',
          );
        }
        final error = answer['error'];
        return PhonePairAnswer.failed(
          error == 'UNSUPPORTED' ? PhonePairAnswer.unavailable : '$error',
        );
      } on WsRequestTimeout {
        return const PhonePairAnswer.failed(PhonePairAnswer.unavailable);
      } on WsRequestFailure catch (failure) {
        return PhonePairAnswer.failed(
          failure.code == 'UNSUPPORTED'
              ? PhonePairAnswer.unavailable
              : failure.code,
        );
      } catch (_) {
        return const PhonePairAnswer.failed('BACKEND_DOWN');
      }
    };

/// A fresh one-time sign-in code for the QR and how long it stays good, or
/// null when there is none to be had (see [ApiClient.phoneSignInCode]).
typedef PhoneSignInCodeCall = Future<({String code, Duration ttl})?> Function();

class AddPhoneDialog extends StatefulWidget {
  const AddPhoneDialog({
    super.key,
    required this.app,
    this.pair,
    required this.signInCode,
    this.onConnectMachine,
    this.onManageDevices,
  });

  final AppNotifier app;
  final PhonePairCall? pair;
  final PhoneSignInCodeCall signInCode;
  final VoidCallback? onConnectMachine;

  /// Was "Manage devices…" — Machines — under the code. No longer drawn: a
  /// second way out, in the middle of adding a phone, that nobody adding one
  /// was looking for (owner, 2026-10-12). Kept so the callers that pass it
  /// still build; it goes with them.
  final VoidCallback? onManageDevices;

  @override
  State<AddPhoneDialog> createState() => _AddPhoneDialogState();
}

/// What the picture at the top of Add Phone shows: this computer, the phone,
/// and what runs between them.
enum _Link {
  /// No account here: the computer asks to be signed in, and the way to the
  /// phone is locked.
  signIn,

  /// Its sign-in is under way in the browser: the same, at twice the pace.
  signingIn,

  /// Signed in: packets run to the phone, which rings out.
  looking,

  /// The phone is in.
  ready,
}

class _AddPhoneDialogState extends State<AddPhoneDialog>
    with TickerProviderStateMixin {
  /// With no phone waiting the daemon answers at once, so this is the whole
  /// cadence of the loop: how soon after the phone's intent lands the
  /// handshake starts. ⚠️ `NO_INTENT`, `EXPIRED` and `BUSY` are answered
  /// BEFORE any handshake runs, and only a handshake that ran and failed
  /// counts against the daemon's three-per-five-minutes limit (manager.ts
  /// `failPair`) — so asking this often costs the person nothing.
  static const _poll = Duration(milliseconds: 1500);
  static const _rateLimited = Duration(seconds: 60);
  static const _unexpected = Duration(seconds: 5);

  /// How often the QR gets a new sign-in code. Shorter than the code's own
  /// life (90 s at the backend), so the one on screen always has at least
  /// half a minute left in it when a phone reads it.
  static const _signInRenew = Duration(seconds: 60);

  /// How long "Looking for your phone" goes before it names what keeps a phone
  /// away most often: signed in, but to another account.
  static const _stillLookingAfter = Duration(minutes: 1);

  /// One beat of the picture — and of the step it points at, and the caret:
  /// the mobile onboarding's breathing pace. Twice as fast while the browser
  /// signs this computer in.
  static const _beat = Duration(milliseconds: 2400);
  static const _quickBeat = Duration(milliseconds: 1200);

  AppNotifier get app => widget.app;

  // Freeze the destination while a QR is visible, even if focus or inventory changes.
  late final String? _remoteMachineId = app.viewer == null
      ? null
      : app.ownedActionMachine?.machine.machineId;

  late final PhonePairCall _pair =
      widget.pair ??
      (_remoteMachineId != null
          ? phonePairOverRelay(app, _remoteMachineId)
          : phonePairOverDaemon(app.api));

  /// A fresh code each time the dialog opens, and a fresh one again after a
  /// scan that did not match — see [_loop].
  late String _code = newPhonePairCode();

  /// ONE token for the dialog's whole life: cancelling it is closing.
  final _cancel = CancelToken();
  bool _closed = false;
  bool _running = false;
  Timer? _timer;
  Completer<bool>? _sleeping;

  /// The sign-in code in the QR, once asked for. Null after asking is a QR
  /// without one: the phone then asks for an emailed code.
  String? _signIn;
  bool _signInAsked = false;
  Timer? _signInTimer;

  /// Bumped to start the renewal over (see [_restartSignIn]): an answer to an
  /// older ask is dropped, so only one chain of renewals ever runs.
  int _signInRound = 0;

  /// The QR's sign-in code has been asked for since the code last came up. A
  /// code put away lets its renewal lapse ([_renewSignIn]), and the next
  /// showing asks afresh.
  bool _signInStarted = false;

  /// This computer had no account while the dialog was open. When the account
  /// lands, the lock on the way to the phone opens, and a code that was up
  /// asks for its sign-in code again — see [_appChanged].
  bool _awaitingAccount = false;

  /// The sign-in sheet raised from here is up — see [_signInHere].
  bool _signingIn = false;

  /// "On this Mac ▸ Sign in" leads: the computer had no account when this
  /// opened, or lost it since. It stays — ticked — once it signs in, so the
  /// steps under it do not move.
  bool _signInStep = false;

  /// The phone is in: the name it gave, or '' when it gave none. Null while
  /// looking.
  String? _ready;

  /// "Not showing up? Scan a code instead" is open: the code is up, and armed.
  bool _showingCode = false;

  /// A minute of looking and no phone ([_stillLookingAfter]).
  bool _stillLooking = false;
  Timer? _stillTimer;

  StreamSubscription<NewDeviceNotice>? _joins;

  /// The beat ([_beat]): the picture, the ring of the step to do now, and the
  /// caret after "Looking for your phone" keep it.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: _beat,
  );

  /// The lock on the way to the phone opening — once, when this computer
  /// signs in from here.
  late final AnimationController _unlock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  /// The code's space — "Preparing your code…", then the code — so it can be
  /// brought into view ([_codeSpace]).
  final _codeKey = GlobalKey();

  /// The code's space has appeared once; after that, the scroll is the person's.
  bool _codeAppeared = false;

  /// No pairing to be had from this daemon — asking stopped for good.
  bool _stopped = false;
  String? _message;

  /// A message that is an instruction to the person ("scan the new code"),
  /// which the next "no phone yet" must not wipe before they have read it.
  /// Everything else describes a condition, and goes when it does.
  bool _sticky = false;

  @override
  void initState() {
    super.initState();
    _signInStep = _awaitingAccount = app.isGuest;
    app.addListener(_appChanged);
    _joins = app.deviceJoins.listen(_deviceJoined);
    _watchForPhone();
  }

  @override
  void dispose() {
    _closed = true;
    app.removeListener(_appChanged);
    unawaited(_joins?.cancel());
    _timer?.cancel();
    _signInTimer?.cancel();
    _stillTimer?.cancel();
    _pulse.dispose();
    _unlock.dispose();
    if (_sleeping case final sleeping? when !sleeping.isCompleted) {
      sleeping.complete(false);
    }
    // ⚠️ This only stops WAITING. A handshake the daemon has already started
    // runs to its end whatever happens here, and a phone that finishes it is
    // paired: the person scanned the code, which is the consent. What closing
    // does guarantee is that nothing arms the daemon again — the code dies
    // with the QR.
    _cancel.cancel('Add Phone closed');
    super.dispose();
  }

  void _appChanged() {
    if (_closed) return;
    if (app.isGuest) {
      _awaitingAccount = true;
      _signInStep = true;
      _stillTimer?.cancel();
      _stillTimer = null;
      _stillLooking = false;
    } else if (_awaitingAccount && !app.signingIn) {
      // Signed in while the dialog was open: the lock on the way to the phone
      // opens, once.
      _awaitingAccount = false;
      if (!MediaQuery.disableAnimationsOf(context)) {
        unawaited(_unlock.forward(from: 0));
      }
      // A code that was up asked for its sign-in code without an account and
      // was refused, and the next renewal is a minute off: without asking now,
      // the first QR the phone can scan has no sign-in in it, and the phone
      // falls back to an emailed code.
      if (_signInStarted) _restartSignIn();
    }
    setState(() {});
    _syncLoop();
    _watchForPhone();
  }

  /// A device joined the account while this was open. A computer is not the
  /// phone; anything else signed in with this account, which is what the steps
  /// ask of the phone.
  void _deviceJoined(NewDeviceNotice device) {
    if (_closed || _ready != null || device.kind == 'machine') return;
    if (app.isGuest) return;
    _phoneIn(device.label);
  }

  /// The phone is in — by its own sign-in, or by the code. The code goes, with
  /// its renewal and the loop that arms it ([_asking]).
  void _phoneIn(String label) {
    _stillTimer?.cancel();
    _stillTimer = null;
    _signInTimer?.cancel();
    setState(() {
      _ready = label.trim();
      _message = null;
      // Back from the stores' codes, if that is where it was: "is ready" is
      // said under the picture.
      _showingStores = false;
    });
  }

  /// Whether there is a phone to look for: an account here, and none in yet.
  bool get _looking => _ready == null && !app.isGuest && !app.signingIn;

  /// Starts the minute before "Still looking" ([_stillLookingAfter]) once
  /// there is a phone to look for.
  void _watchForPhone() {
    if (!_looking || _stillLooking || _stillTimer != null) return;
    _stillTimer = Timer(_stillLookingAfter, () {
      _stillTimer = null;
      if (_closed || !_looking) return;
      setState(() => _stillLooking = true);
    });
  }

  /// A guest's way in, raised over this dialog rather than instead of it: the
  /// sheet closes itself when the account lands, and the steps on the phone
  /// light up here.
  ///
  /// Without Scan with your phone: that way in needs a phone already signed
  /// in, and the person here is adding one.
  Future<void> _signInHere() async {
    if (_signingIn || _closed) return;
    _signingIn = true;
    try {
      await showSignInSheet(
        context,
        app,
        reason:
            'Sign in to add your phone. Your phone signs in to the same '
            'account.',
        offerPhone: false,
      );
    } finally {
      _signingIn = false;
    }
  }

  /// Who and what the QR is for, or null while there is nothing to show yet.
  ///
  /// The machine is the one the phone will see in its own list: this
  /// computer's row, whose id is the backend's once someone is signed in (the
  /// daemon serves this computer under the account's `machineId` then — see
  /// `AppNotifier._followLocalMachineId`).
  ({String email, String machineId})? get _target {
    // Mid sign-in the daemon moves onto the account, and this computer's id
    // with it (`AppNotifier.login`): nothing to show or arm until it lands.
    if (app.isGuest || app.signingIn) return null;
    final email = app.currentUser?.email.trim();
    final machineId = app.viewer == null
        ? app.localMachineState?.machine.machineId
        : _remoteMachineId;
    // `CurrentUserProfile.local()` says "local terminal": not an address.
    if (email == null || !email.contains('@')) return null;
    if (machineId == null || machineId.isEmpty) return null;
    return (email: email, machineId: machineId);
  }

  /// The account the phone signs in with, when this computer knows it.
  String? get _accountEmail {
    if (app.isGuest) return null;
    final email = app.currentUser?.email.trim();
    return email != null && email.contains('@') ? email : null;
  }

  /// Only while the code is up: a code nobody can see is a code nobody can
  /// scan, and arming the daemon with it would be for nothing.
  bool get _asking => !_closed && !_stopped && _ready == null && _showingCode;

  /// Starts the loop when there is a QR worth arming and nothing is asking
  /// yet. Called again whenever the app changes, so a profile that loads
  /// after the dialog opened arms it then.
  void _syncLoop() {
    if (_running || !_asking || _target == null) return;
    _running = true;
    unawaited(_loop().whenComplete(() => _running = false));
  }

  Future<void> _loop() async {
    while (_asking && _target != null) {
      final code = _code;
      PhonePairAnswer answer;
      try {
        answer = await _pair(code, _cancel);
      } catch (error) {
        answer = PhonePairAnswer.failed('$error');
      }
      // A long poll can come back long after the dialog went — a handshake
      // that finished (or failed) behind a closed window must not touch it.
      if (_closed) return;
      if (answer.label case final label?) {
        // The transports call a phone that gave no name "phone".
        _phoneIn(label == 'phone' ? '' : label);
        return;
      }
      final Duration wait;
      switch (answer.error) {
        // No phone yet, one whose minute ran out, or one mid-handshake with
        // somebody else. Ask again.
        case 'NO_INTENT' || 'EXPIRED' || 'BUSY':
          if (!_sticky && _message != null) setState(() => _message = null);
          wait = _poll;
        case 'CODE_MISMATCH':
          // The phone holds the old code and the daemon has spent it. A new
          // one — and a new QR — is the only way forward.
          // Under the code, which is the new one by now: "above".
          _say("That code didn't work. Scan the new one above.", sticky: true);
          setState(() => _code = newPhonePairCode());
          wait = _poll;
        case 'RATE_LIMITED':
          _say('Too many tries. Wait a minute.');
          wait = _rateLimited;
        case 'BACKEND_DOWN':
          _say(
            app.viewer == null
                ? "This ${_thisComputer()} can't reach Harness right now."
                : 'The computer is offline. Reconnect it to add your phone.',
          );
          wait = _poll;
        // The phone started and went quiet, or said no. The QR is still
        // good: scanning it again starts over.
        case 'TIMEOUT':
          _say('Your phone stopped answering. Scan again.', sticky: true);
          wait = _poll;
        case 'CANCELLED':
          _say('Cancelled on your phone. Scan again.', sticky: true);
          wait = _poll;
        case PhonePairAnswer.unavailable:
          _say(
            app.viewer == null
                ? 'Update Harness on this ${_thisComputer()} to add a phone.'
                : 'Update Harness on the computer to add a phone.',
          );
          setState(() => _stopped = true);
          return;
        case final other:
          _say('Could not pair ($other). Trying again.');
          wait = _unexpected;
      }
      if (!await _sleep(wait)) return;
    }
  }

  /// Ask for a sign-in code, put it in the QR, and ask again before it runs
  /// out — for as long as the QR is on screen. A failure is not retried
  /// sooner: the QR works without one, and the next renewal tries again.
  /// The one exception is an account arriving — see [_restartSignIn].
  Future<void> _renewSignIn() async {
    final round = _signInRound;
    ({String code, Duration ttl})? next;
    try {
      next = await widget.signInCode();
    } catch (_) {
      next = null;
    }
    if (_closed || !mounted || round != _signInRound) return;
    setState(() {
      _signIn = next?.code;
      _signInAsked = true;
    });
    if (_ready != null || _stopped) return;
    final ttl = next?.ttl;
    final wait = ttl != null && ttl - const Duration(seconds: 30) < _signInRenew
        ? ttl - const Duration(seconds: 30)
        : _signInRenew;
    _signInTimer = Timer(wait > Duration.zero ? wait : _signInRenew, () {
      // Put away, the code needs no fresher sign-in: the next showing asks.
      if (!_showingCode) {
        _signInStarted = false;
        return;
      }
      unawaited(_renewSignIn());
    });
  }

  /// The renewal from the top, now: the pending one is cancelled, an ask
  /// still in flight is dropped when it lands, and the QR waits on
  /// "Preparing your code…" for the new code. The caller rebuilds.
  void _restartSignIn() {
    _signInTimer?.cancel();
    _signInRound++;
    _signIn = null;
    _signInAsked = false;
    unawaited(_renewSignIn());
  }

  /// "Not showing up? Scan a code instead", opened or put away. Opened, the
  /// code asks for its sign-in code — fresh unless one is still renewing —
  /// and starts arming the daemon; put away, the loop ends after its answer.
  void _toggleCode() {
    setState(() {
      _showingCode = !_showingCode;
      if (_showingCode && !_signInStarted) {
        _signInStarted = true;
        _restartSignIn();
      }
    });
    _syncLoop();
  }

  void _say(String message, {bool sticky = false}) => setState(() {
    _message = message;
    _sticky = sticky;
  });

  /// A wait the dialog can cut short: true when it ran out, false when the
  /// dialog closed. `Future.delayed` cannot be cancelled, and a timer left
  /// behind by a closed dialog is one more wake-up for nothing.
  Future<bool> _sleep(Duration duration) {
    final done = Completer<bool>();
    _sleeping = done;
    _timer = Timer(duration, () {
      if (!done.isCompleted) done.complete(!_closed);
    });
    return done.future;
  }

  void _close() => Navigator.of(context).maybePop();

  Color get _faint => DesktopChrome.muted;

  /// Narrower than a form: one column, the code at its middle.
  static const double _width = 400;

  /// The connect code, under the steps rather than the dialog's subject: still
  /// big enough to scan from across a desk.
  static const double _qrSide = 168;

  /// "App Store · Google Play": the stores' codes are up, in the connect code's
  /// place. One kind of code on screen at a time — Harness reads only the connect
  /// code, the Camera only these — so nobody scans one with the other's.
  bool _showingStores = false;

  _Link get _link {
    if (_ready != null) return _Link.ready;
    if (app.signingIn) return _Link.signingIn;
    if (app.isGuest) return _Link.signIn;
    return _Link.looking;
  }

  @override
  Widget build(BuildContext context) {
    grid.AppTheme.watch(context);
    _keepBeat(context);
    return _dialog(context);
  }

  /// Runs the beat while something on screen moves to it: not once the phone
  /// is in, not under Reduce Motion, and not while the dialog is hidden.
  void _keepBeat(BuildContext context) {
    final link = _link;
    final moving =
        link != _Link.ready &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!moving) {
      if (_pulse.isAnimating) _pulse.stop();
      return;
    }
    final beat = link == _Link.signingIn ? _quickBeat : _beat;
    if (_pulse.isAnimating && _pulse.duration == beat) return;
    _pulse.duration = beat;
    unawaited(_pulse.repeat());
  }

  Widget _dialog(BuildContext context) {
    return TerminalPromptKeys(
      cancel: _close,
      child: DesktopPromptSurface(
        width: _width,
        body: LayoutBuilder(
          builder: (context, constraints) => DesktopPromptScrollBody(
            child: _showingStores
                ? _stores()
                : _connect(math.min(_qrSide, constraints.maxWidth)),
          ),
        ),
        // None over the store's code: Back and Esc are the ways out of it.
        actions: _showingStores
            ? const []
            : [
                // Cancel while it looks — closing takes the code away — and
                // Done once the phone is in.
                if (_ready != null)
                  FilledButton(
                    key: const ValueKey('add-phone-done'),
                    autofocus: true,
                    onPressed: _close,
                    child: const Text('Done'),
                  )
                else ...[
                  TextButton(onPressed: _close, child: const Text('Cancel')),
                  if (app.isGuest)
                    FilledButton(
                      key: const ValueKey('add-phone-sign-in'),
                      autofocus: true,
                      onPressed: () => unawaited(_signInHere()),
                      child: const Text('Sign in…'),
                    ),
                ],
              ],
      ),
    );
  }

  /// What this is for, the picture with how it is going under it, then the
  /// steps — on this computer first while it has no account, then on the
  /// phone — and the code, put away under them.
  ///
  /// ```
  /// Add your phone
  /// Manage all your agents on all your computers from your phone.
  ///        [Mac] ·······🔒······· [phone]
  ///            Looking for your phone▌
  /// ON THIS MAC                              (no account when it opened)
  /// (1) Sign in                              → (✓) Signed in
  ///     Your phone signs in with the same        As ada@gmail.com.
  ///     account.
  /// ON YOUR PHONE
  /// (2) Install Harness
  ///     App Store · Google Play
  /// (3) Sign in
  ///     With ada@gmail.com.
  /// ─────────────────────────────────────────
  /// › Not showing up? Scan a code instead
  ///                                 [Cancel] [Sign in…]
  /// ```
  ///
  /// ⚠️ **The phone's words, turned around (owner, 2026-10-12).** The line
  /// under the title is the phone's welcome headline (mobile `OnboardingCopy`),
  /// and the steps on the phone are its "On your computer, go to" seen from
  /// here (`set_up_computer.dart` `goToSteps`): Install Harness, then Sign in,
  /// `With <account>.` Change one, change the other.
  Widget _connect(double qrSide) {
    final asking = app.isGuest || app.signingIn;
    final ready = _ready != null;
    final email = _accountEmail;
    final first = _signInStep ? 2 : 1;
    final phoneMark = asking
        ? _Mark.later
        : ready
        ? _Mark.done
        : _Mark.plain;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text('Add your phone', style: DesktopChrome.heading()),
        ),
        const SizedBox(height: 4),
        Text(
          'Manage all your agents on all your computers from your phone.',
          style: _note(),
        ),
        const SizedBox(height: 14),
        _LinkPicture(link: _link, beat: _pulse, unlock: _unlock),
        _linkLine(email),
        if (_signInStep) ...[
          _where('On this ${_thisComputer()}'),
          _Step(
            number: 1,
            mark: asking ? _Mark.current : _Mark.done,
            beat: _pulse,
            title: [TextSpan(text: asking ? 'Sign in' : 'Signed in')],
            note: asking || email == null
                ? const [
                    TextSpan(
                      text: 'Your phone signs in with the same account.',
                    ),
                  ]
                : [
                    const TextSpan(text: 'As '),
                    _strong(email),
                    const TextSpan(text: '.'),
                  ],
            last: true,
          ),
        ],
        _where('On your phone'),
        _Step(
          number: first,
          mark: phoneMark,
          title: const [TextSpan(text: 'Install Harness')],
          link: ready
              ? null
              : _StepLink(
                  key: const ValueKey('add-phone-show-downloads'),
                  // The stores, not "Get Harness": in the computer's own
                  // Harness that read as this app's download.
                  label: 'App Store · Google Play',
                  onPressed: () => setState(() => _showingStores = true),
                ),
        ),
        _Step(
          number: first + 1,
          mark: phoneMark,
          title: const [TextSpan(text: 'Sign in')],
          note: asking || email == null
              ? const [TextSpan(text: 'With the same account.')]
              : [
                  const TextSpan(text: 'With '),
                  _strong(email),
                  const TextSpan(text: '.'),
                ],
          last: true,
        ),
        if (!asking && !ready) ...[
          _disclosure(),
          if (_showingCode) ...[
            const SizedBox(height: 12),
            ..._codeArea(qrSide),
          ],
        ],
      ],
    );
  }

  /// Where the steps under it happen — this computer, or the phone.
  Widget _where(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Semantics(
      header: true,
      child: Text(
        text.toUpperCase(),
        style: DesktopChrome.metadata().copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: .7,
        ),
      ),
    ),
  );

  /// The line under the picture, and it is the status: looking — the phone's
  /// "Looking for your computer▌" turned around — then, after a minute, what
  /// keeps a phone away most often, and that it is in. Nothing before there is
  /// an account to look with: the steps say what to do.
  Widget _linkLine(String? email) {
    final Widget line;
    switch (_link) {
      case _Link.signIn || _Link.signingIn:
        return const SizedBox.shrink();
      case _Link.ready:
        final name = _ready!;
        line = Text(
          '${name.isEmpty ? 'Your phone' : name} is ready.',
          key: const ValueKey('add-phone-ready'),
          textAlign: TextAlign.center,
          style: DesktopChrome.heading(),
        );
      case _Link.looking when _stillLooking:
        line = Column(
          key: const ValueKey('add-phone-still-looking'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Still looking for your phone',
              textAlign: TextAlign.center,
              style: DesktopChrome.text(color: _faint, size: 13.5),
            ),
            const SizedBox(height: 3),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Your phone has to be signed in with '),
                  if (email != null)
                    _strong(email)
                  else
                    const TextSpan(text: 'the same account'),
                  const TextSpan(text: '.'),
                ],
              ),
              textAlign: TextAlign.center,
              style: DesktopChrome.metadata(),
            ),
          ],
        );
      case _Link.looking:
        line = Row(
          key: const ValueKey('add-phone-looking'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                'Looking for your phone',
                style: DesktopChrome.text(color: _faint, size: 13.5),
              ),
            ),
            _Caret(beat: _pulse),
          ],
        );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(liveRegion: true, child: Center(child: line)),
    );
  }

  /// "Not showing up? Scan a code instead": the code, for a phone app from
  /// before the onboarding or a phone that does not turn up — put away until
  /// asked for, and armed only while it is up ([_asking]).
  Widget _disclosure() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: grid.AppPalette.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            expanded: _showingCode,
            child: DesktopPill(
              key: const ValueKey('add-phone-show-code'),
              label: 'Not showing up? Scan a code instead',
              quiet: true,
              foregroundColor: _faint,
              leading: AnimatedRotation(
                turns: _showingCode ? .25 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(AppIcons.chevronRight, size: 14, color: _faint),
              ),
              onPressed: _toggleCode,
            ),
          ),
        ),
      ),
    ),
  );

  /// The code, under "Not showing up?": the code, where to scan it on the
  /// phone, and what went wrong — or, before there is a code, why not yet, in
  /// a square of the code's own size so nothing moves when it comes.
  List<Widget> _codeArea(double qrSide) {
    // The code's own size at the least, so nothing moves when it comes; taller
    // when what it says (and a button) needs more than the code does.
    Widget room(List<Widget> children) => _codeSpace(
      Center(
        child: Container(
          width: qrSide,
          constraints: BoxConstraints(minHeight: qrSide),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: DesktopChrome.field,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
    Widget say(String text) =>
        Text(text, textAlign: TextAlign.center, style: _note());

    final target = _target;
    if (target == null) {
      if (_connectFirst) {
        return [
          room([
            say('Your phone pairs with a computer on your account.'),
            if (widget.onConnectMachine case final connect?) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  connect();
                },
                child: const Text('Connect a machine'),
              ),
            ],
          ]),
        ];
      }
      return [
        room([
          say(
            app.currentUser?.email.contains('@') == true
                ? 'Waiting for Harness on this ${_thisComputer()}…'
                : 'Waiting for your account…',
          ),
        ]),
      ];
    }
    // A moment's wait for the sign-in code, in the QR's own space: a QR that
    // changed right after it appeared would be one scanned without it.
    if (!_signInAsked) {
      return [
        room([say('Preparing your code…')]),
      ];
    }
    final link = phonePairLink(
      email: target.email,
      machineId: target.machineId,
      code: _code,
      signIn: _signIn,
    ).toString();
    final message = _message;
    return [
      _codeSpace(
        Center(
          // Dimmed once there is no pairing to be had, so nobody scans it.
          child: Opacity(
            opacity: _stopped ? .25 : 1,
            child: PhonePairQr(data: link, side: qrSide),
          ),
        ),
      ),
      if (_remoteMachineId case final machineId?) ...[
        const SizedBox(height: 8),
        Text(
          app.stateOf(machineId)?.machine.displayName ?? 'Computer',
          textAlign: TextAlign.center,
          style: _note(),
        ),
      ],
      const SizedBox(height: 10),
      // Computers is where the phone scans a code — the new app at its foot
      // ("Or scan the QR code on your computer"), an older one as Connect
      // computer — so the line names the list, not its button.
      Text(
        'On your phone, open Computers and scan this code.',
        textAlign: TextAlign.center,
        style: _note(),
      ),
      if (message != null) ...[
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            key: const ValueKey('add-phone-status'),
            textAlign: TextAlign.center,
            style: _note(Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    ];
  }

  /// "App Store · Google Play" beside Install Harness: ONE code a phone's
  /// camera opens, which sends an iPhone to the App Store and an Android phone
  /// to Google Play ([kPhoneAppUrl]) — so nobody has to know which store is
  /// theirs. A code, not a link: clicked here a link opens on this computer,
  /// which cannot install a phone's app. Nothing to do here but scan it, so no
  /// buttons (owner, 2026-10-12): Back returns, Esc closes.
  Widget _stores() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: DesktopPill(
          key: const ValueKey('add-phone-hide-downloads'),
          label: '‹ Back',
          quiet: true,
          onPressed: () => setState(() => _showingStores = false),
        ),
      ),
      const SizedBox(height: 8),
      Semantics(
        header: true,
        child: Text(
          'Get Harness on your phone',
          style: DesktopChrome.heading(),
        ),
      ),
      const SizedBox(height: 4),
      Text('Scan with your phone’s Camera.', style: _note()),
      const SizedBox(height: 20),
      const Center(
        child: QrCodeView(
          data: kPhoneAppUrl,
          side: _qrSide,
          semanticLabel: 'QR code for Harness on the App Store or Google Play',
        ),
      ),
      const SizedBox(height: 12),
      const _StoreMarks(),
    ],
  );

  /// A step's words in bold: what is on the phone's screen, or the account.
  static TextSpan _strong(String text) => TextSpan(
    text: text,
    style: const TextStyle(fontWeight: FontWeight.w600),
  );

  /// A browser with none of the account's computers to pair through.
  bool get _connectFirst =>
      app.viewer != null &&
      !app.signingIn &&
      app.currentUser?.email.contains('@') == true;

  /// [child] in the code's space, scrolled into view the first time it appears.
  ///
  /// The steps above push the code — opened under them — below the fold of a
  /// short window. It is brought up only as far as it takes, so where it
  /// already shows nothing moves; and only the once, so a new code or a dimmed
  /// one never pulls back a person who scrolled up.
  Widget _codeSpace(Widget child) {
    if (!_codeAppeared) {
      _codeAppeared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final space = _codeKey.currentContext;
        if (_closed || space == null) return;
        unawaited(
          Scrollable.ensureVisible(
            space,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      });
    }
    return KeyedSubtree(key: _codeKey, child: child);
  }

  /// A line under a step's title: smaller and quieter than the title.
  TextStyle _note([Color? color]) =>
      DesktopChrome.text(color: color ?? _faint, size: 13);
}

/// How a step's number is drawn.
enum _Mark {
  /// To do, now: in the accent, its ring keeping the picture's beat.
  current,

  /// To do once the step before it is done: faint, and so are its words.
  later,

  /// To do.
  plain,

  /// Done: a tick.
  done,
}

/// One step: its number in a ring, a thread down to the next one's, what to
/// do, a quieter line under it where one is needed, and under that a way to do
/// it. The phone's steps (mobile `set_up_computer.dart` `StepsTimeline`), on
/// this side.
class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.mark,
    required this.title,
    this.note,
    this.link,
    this.beat,
    this.last = false,
  });

  final int number;
  final _Mark mark;
  final List<InlineSpan> title;
  final List<InlineSpan>? note;

  /// The step's own way to do it ([_StepLink]), under its words — not out at
  /// the row's end, where it read as apart from the step and ran out of room
  /// for its words at a large text size.
  final Widget? link;

  /// The picture's beat, which a [_Mark.current] ring keeps.
  final AnimationController? beat;

  /// No thread under the last step of a group.
  final bool last;

  static const double _ring = 22;

  @override
  Widget build(BuildContext context) {
    final faint = grid.AppPalette.textFaint;
    final titleColor = switch (mark) {
      _Mark.later => faint,
      _Mark.done => DesktopChrome.muted,
      _ => DesktopChrome.foreground,
    };
    final noteColor = mark == _Mark.later ? faint : DesktopChrome.muted;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _ring,
            child: Column(
              children: [
                ExcludeSemantics(child: _numberRing()),
                if (!last)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Center(
                        child: Container(
                          width: 1,
                          color: grid.AppPalette.divider,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Centred on the ring while it is one line; wraps under itself after.
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: _ring),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text.rich(
                        TextSpan(children: title),
                        style: DesktopChrome.text(size: 14, color: titleColor),
                      ),
                    ),
                  ),
                  if (note case final note?)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text.rich(
                        TextSpan(children: note),
                        style: DesktopChrome.text(
                          size: 12.5,
                          color: noteColor,
                          height: 1.4,
                        ),
                      ),
                    ),
                  if (link case final link?)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: link,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberRing() {
    switch (mark) {
      case _Mark.done:
        final ok = grid.AppPalette.online;
        return Container(
          width: _ring,
          height: _ring,
          decoration: BoxDecoration(
            color: ok.withValues(alpha: .16),
            shape: BoxShape.circle,
          ),
          child: Icon(AppIcons.check, size: 13, color: ok),
        );
      case _Mark.current:
        final accent = DesktopChrome.accent;
        final dot = Container(
          width: _ring,
          height: _ring,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          child: Text(
            '$number',
            style: DesktopChrome.metadata(color: Colors.white)
                .copyWith(fontWeight: FontWeight.w600),
          ),
        );
        final beat = this.beat;
        if (beat == null) return dot;
        return AnimatedBuilder(
          animation: beat,
          child: dot,
          builder: (context, child) {
            // A halo out from the ring, gone by 70% of the beat.
            final t = (beat.value / .7).clamp(0.0, 1.0);
            return DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  if (beat.isAnimating && t < 1)
                    BoxShadow(
                      color: accent.withValues(alpha: .55 * (1 - t)),
                      spreadRadius: 7 * t,
                    ),
                ],
              ),
              child: child,
            );
          },
        );
      case _Mark.later || _Mark.plain:
        final color = mark == _Mark.later
            ? grid.AppPalette.textFaint
            : DesktopChrome.muted;
        return Container(
          width: _ring,
          height: _ring,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.5),
          ),
          child: Text(
            '$number',
            style: DesktopChrome.metadata(color: color)
                .copyWith(fontWeight: FontWeight.w600, fontSize: 11),
          ),
        );
    }
  }
}

/// A step's way to do it: its words in the accent, on the step's own edge, and
/// nothing around them — a pill there set the words in from the step's, and a
/// box read as one more button beside the dialog's own. Hover and the keyboard
/// underline them. They wrap, rather than run out of room, at a large text size.
class _StepLink extends StatefulWidget {
  const _StepLink({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_StepLink> createState() => _StepLinkState();
}

class _StepLinkState extends State<_StepLink> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: widget.onPressed,
        onHover: (hovered) => setState(() => _hovered = hovered),
        onFocusChange: (focused) => setState(() => _focused = focused),
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(4),
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            widget.label,
            style:
                DesktopChrome.text(
                  size: 13,
                  medium: true,
                  color: DesktopChrome.accent,
                ).copyWith(
                  decoration: active ? TextDecoration.underline : null,
                  decorationColor: DesktopChrome.accent,
                ),
          ),
        ),
      ),
    );
  }
}

/// The caret after "Looking for your phone" — the phone's "Looking for your
/// computer▌": on for half of every half beat, and steady when nothing moves.
class _Caret extends StatelessWidget {
  const _Caret({required this.beat});

  final AnimationController beat;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsetsDirectional.only(start: 2),
      child: AnimatedBuilder(
        animation: beat,
        builder: (context, _) => Opacity(
          opacity: !beat.isAnimating || (beat.value * 2) % 1 < .5 ? 1 : 0,
          child: Container(width: 7, height: 14, color: DesktopChrome.muted),
        ),
      ),
    ),
  );
}

/// The picture at the top of Add Phone — this computer, the phone, and what
/// runs between them, by [_Link] — the mobile onboarding's picture, small.
class _LinkPicture extends StatelessWidget {
  const _LinkPicture({
    required this.link,
    required this.beat,
    required this.unlock,
  });

  final _Link link;
  final AnimationController beat;
  final AnimationController unlock;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    // Its own layer: the beat repaints the picture, never the dialog.
    child: RepaintBoundary(
      child: AspectRatio(
        aspectRatio: _LinkPainter.width / _LinkPainter.height,
        child: CustomPaint(
          painter: _LinkPainter(
            link: link,
            beat: beat,
            unlock: unlock,
            ink: DesktopChrome.muted,
            faint: grid.AppPalette.textFaint,
            accent: DesktopChrome.accent,
            ok: grid.AppPalette.online,
          ),
        ),
      ),
    ),
  );
}

/// Draws [_LinkPicture] in its own units ([width] × [height]), scaled to fit.
///
/// - **Sign in** ([_Link.signIn], [_Link.signingIn]): the computer in the
///   accent, breathing on the beat, a person on its screen with a ring out from
///   them; a lock in the middle of the dotted way to the phone, which is faint.
/// - **The lock opening** ([unlock] running, once, when the computer signs in
///   from here): the shackle lifts, the lock rises and fades, the dots close
///   over where it was, and a tick on the computer's screen comes and goes.
/// - **Looking** ([_Link.looking]): packets run along the dots to the phone,
///   which rings out.
/// - **Ready** ([_Link.ready]): the way is a line, and the phone is ticked.
///
/// With nothing moving (Reduce Motion), each is its still frame: no ring, no
/// packets, the lock simply gone once signed in.
class _LinkPainter extends CustomPainter {
  _LinkPainter({
    required this.link,
    required this.beat,
    required this.unlock,
    required this.ink,
    required this.faint,
    required this.accent,
    required this.ok,
  }) : super(repaint: Listenable.merge([beat, unlock]));

  static const double width = 356;
  static const double height = 76;

  final _Link link;
  final AnimationController beat;
  final AnimationController unlock;
  final Color ink, faint, accent, ok;

  static double _clamp(double v) => v.clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / width);
    final t = beat.value;
    final moving = beat.isAnimating;
    final asking = link == _Link.signIn || link == _Link.signingIn;
    final ready = link == _Link.ready;
    // The lock opening, 0 to 1, while it runs.
    final u = unlock.isAnimating ? unlock.value : null;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // This computer: asking to be signed in, it takes the accent and breathes;
    // just signed in, it is green a moment and settles.
    final breath = moving
        ? .55 + .45 * (.5 - .5 * math.cos(2 * math.pi * t))
        : 1.0;
    pen.color = asking
        ? accent.withValues(alpha: breath)
        : u != null
        ? Color.lerp(ok, ink, _clamp((u - .6) / .4))!
        : ink;
    canvas.drawRRect(
      RRect.fromLTRBR(40, 16, 102, 54, const Radius.circular(3)),
      pen,
    );
    canvas.drawLine(const Offset(30, 60), const Offset(112, 60), pen);

    if (asking) {
      // Whose it is: a person on its screen, and a ring out from them.
      if (moving) {
        pen.color = accent.withValues(alpha: .6 * (1 - t));
        canvas.drawCircle(const Offset(71, 35), 11 * (.6 + 1.3 * t), pen);
      }
      pen.color = accent;
      canvas.drawCircle(const Offset(71, 31), 4, pen);
      canvas.drawPath(
        Path()
          ..moveTo(63.5, 45)
          ..cubicTo(64.7, 40.8, 67.7, 38.5, 71, 38.5)
          ..cubicTo(74.3, 38.5, 77.3, 40.8, 78.5, 45),
        pen,
      );
    }
    if (u != null) {
      // Signed in: a tick on its screen, there and gone.
      final a = u < .2 ? u / .2 : (u < .7 ? 1.0 : 1 - (u - .7) / .3);
      pen.color = ok.withValues(alpha: _clamp(a));
      canvas.drawPath(
        Path()
          ..moveTo(63, 35.5)
          ..lineTo(68, 40.5)
          ..lineTo(78, 29.5),
        pen,
      );
    }

    // The way to the phone: dots, with the lock's gap in them until it opens.
    final gap = asking ? 1.0 : (u == null ? 0.0 : 1 - _clamp((u - .61) / .22));
    if (ready) {
      pen.color = ok.withValues(alpha: .7);
      canvas.drawLine(const Offset(124, 38), const Offset(270, 38), pen);
    } else {
      for (var x = 124.0; x <= 268; x += 8) {
        final inGap = x + 2 > 185 && x < 209;
        final alpha = inGap ? 1 - gap : 1.0;
        if (alpha <= 0) continue;
        pen.color = faint.withValues(alpha: faint.a * alpha);
        canvas.drawLine(Offset(x, 38), Offset(x + 2, 38), pen);
      }
    }

    // The lock: shut while there is no account; opening once when there is.
    final lockAlpha = asking
        ? 1.0
        : (u == null ? 0.0 : 1 - _clamp((u - .375) / .455));
    if (lockAlpha > 0) {
      final rise = u == null ? 0.0 : -5 * _clamp((u - .375) / .455);
      final lift = u == null ? 0.0 : -2.5 * _clamp((u - .083) / .25);
      pen.color = ink.withValues(alpha: ink.a * lockAlpha);
      canvas.save();
      canvas.translate(0, rise);
      canvas.drawRRect(
        RRect.fromLTRBR(191, 37, 203, 46, const Radius.circular(2)),
        pen,
      );
      canvas.drawPath(
        Path()
          ..moveTo(193.5, 37 + lift)
          ..lineTo(193.5, 34 + lift)
          ..arcToPoint(
            Offset(200.5, 34 + lift),
            radius: const Radius.circular(3.5),
          )
          ..lineTo(200.5, 37 + lift),
        pen,
      );
      canvas.restore();
    }

    if (link == _Link.looking) {
      final dot = Paint()..color = accent;
      if (moving) {
        // Packets along the dots, a third of a beat apart.
        for (var k = 0; k < 3; k++) {
          final q = (t + k / 3) % 1;
          final a = q < .15 ? q / .15 : (q > .85 ? (1 - q) / .15 : 1.0);
          dot.color = accent.withValues(alpha: _clamp(a));
          canvas.drawCircle(Offset(140 + 96 * q, 38), 2.2, dot);
        }
        // The phone rings out, twice a beat.
        for (var k = 0; k < 2; k++) {
          final q = (t + k / 2) % 1;
          pen.color = accent.withValues(alpha: .55 * (1 - q));
          canvas.drawCircle(const Offset(293, 38), 26 * (.7 + .8 * q), pen);
        }
      } else {
        pen.color = accent.withValues(alpha: .3);
        canvas.drawCircle(const Offset(293, 38), 26, pen);
      }
    }

    // The phone: faint until there is an account, then waiting, then in.
    final phone = RRect.fromLTRBR(281, 16, 305, 60, const Radius.circular(5));
    if (ready) {
      canvas.drawRRect(phone, Paint()..color = ok.withValues(alpha: .16));
    }
    pen.color = ready ? ok : (asking ? faint : ink);
    canvas.drawRRect(phone, pen);
    canvas.drawLine(const Offset(290, 55), const Offset(296, 55), pen);
    if (ready) {
      canvas.drawPath(
        Path()
          ..moveTo(287, 38)
          ..lineTo(291, 42)
          ..lineTo(299, 33),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_LinkPainter old) =>
      old.link != link ||
      old.ink != ink ||
      old.faint != faint ||
      old.accent != accent ||
      old.ok != ok;
}

/// Under the phone app's one code, the two stores it opens — each its own mark
/// and name — so nobody wonders whether theirs is one of them.
class _StoreMarks extends StatelessWidget {
  const _StoreMarks();

  /// Each store's mark, in its own colours whatever the theme — it is the
  /// store's brand, the way the sign-in buttons' marks are.
  static const _stores = [
    ('App Store', 'assets/stores/app-store.svg'),
    ('Google Play', 'assets/stores/google-play.svg'),
  ];

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 20,
    runSpacing: 6,
    children: [
      for (final (name, mark) in _stores)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: SvgPicture.asset(mark, width: 18, height: 18),
            ),
            const SizedBox(width: 7),
            Text(
              name,
              style: DesktopChrome.control().copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
    ],
  );
}

/// "Mac" where the menu says Harness ▸ Add Phone…; the command palette also
/// reaches this dialog on Linux, where "this Mac" would be wrong.
String _thisComputer() =>
    defaultTargetPlatform == TargetPlatform.macOS ? 'Mac' : 'computer';

/// The Add Phone QR — [QrCodeView], named for the one thing it is here.
class PhonePairQr extends StatelessWidget {
  const PhonePairQr({super.key, required this.data, required this.side});

  /// What the code says — the whole link, secret included.
  final String data;
  final double side;

  @override
  Widget build(BuildContext context) => QrCodeView(
    data: data,
    side: side,
    semanticLabel: 'QR code to add your phone',
  );
}
