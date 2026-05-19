import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'web_auth.dart';
import 'constants.dart';
import 'bes_session.dart';

class BesAuth {
  String clientId;
  String serviceUrl;
  String clientSecret;
  String redirectPath;
  late WebAuth _webAuth;

  BesAuth({
    required this.clientId,
    required this.serviceUrl,
    required this.redirectPath,
    required this.clientSecret,
  }) {
    _webAuth = WebAuth(
      redirectUri: redirectUri,
    );
  }

  String get redirectUri => "$CAllBACK_URL_SCHEMA://$redirectPath";

  Future<BesSession?> authenticate([BuildContext? context]) async {
    String code = await _openWebLogin();
    if (code == '') return null;
    return await _getTokensWithCode(code);
  }

  ///Return null if refresh was failed else return new BesSession
  Future<BesSession?> refreshToken(String token) async {
    return await http.post(Uri.https(serviceUrl, GET_TOKENS_PATH), body: {
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
    await http.post(Uri.https(serviceUrl, REVOKE_TOKEN_PATH), body: {
      "client_id": clientId,
      "token": session.accessToken,
      "client_secret": clientSecret,
    });
  }

  Future<String> _openWebLogin() async {
    String url = Uri.https(serviceUrl, AUTHORIZE_PATH, {
      "response_type": "code",
      "client_id": clientId,
      "redirect_uri": redirectUri,
    }).toString();
    return await _webAuth.open(url).then((response) {
      if (response == '') return response;
      return Uri.parse(response).queryParameters["code"] ?? '';
    });
  }

  Future<BesSession> _getTokensWithCode(String code) async {
    final userAgent = await _generateUserAgent();

    return await http.post(Uri.https(serviceUrl, GET_TOKENS_PATH), body: {
      "code": code,
      "client_id": clientId,
      "redirect_uri": redirectUri,
      "client_secret": clientSecret,
      "grant_type": "authorization_code",
    }, headers: {
      'USER-AGENT': userAgent
    }).then((response) => BesSession.fromJson(response.body));
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
