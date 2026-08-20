import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'web_auth.dart';
import 'constants.dart';
import 'bes_session.dart';

/// Thrown when the `state` on the OAuth redirect does not match the random
/// value this client put on the authorization request.
///
/// A matching `state` is the only thing that ties a returned authorization
/// `code` to the sign-in the user actually started. A redirect injected by a
/// hostile app — a bare `code`, or one carrying a `state` this app never
/// issued — fails this check and is rejected before the code is exchanged, so
/// the victim is never signed into the attacker's account. The check lives in
/// Dart, so it holds for a redirect delivered by a direct VIEW intent too, not
/// only the SEND path the Kotlin layer already vets.
class StateMismatchException implements Exception {
  StateMismatchException([this.message = 'OAuth state did not match']);

  final String message;

  @override
  String toString() => 'StateMismatchException: $message';
}

class BesAuth {
  String clientId;
  String serviceUrl;
  String clientSecret;
  String redirectPath;
  final String? redirectUriOverride;
  late WebAuth _webAuth;

  /// [httpClient] exists so a test can drive the token endpoints without a
  /// network: left null (the production case) every request goes through the
  /// top-level `http.post`, i.e. a one-shot client per call, exactly as before.
  BesAuth({
    required this.clientId,
    required this.serviceUrl,
    required this.redirectPath,
    required this.clientSecret,
    this.redirectUriOverride,
    http.Client? httpClient,
  }) : _httpClient = httpClient {
    _webAuth = WebAuth(
      redirectUri: redirectUri,
    );
  }

  final http.Client? _httpClient;

