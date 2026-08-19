import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bes_auth_flutter/bes_auth_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
