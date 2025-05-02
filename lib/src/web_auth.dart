import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebAuth {
  String redirectUri;

  WebAuth({required this.redirectUri});

  Future<String> open(BuildContext context, String authUrl) async {
    Completer completer = Completer<String>();
    WebViewCookieManager().clearCookies();

    await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => Scaffold(
          resizeToAvoidBottomInset: false,
            body: Stack(children: [
              Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: MediaQuery.of(context).size.height * 0.07,
                    color: const Color(0xFF120338),
                  )),
              Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.94,
                  child: WebViewWidget(
                    controller: WebViewController()
                      ..setJavaScriptMode(JavaScriptMode.unrestricted)
                      ..clearCache()
                      ..clearLocalStorage()
                      ..setNavigationDelegate(NavigationDelegate(
                        onNavigationRequest: (NavigationRequest request) {
                          String actionOrigin = _getOriginUri(request.url);
                          String redirectOrigin = _getOriginUri(redirectUri);

                          if (actionOrigin == redirectOrigin) {
                            Navigator.pop(context);
                            completer.complete(request.url);
                            return NavigationDecision.prevent;
                          }

                          return NavigationDecision.navigate;
                      }))
                      ..loadRequest(Uri.parse(authUrl)),
                    gestureRecognizers: <
                        Factory<OneSequenceGestureRecognizer>>{
                      Factory<OneSequenceGestureRecognizer>(
                        () => EagerGestureRecognizer(),
                      ),
                    },
                  ),
                ),
              ),
              Positioned(
                  top: MediaQuery.of(context).size.height * 0.07,
                  right: 10,
                  child: InkWell(
                    child: const Icon(Icons.close, color: Colors.white),
                    onTap: () => Navigator.pop(context),
                  )),
            ]),
          )).then((val) {
      if (!completer.isCompleted) {
        completer.complete('');
      }
    });
    return await completer.future;
  }

  String _getOriginUri(String uri) {
    Uri fUri = Uri.parse(uri);
    return "${fUri.scheme}://${fUri.host}${fUri.path.isEmpty ? "/" : fUri.path}";
  }
}
