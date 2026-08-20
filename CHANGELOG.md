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

## 0.2.0
* Security: verify an OAuth `state` nonce on the callback and reject a
  redirect whose state does not match the value sent, before the code is
  exchanged — closes an authorization-code injection reachable via a crafted
  ACTION_SEND or direct VIEW intent (custom scheme or https App Link).
* Security: on Android, ACTION_SEND callback recovery now delivers only a URI
  that matches this app's own registered redirect filters, dropping the
  any-scheme fallback.
* Observability: surface previously silent web-auth failures
  (WebAuth.lastFailureCode, OAUTH_ERROR / NO_CODE_IN_REDIRECT, token-exchange
  timeout + status check, Kotlin seam logging that never records the URL).

  NOTE: the state check requires the authorization server to echo `state`
  unchanged (RFC 6749 §10.12) on every redirect variant; verify end-to-end on
  device before release, as a login fails closed if it is stripped.

## 0.2.1
* Reliability: fail a web-auth callback that can never be delivered instead of
  hanging the sign-in forever. Previously, when the Android callback was dropped
  or dangling without a process death, the Dart `authenticate` future never
  completed — the login spinner spun forever with no message and no Sentry
  report. The plugin now completes the pending result with a distinct code:
  `NO_ACTIVITY` (authenticate called with no attached activity, so no browser
  could be launched) and `CALLBACK_DROPPED` (a pending callback superseded by a
  second authenticate on the same scheme, or an Auth Tab that returned without
  delivering a redirect). A dismissed Custom Tab still reports `CANCELED`.
* Correctness: the failure above is gated by a per-session id so a superseded
  management activity cannot evict the live session that replaced it. Two
  sign-ins on one scheme spawn two `standard`-launchMode activities sharing a
  scheme-keyed callback map; without the id, a stale activity reaching its drop
  branch would fail the login the user is still completing. That branch now
  fails only a callback it still owns. The gate covers the drop branch alone —
  the Auth Tab result handler and the no-browser fallback still act on whatever
  callback the scheme currently holds.
* Reliability: `WebAuth.open` now wraps the browser round-trip in a generous
  10-minute backstop; if no callback ever arrives it resolves as an empty
  string with `WebAuth.lastFailureCode = 'TIMEOUT_NO_CALLBACK'` rather than
  awaiting forever. The ceiling is far beyond any real interactive login, so it
  cannot abort one — it only bounds a drop path the plugin fixes do not cover.

  These codes reach the host through `WebAuth.lastFailureCode`; a host that
  reports it (e.g. to Sentry) now gets a distinct identity for each instead of
  a silent hang.

## 0.2.2
* Fix (Android, critical): the 0.2.0 vet on ACTION_SEND callback recovery could
  reject the legitimate redirect. It probed with `ACTION_VIEW` +
  `CATEGORY_BROWSABLE`, which for an https redirect is a *web intent*, and since
  Android 12 the platform answers a web-intent query through domain
  verification — leaving out an app that is not approved for the domain. The
  SEND recovery exists for devices whose App Link never verified, so on exactly
  those devices the vet answered false for the URI it must accept: the callback
  was discarded, the host reported an unknown error, and that user could not
  sign in at all. The probe now carries no category and queries with no
  `MATCH_DEFAULT_ONLY`, so the domain gate cannot engage while the filter match
  is unchanged. What the vet accepts does not widen.
* Observability (Android): the vet's rejection branch logged nothing, so a
  discarded redirect — the branch above — left no trace. It now logs the scheme
  and host of a refused URI, never the query, which carries the code and state.
* Correctness (Android): the per-session ownership gate from 0.2.1 now also
  covers the Auth Tab result handler, not just the drop branch. A superseded
  management activity whose tab was dismissed later could cancel the callback of
  the sign-in that replaced it — reported as `CANCELED`, which a host tends to
  treat as "the user changed their mind" and say nothing about. A stale instance
  now finishes without touching the callback map. The delivery path of a normal
  sign-in is unchanged: the platform delivers an activity result before it
  resumes the activity, so the live instance still owns its session when its
  result arrives.
* Reliability: `refreshToken` and `logout` now use the same 30-second ceiling
  the token exchange got in 0.2.0. Both were unbounded, and a black-holed
  connection is not a socket error — the request simply never completes, which
  on the refresh path is a returning session that never resolves. Their failure
  shapes are unchanged: a refresh answers null only when the server refuses the
  token, so a dead network is still not mistaken for a rejected refresh token.
* `refreshToken` now sends the app's `USER-AGENT`, which the token exchange
  already sent to the same endpoint; refreshes were arriving as a bare
  `Dart/x.y (dart:io)`. A failed token revocation is logged instead of being
  discarded unread.
* `BesAuth` takes an optional `httpClient` for tests. Left unset — the
  production case — every request goes through the top-level `http.post`
  exactly as before.
