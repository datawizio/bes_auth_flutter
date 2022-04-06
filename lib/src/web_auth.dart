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
    await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => Scaffold(
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
                    child: WebView(
                      initialUrl: authUrl,
                      gestureRecognizers: <
                          Factory<OneSequenceGestureRecognizer>>{
                        Factory<OneSequenceGestureRecognizer>(
                          () => EagerGestureRecognizer(),
                        ),
                      },
                      javascriptMode: JavascriptMode.unrestricted,
                      navigationDelegate: (action) {
                        String actionOrigin = _getOriginUri(action.url);
                        String redirectOrigin = _getOriginUri(redirectUri);

                        if (actionOrigin == redirectOrigin) {
                          Navigator.pop(context);
                          completer.complete(action.url);
                          return NavigationDecision.prevent;
                        }
                        return NavigationDecision.navigate;
                      },
                      onWebViewCreated: (WebViewController controller) {
                        CookieManager().clearCookies();
                        controller.clearCache();
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
