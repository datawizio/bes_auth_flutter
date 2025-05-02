import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebAuth {
  String redirectUri;

  WebAuth({required this.redirectUri});

  Future<String> open(BuildContext context, String authUrl) async {
    final completer = Completer<String>();

    await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => WebAuthModal(authUrl: authUrl, redirectUri: redirectUri, completer: completer)).then((val) {
      if (!completer.isCompleted) {
        completer.complete('');
      }
    });
    return await completer.future;
  }
}

class WebAuthModal extends StatefulWidget {
  const WebAuthModal({
    super.key,
    required this.authUrl,
    required this.redirectUri,
    required this.completer,
  });

  final String authUrl;
  final String redirectUri;
  final Completer<String> completer;

  @override
  State<WebAuthModal> createState() => _WebAuthModalState();
}

class _WebAuthModalState extends State<WebAuthModal> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();

    WebViewCookieManager().clearCookies();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..clearCache()
      ..clearLocalStorage()
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (NavigationRequest request) {
          String actionOrigin = _getOriginUri(request.url);
          String redirectOrigin = _getOriginUri(widget.redirectUri);

          if (actionOrigin == redirectOrigin) {
            Navigator.pop(context);
            widget.completer.complete(request.url);
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
      }))
      ..loadRequest(Uri.parse(widget.authUrl));
  }

  @override
  void dispose() {
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                controller: _controller,
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
      );
  }

  String _getOriginUri(String uri) {
    Uri fUri = Uri.parse(uri);
    return "${fUri.scheme}://${fUri.host}${fUri.path.isEmpty ? "/" : fUri.path}";
  }
}