  Future<http.Response> _post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) {
    final client = _httpClient;
    return client == null
        ? http.post(url, headers: headers, body: body)
        : client.post(url, headers: headers, body: body);
  }

  /// Full OAuth callback URL. [redirectUriOverride] wins when provided
  /// (e.g. an https App Link on Android); otherwise the legacy custom
  /// scheme `app://<redirectPath>` (still used by iOS).
  String get redirectUri =>
      redirectUriOverride ?? "$CAllBACK_URL_SCHEMA://$redirectPath";

  Future<BesSession?> authenticate([BuildContext? context]) async {
    String code = await _openWebLogin();
    if (code == '') return null;
    return await _getTokensWithCode(code);
  }

  ///Return null if refresh was failed else return new BesSession
  Future<BesSession?> refreshToken(String token) async {
    return await _post(Uri.https(serviceUrl, GET_TOKENS_PATH), body: {
      "client_id": clientId,
      'refresh_token': token,
      "redirect_uri": redirectUri,
      "client_secret": clientSecret,
      "grant_type": "refresh_token",
    }).then((response) {
      if (response.statusCode == 200) {
        return BesSession.fromJson(response.body);
      } else {
        return null;
      }
    });
  }

  Future<void> logout(BesSession session) async {
    await _post(Uri.https(serviceUrl, REVOKE_TOKEN_PATH), body: {
      "client_id": clientId,
      "token": session.accessToken,
      "client_secret": clientSecret,
    });
  }

  Future<String> _openWebLogin() async {
    // Hit the OAuth authorize endpoint with `force_login=true`, which tells
    // BES to re-authenticate the user (drop its own session) instead of
    // silently signing them back in:
    //   /o/authorize/?response_type=code&client_id=...&redirect_uri=...&state=...&force_login=true
    // Cookies on other domains (e.g. Google SSO) stay intact, so the user can
    // pick a different account on every sign-in.
    //
    // `state` is a fresh random nonce, unique to this flow, that the server
    // must echo back on the redirect (RFC 6749 §10.12). The callback below
    // rejects any redirect that does not carry it, which is what stops a
    // hostile app from injecting its own `code` into this pending session.
    final state = _generateState();
    final url = "${Uri.https(serviceUrl, AUTHORIZE_PATH)}?"
        "response_type=code"
        "&client_id=$clientId"
        "&redirect_uri=$redirectUri"
        "&state=$state"
        "&force_login=true";
    return await _webAuth.open(url).then((response) {
      if (response == '') return response;
      final params = Uri.parse(response).queryParameters;

      // Authorization-code-injection guard. A redirect that did not come from
      // the request we just sent cannot carry the `state` we put on it, so a
      // missing or non-matching value means the `code` beside it is not ours —
      // reject before it is read, let alone exchanged. Both the VIEW and the
      // SEND-recovery paths deliver the full redirect URI with its query, so a
      // legitimate `state` is present on either; recovery is not exempt.
      final returnedState = params["state"];
      if (returnedState == null || !_constantTimeEquals(returnedState, state)) {
        throw StateMismatchException(returnedState == null
            ? 'the redirect carried no state'
            : 'the returned state did not match the value sent');
      }

      final code = params["code"];
      if (code != null) return code;

      // A redirect that came back, and came back refusing. Folding it into the
      // same '' as "the browser never returned" is what made an
      // `access_denied` from BES indistinguishable from a closed tab.
      final error = params["error"];
      if (error != null) {
        debugPrint('[bes_auth] authorize returned an error: $error'
            '${params["error_description"] == null ? '' : ' — ${params["error_description"]}'}');
        WebAuth.lastFailureCode = 'OAUTH_ERROR';
        WebAuth.lastFailureMessage = params["error_description"] ?? error;
      } else {
        debugPrint('[bes_auth] redirect carried neither a code nor an error');
        WebAuth.lastFailureCode = 'NO_CODE_IN_REDIRECT';
        WebAuth.lastFailureMessage = null;
      }
      return '';
    });
  }

  Future<BesSession> _getTokensWithCode(String code) async {
    final userAgent = await _generateUserAgent();

    final response = await _post(Uri.https(serviceUrl, GET_TOKENS_PATH),
        body: {
          "code": code,
          "client_id": clientId,
          "redirect_uri": redirectUri,
          "client_secret": clientSecret,
          "grant_type": "authorization_code",
        },
        // Unbounded, this hangs on a captive portal or a black-holed connection
        // for as long as the OS lets it, with the sign-in button spinning.
        headers: {'USER-AGENT': userAgent}).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      // The old code handed an error body straight to BesSession.fromJson,
      // which read fields that were not there — so a rejected exchange surfaced
      // as a TypeError naming a token field, and the app's catch showed the
      // user a message about something that was never the problem.
      throw Exception(
          'BES token exchange failed: HTTP ${response.statusCode}');
    }
    return BesSession.fromJson(response.body);
  }

  /// A fresh, unguessable `state` nonce for one authorization request.
  ///
  /// 32 bytes from [Random.secure] (256 bits), base64url without padding so the
  /// value is URL-safe and needs no further encoding in the query string.
  String _generateState() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Length-checked, difference-accumulating string compare. `state` is a
  /// client-side nonce, so a timing side-channel is not realistically reachable
  /// here — plain `==` would be sound — but the loop is cheap and settles the
  /// question outright.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Повертає User-Agent виду:
  /// "Mozilla/5.0 (<OSName> <OSVersion>; <DeviceModel>; DeviceID/<DeviceId>) <AppName>/<AppVersion>"
  Future<String> _generateUserAgent() async {
    final pkg = await PackageInfo.fromPlatform();
    final appName = pkg.appName;
    final appVersion = pkg.version;

    final deviceInfo = DeviceInfoPlugin();

    String osName;
    String osVersion;
    String deviceModel;
    String deviceId;

    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;

      osName = 'Android';
      osVersion = info.version.release;
      deviceModel = '${info.brand} ${info.model}'.trim();
      deviceId = info.id;
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;

      osName = 'iOS';
      osVersion = info.systemVersion;
      deviceModel = info.utsname.machine;
      deviceId = info.identifierForVendor ?? 'unknown';
    } else {
      osName = Platform.operatingSystem;
      osVersion = Platform.operatingSystemVersion;
      deviceModel = Platform.localHostname;
      deviceId = Platform.localHostname;
    }

    // 3. Складаємо сам User-Agent
    final comment = '$osName $osVersion; $deviceModel; DeviceID/$deviceId';
    return 'Mozilla/5.0 ($comment) $appName/$appVersion';
  }
}
