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

  /// Launches [authUrl] in the system browser and returns the full
  /// redirect URL once the IdP navigates back to [redirectUri], or an
  /// empty string if the user cancels the flow.
  Future<String> open(String authUrl) async {
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: callbackUrlScheme,
      );
      return result;
    } on Exception {
      return '';
    }
  }
}
