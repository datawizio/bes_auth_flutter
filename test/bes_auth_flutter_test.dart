import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bes_auth_flutter/bes_auth_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebAuth.open', () {
    const channel = MethodChannel('flutter_web_auth_2');

    void answerWith(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    setUp(() {
      WebAuth.lastFailureCode = null;
      WebAuth.lastFailureMessage = null;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // The whole point of the field: `open` answers '' for every one of these,
    // so the code is the only thing left that says which one happened.
    test('remembers the plugin code behind an empty answer', () async {
      answerWith((call) async => throw PlatformException(
          code: 'CANCELED', message: 'User canceled authentication'));

      final result = await WebAuth(redirectUri: 'app://callback')
          .open('https://example.test/o/authorize/');

      expect(result, '', reason: 'the return type is compatibility surface');
      expect(WebAuth.lastFailureCode, 'CANCELED');
      expect(WebAuth.lastFailureMessage, 'User canceled authentication');
    });

    test('separates a device problem from a user who gave up', () async {
      answerWith((call) async => throw PlatformException(
          code: 'NO_BROWSER',
          message: 'No valid browser available for authentication.'));

      await WebAuth(redirectUri: 'app://callback')
          .open('https://example.test/o/authorize/');

      expect(WebAuth.lastFailureCode, 'NO_BROWSER');
    });

    // Left set, the code from a failure two sign-ins ago reads as the reason
    // for a session that is working.
    test('forgets the last failure once a sign-in succeeds', () async {
      answerWith((call) async => throw PlatformException(code: 'CANCELED'));
      final auth = WebAuth(redirectUri: 'app://callback');
      await auth.open('https://example.test/o/authorize/');
      expect(WebAuth.lastFailureCode, isNotNull);

      answerWith((call) async => 'app://callback?code=abc123');
      final result = await auth.open('https://example.test/o/authorize/');

      expect(result, 'app://callback?code=abc123');
      expect(WebAuth.lastFailureCode, isNull);
      expect(WebAuth.lastFailureMessage, isNull);
    });

    // GAP 1 — the Android plugin used to drop an undeliverable callback in
    // silence, so Dart's `authenticate` future never completed and the sign-in
    // button spun forever with nothing said. The plugin now fails the pending
    // Result with a distinct code instead of dropping it. These lock the two
    // codes it emits so they survive the round-trip to a host that reads
    // lastFailureCode (the fix that makes each one a separable Sentry identity).

    // Emitted when the plugin is asked to authenticate with no attached
    // activity: there is nothing to launch a browser from, so it fails now
    // rather than storing a callback that can never be launched.
    test('carries NO_ACTIVITY through instead of hanging', () async {
      answerWith((call) async => throw PlatformException(
          code: 'NO_ACTIVITY',
          message: 'Plugin is not attached to an activity.'));

      final result = await WebAuth(redirectUri: 'app://callback')
          .open('https://example.test/o/authorize/');

      expect(result, '');
      expect(WebAuth.lastFailureCode, 'NO_ACTIVITY');
      expect(WebAuth.lastFailureMessage, 'Plugin is not attached to an activity.');
    });

    // Emitted when a pending callback is abandoned: superseded by a second
    // authenticate on the same scheme, or a browser that returned without ever
    // delivering the redirect.
    test('carries CALLBACK_DROPPED through, distinct from a cancel', () async {
      answerWith((call) async => throw PlatformException(
          code: 'CALLBACK_DROPPED',
          message: 'Browser closed without delivering a redirect.'));

      final result = await WebAuth(redirectUri: 'app://callback')
          .open('https://example.test/o/authorize/');

      expect(result, '');
      expect(WebAuth.lastFailureCode, 'CALLBACK_DROPPED');
      expect(WebAuth.lastFailureCode, isNot('CANCELED'));
    });

    // Defensive backstop for any drop path the plugin fixes do not cover: a
    // callback that simply never arrives must not hang `authenticate` forever.
    // Driven on fake time so the real 10-minute deadline is exercised honestly
    // without the test waiting for it.
    test('times out a callback that never arrives, and not a slow login', () {
      fakeAsync((async) {
        final never = Completer<Object?>(); // a browser that never comes back
        answerWith((call) => never.future);

        String? result;
        WebAuth(redirectUri: 'app://callback')
            .open('https://example.test/o/authorize/')
            .then((r) => result = r);

        // Nine minutes in, a genuinely slow interactive login is still going:
        // the backstop must not have fired.
        async.elapse(const Duration(minutes: 9));
        async.flushMicrotasks();
        expect(result, isNull,
            reason: 'a real login in progress must never be aborted early');

        // Past the deadline the future resolves to the same empty-string
        // failure shape as a caught error, carrying the timeout code.
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(result, '');
        expect(WebAuth.lastFailureCode, 'TIMEOUT_NO_CALLBACK');
        expect(WebAuth.lastFailureMessage, isNotNull);
      });
    });
  });

  group('BesAuth OAuth state (authorization-code-injection guard)', () {
    const channel = MethodChannel('flutter_web_auth_2');

    // Mock the browser round-trip: read the URL the app opened, hand the test's
    // redirect builder the `state` the app actually generated, and answer with
    // whatever redirect the test wants back.
    void answerAuthenticateWith(String Function(Uri authUrl) buildRedirect) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'authenticate') return null;
        final url = Uri.parse((call.arguments as Map)['url'] as String);
        return buildRedirect(url);
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    BesAuth newAuth() => BesAuth(
          clientId: 'client',
          // `.invalid` never resolves (RFC 6761). If the state gate passes, the
          // token exchange fails fast on this host instead of a real network —
          // so a test reaching exchange throws something that is *not* a
          // StateMismatchException, which is exactly the signal we assert on.
          serviceUrl: 'bes.invalid',
          redirectPath: 'callback',
          clientSecret: 'secret',
        );

    test('sends a non-empty state on the authorize request', () async {
      String? sentState;
      answerAuthenticateWith((authUrl) {
        sentState = authUrl.queryParameters['state'];
        return 'app://callback?code=GOOD&state=${sentState ?? ''}';
      });

      await expectLater(
        newAuth().authenticate(),
        throwsA(isNot(isA<StateMismatchException>())),
      );
      expect(sentState, isNotNull, reason: 'state must be on the authorize URL');
      expect(sentState, isNotEmpty);
    });

    test('accepts a redirect whose state echoes the value sent', () async {
      // The server MUST echo state unchanged (RFC 6749 §10.12); model that by
      // reading it off the auth URL and handing it straight back with the code.
      answerAuthenticateWith((authUrl) =>
          'app://callback?code=GOOD&state=${authUrl.queryParameters['state']}');

      // Matching state → gate passes → the code exchange is attempted (and only
      // then fails, for a reason that is not a state mismatch).
      await expectLater(
        newAuth().authenticate(),
        throwsA(isNot(isA<StateMismatchException>())),
      );
    });

    test('rejects an injected redirect that carries no state', () async {
      // The attack 56ecb7a could not close: app://<our-redirect>/?code=... ,
      // matching our own filter, delivered to the pending session — no state.
      answerAuthenticateWith((_) => 'app://callback?code=ATTACKER_CODE');

      await expectLater(
        newAuth().authenticate(),
        throwsA(isA<StateMismatchException>()),
      );
    });

    test('rejects a redirect whose state is not the value sent', () async {
      answerAuthenticateWith(
          (_) => 'app://callback?code=ATTACKER_CODE&state=not-the-nonce');

      await expectLater(
        newAuth().authenticate(),
        throwsA(isA<StateMismatchException>()),
      );
    });
  });
}
