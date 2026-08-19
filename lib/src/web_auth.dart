import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Opens the SSO/OAuth authorize URL in the system browser
/// (ASWebAuthenticationSession on iOS, Chrome Custom Tabs / Auth Tab on
/// Android) so that existing browser/IdP cookies (e.g. an active Google
/// SSO session) are reused and the user is not asked to re-enter
/// credentials on every login.
class WebAuth {
  /// Full callback URL the IdP will redirect to, e.g. `app://callback`.
  final String redirectUri;

  WebAuth({required this.redirectUri});

  /// The scheme part of [redirectUri]. Must be registered with the host
  /// app (Info.plist on iOS, intent-filter on Android) so the OS can
  /// route the redirect back to the app.
  String get callbackUrlScheme => Uri.parse(redirectUri).scheme;

  /// Why the last [open] came back empty, or null after one that succeeded.
  ///
  /// [open] answers the same empty string for a user who closed the tab, a
  /// browser that never came back, and a platform channel that threw — and the
  /// return type cannot be widened without breaking every caller. This is where
  /// the difference survives: `CANCELED` is a user, anything else is a bug or a
  /// device problem, and the caller can finally tell a support ticket which.
  static String? lastFailureCode;

  /// The failure's own words, for the code that carries no detail of its own.
  static String? lastFailureMessage;

  /// Launches [authUrl] in the system browser and returns the full
  /// redirect URL once the IdP navigates back to [redirectUri], or an
  /// empty string if the user cancels the flow.
  Future<String> open(String authUrl) async {
    try {
      final uri = Uri.parse(redirectUri);
      final isHttps = uri.scheme == 'https';
      final result = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: callbackUrlScheme,
        options: FlutterWebAuth2Options(
          // For https App Links (Android) the OS verifies host+path against
          // the domain's assetlinks.json. Null for custom schemes (iOS app://).
          httpsHost: isHttps ? uri.host : null,
          httpsPath: isHttps ? uri.path : null,
        ),
      );
      lastFailureCode = null;
      lastFailureMessage = null;
      return result;
    } on PlatformException catch (e) {
      // The plugin's own vocabulary: CANCELED, FAILED, NO_BROWSER. Every one of
      // them used to arrive here and leave as the same empty string.
      lastFailureCode = e.code;
      lastFailureMessage = e.message;
      debugPrint('[bes_auth] web auth failed: ${e.code} ${e.message ?? ''}');
      return '';
    } on Exception catch (e) {
      lastFailureCode = 'UNKNOWN';
      lastFailureMessage = e.toString();
      debugPrint('[bes_auth] web auth failed with a non-platform error: $e');
      return '';
    }
  }
}
