## 0.0.1

* Initial release.

## 0.0.2
* Fix exeption on auth failing

## 0.0.4
* Fixed webview scroll

## 0.0.6
* Added close button

## 0.0.9
* Now window opens in fullscreen mode

## 0.0.10
* Add "resizeToAvoidBottomInset: false" for auth view

## 0.1.0
* SSO/OAuth login now runs in the system browser via `flutter_web_auth_2`
  (`ASWebAuthenticationSession` on iOS, Chrome Custom Tabs / Auth Tab on
  Android) instead of an embedded `WebView`. This fixes the bug where SAML
  SSO users had to re-enter their Google credentials on every login —
  Safari/Chrome cookies (and therefore the active Google session) are now
  reused.
* Removed the in-app WebView UI and the `webview_flutter` dependency.
* `BesAuth.authenticate(...)`: the `BuildContext` argument is now optional
  (the system browser does not need it). Existing call sites that still
  pass a context continue to compile without changes.
* Minimum platform versions bumped to iOS 12.0 and Android API 21
  (required by `flutter_web_auth_2` / `ASWebAuthenticationSession`).
* Consumers must register the SSO callback URL scheme — see README
  ("SSO via system browser").