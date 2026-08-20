import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:bes_auth_flutter/bes_auth_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The token exchange stamps a User-Agent built from PackageInfo; without a
  // mocked value that call goes to a platform channel no test host answers.
  // The device half of the string comes from dart:io on a test host, no plugin.
  PackageInfo.setMockInitialValues(
    appName: 'bes_auth_flutter_test',
    packageName: 'io.datawiz.test',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

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

    // The Dart side of the supersede contract: when a second sign-in starts on
    // the same scheme before the first round-trips, the plugin fails the first
    // (CALLBACK_DROPPED) and lets the second proceed. Modelled at the mock
    // boundary — the plugin's stale-instance ownership guard is Kotlin and
    // device-QA only. What this locks is that one open()'s failure never
    // corrupts a concurrent open()'s own result: the superseded first resolves
    // empty, the live second still returns its own redirect.
    test('a superseded first open does not abort a concurrent second', () async {
      final auth = WebAuth(redirectUri: 'app://callback');
      final first = Completer<Object?>();
      var authenticateCalls = 0;
      answerWith((call) async {
        if (call.method != 'authenticate') return null;
        authenticateCalls++;
        if (authenticateCalls == 1) {
          return first.future; // first session's browser is still outstanding
        }
        // A second authenticate on the same scheme: the plugin drops the first
        // and the second goes on to succeed.
        if (!first.isCompleted) {
          first.completeError(PlatformException(
              code: 'CALLBACK_DROPPED',
              message: 'Superseded by a newer authentication.'));
        }
        return 'app://callback?code=SECOND';
      });

      final f1 = auth.open('https://example.test/o/authorize/');
      final f2 = auth.open('https://example.test/o/authorize/');

      expect(await f1, '', reason: 'the superseded first resolves, not hangs');
      expect(await f2, 'app://callback?code=SECOND',
          reason: 'the live second session must not be aborted');
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

    setUp(() {
      WebAuth.lastFailureCode = null;
      WebAuth.lastFailureMessage = null;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    const tokenJson = '{"scope":"read write","expires_in":36000,'
        '"token_type":"Bearer","access_token":"ACCESS",'
        '"refresh_token":"REFRESH"}';

    // Every exchange the test lets through is recorded here, so a test can
    // assert both that the code WAS exchanged and what it was exchanged with —
    // and, on the rejection tests, that it was never exchanged at all.
    late List<Map<String, String>> exchanges;

    BesAuth newAuth({http.Response Function()? answer}) => BesAuth(
          clientId: 'client',
          serviceUrl: 'bes.example',
          redirectPath: 'callback',
          clientSecret: 'secret',
          // No network in either direction: the browser is the method-channel
          // mock above, the token endpoint is this client. A test that reaches
          // the exchange gets a real BesSession back, so the assertions can be
          // about behaviour instead of about which exception came out.
          httpClient: MockClient((request) async {
            exchanges.add(Uri.splitQueryString(request.body));
            return answer?.call() ?? http.Response(tokenJson, 200);
          }),
        );

    setUp(() => exchanges = []);

    test('sends a non-empty state on the authorize request', () async {
      String? sentState;
      answerAuthenticateWith((authUrl) {
        sentState = authUrl.queryParameters['state'];
        return 'app://callback?code=GOOD&state=${sentState ?? ''}';
      });

      final session = await newAuth().authenticate();

      expect(sentState, isNotNull, reason: 'state must be on the authorize URL');
      expect(sentState, isNotEmpty);
      expect(session?.accessToken, 'ACCESS',
          reason: 'the sign-in must complete when the state echoes back');
    });

    test('accepts a redirect whose state echoes the value sent', () async {
      // The server MUST echo state unchanged (RFC 6749 §10.12); model that by
      // reading it off the auth URL and handing it straight back with the code.
      answerAuthenticateWith((authUrl) =>
          'app://callback?code=GOOD&state=${authUrl.queryParameters['state']}');

      final session = await newAuth().authenticate();

      // Matching state → gate passes → the code is exchanged, with the code the
      // redirect carried. Asserting the exchange itself is what makes this test
      // fail if the gate ever rejects a legitimate redirect.
      expect(exchanges, hasLength(1));
      expect(exchanges.single['code'], 'GOOD');
      expect(exchanges.single['grant_type'], 'authorization_code');
      expect(exchanges.single['client_id'], 'client');
      expect(exchanges.single['redirect_uri'], 'app://callback');
      expect(session, isA<BesSession>());
      expect(session!.accessToken, 'ACCESS');
      expect(session.refreshToken, 'REFRESH');
      expect(WebAuth.lastFailureCode, isNull);
    });

    test('rejects an injected redirect that carries no state', () async {
      // The attack 56ecb7a could not close: app://<our-redirect>/?code=... ,
      // matching our own filter, delivered to the pending session — no state.
      answerAuthenticateWith((_) => 'app://callback?code=ATTACKER_CODE');

      await expectLater(
        newAuth().authenticate(),
        throwsA(isA<StateMismatchException>()),
      );
      expect(exchanges, isEmpty,
          reason: 'the injected code must never reach the token endpoint');
    });

    test('rejects a redirect whose state is not the value sent', () async {
      answerAuthenticateWith(
          (_) => 'app://callback?code=ATTACKER_CODE&state=not-the-nonce');

      await expectLater(
        newAuth().authenticate(),
        throwsA(isA<StateMismatchException>()),
      );
      expect(exchanges, isEmpty,
          reason: 'the injected code must never reach the token endpoint');
    });

    // The two redirect shapes that used to be folded into the same '' as "the
    // browser never came back". Both are reachable only past the state gate,
    // because a legitimate error redirect echoes state like any other.
    test('reports an authorize error as OAUTH_ERROR, not a silent empty answer',
        () async {
      answerAuthenticateWith((authUrl) =>
          'app://callback?state=${authUrl.queryParameters['state']}'
          '&error=access_denied&error_description=User%20denied%20access');

      final session = await newAuth().authenticate();

      expect(session, isNull);
      expect(WebAuth.lastFailureCode, 'OAUTH_ERROR');
      expect(WebAuth.lastFailureMessage, 'User denied access');
      expect(exchanges, isEmpty, reason: 'there was no code to exchange');
    });

    test('reports a redirect with neither code nor error as NO_CODE_IN_REDIRECT',
        () async {
      answerAuthenticateWith((authUrl) =>
          'app://callback?state=${authUrl.queryParameters['state']}');

      final session = await newAuth().authenticate();

      expect(session, isNull);
      expect(WebAuth.lastFailureCode, 'NO_CODE_IN_REDIRECT');
      expect(WebAuth.lastFailureMessage, isNull);
      expect(exchanges, isEmpty);
    });
  });
}
