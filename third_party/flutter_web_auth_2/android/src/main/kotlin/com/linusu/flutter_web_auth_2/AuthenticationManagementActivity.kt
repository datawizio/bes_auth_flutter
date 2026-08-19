package com.linusu.flutter_web_auth_2

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.browser.auth.AuthTabIntent
import androidx.browser.auth.AuthTabIntent.AuthResult
import androidx.browser.customtabs.CustomTabsIntent

@SuppressLint("UnsafeOptInUsageError", "UnsafeOptInUsageWarning")
class AuthenticationManagementActivity : ComponentActivity() {
    companion object {
        const val KEY_AUTH_STARTED: String = "authStarted"
        const val KEY_AUTH_URI: String = "authUri"
        const val KEY_AUTH_OPTION_INTENT_FLAGS: String = "authOptionsIntentFlags"
        const val KEY_AUTH_OPTION_TARGET_PACKAGE: String = "authOptionsTargetPackage"
        const val KEY_AUTH_OPTION_PREFER_EPHEMERAL: String = "authOptionsPreferEphemeral"
        const val KEY_AUTH_CALLBACK_SCHEME: String = "authCallbackScheme"
        const val KEY_AUTH_CALLBACK_HOST: String = "authCallbackHost"
        const val KEY_AUTH_CALLBACK_PATH: String = "authCallbackPath"
        const val KEY_AUTH_SESSION_ID: String = "authSessionId"

        fun createResponseHandlingIntent(context: Context): Intent {
            val intent = Intent(context, AuthenticationManagementActivity::class.java)
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return intent
        }
    }

    private var authStarted: Boolean = false
    private lateinit var authenticationUri: Uri
    private var intentFlags: Int = 0
    private var targetPackage: String? = null
    private var preferEphemeral: Boolean = false
    private lateinit var callbackScheme: String
    private var callbackHost: String? = null
    private var callbackPath: String? = null

    // Identifies the one authenticate() call this activity instance belongs to.
    // launchMode is `standard`, so a second open() on the same scheme spawns a
    // second instance while the scheme-keyed callbacks map holds only the newest
    // session. This is how a superseded (stale) instance recognises that the
    // pending callback now belongs to a newer session and must not be touched.
    // -1 is the "never set" sentinel; real ids from the plugin start at 1.
    private var sessionId: Long = -1L

    private lateinit var authLauncher: ActivityResultLauncher<Intent>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Register the activity result launcher
        authLauncher = AuthTabIntent.registerActivityResultLauncher(this, this::handleAuthResult)

        if (savedInstanceState == null) {
            extractState(intent.extras)
        } else {
            extractState(savedInstanceState)
        }
    }

    private fun handleAuthResult(result: AuthResult) {
        val callback = FlutterWebAuth2Plugin.callbacks[callbackScheme]
        if (callback == null) {
            finish()
            return
        }

        when (result.resultCode) {
            AuthTabIntent.RESULT_OK -> {
                val uri = result.resultUri
                if (uri != null) {
                    callback.success(uri.toString())
                } else {
                    callback.error("FAILED", "Authentication returned no URI", null)
                }
            }

            AuthTabIntent.RESULT_CANCELED -> {
                // "Canceled" is also what the Auth Tab reports when the system
                // took it down without the user touching anything, so this line
                // is the difference between a user who gave up and a device that
                // dropped the session.
                Log.w(LOG_TAG, "Auth Tab reported CANCELED for scheme $callbackScheme")
                callback.error("CANCELED", "User canceled authentication", null)
            }

            else -> {
                callback.error("FAILED", "Authentication failed with code: ${result.resultCode}", null)
            }
        }

        FlutterWebAuth2Plugin.callbacks.remove(callbackScheme)
        finish()
    }

    override fun onResume() {
        super.onResume()

        if (!authStarted) {

            val intentBuilder = if (shouldUseAuthTabs()) {
                Log.d(LOG_TAG, "Using AuthTabIntent")
                AuthTabBuilderWrapper(AuthTabIntent.Builder())
            } else {
                Log.d(LOG_TAG, "Using CustomTabsIntent")
                CtBuilderWrapper(CustomTabsIntent.Builder())
            }

            // Set ephemeral browsing if requested and supported
            if (preferEphemeral) {
                try {
                    intentBuilder.setEphemeralBrowsingEnabled(true)
                    Log.d(LOG_TAG, "Ephemeral browsing enabled")
                } catch (e: Exception) {
                    Log.w(LOG_TAG, "Failed to enable ephemeral browsing: ${e.message}")
                }
            }

            val intent = intentBuilder.build()

            intent.intent.addFlags(intentFlags)
            if (targetPackage != null) {
                intent.intent.setPackage(targetPackage)
            }

            // Restore the KEEP_ALIVE wiring older flutter_web_auth versions had: the
            // browser binds to this (empty) service, raising our process importance so
            // the cached-app freezer cannot freeze us while the user is away in a long
            // auth journey (e.g. Google's native sign-in). A frozen process makes the
            // Auth Tab result delivery fail and the login silently die.
            val keepAliveIntent = Intent(this, KeepAliveService::class.java)
            intent.intent.putExtra(
                "android.support.customtabs.extra.KEEP_ALIVE",
                keepAliveIntent
            )

            try {
                if (callbackScheme == "https" && callbackHost != null && callbackPath != null) {
                    Log.d(LOG_TAG, "Using https host and path: $callbackHost, $callbackPath")
                    intent.launch(this, authLauncher, authenticationUri, callbackHost!!, callbackPath!!)
                } else {
                    Log.d(LOG_TAG, "Using custom scheme: $callbackScheme")
                    intent.launch(this, authLauncher, authenticationUri, callbackScheme)
                }
            } catch (e: android.content.ActivityNotFoundException){
                Log.e(LOG_TAG, "Failed to start authentication. No browser available (Activity not found)")
                val callback = FlutterWebAuth2Plugin.callbacks[callbackScheme]
                callback?.error("NO_BROWSER", "No valid browser available for authentication.", e.message)
                FlutterWebAuth2Plugin.callbacks.remove(callbackScheme)
                finish()
            }

            authStarted = true
            return
        }
        /* If the authentication was already started and we've returned here, the user either
         * completed or cancelled authentication.
         * Either way we want to return to our original flutter activity, so just finish here
         */
        // The completed case has already delivered through CallbackActivity (a
        // redirect) or handleAuthResult (the Auth Tab result), both of which
        // remove the callback. If it is STILL pending here, nothing delivered a
        // result and it would dangle forever — the silent sign-in that never
        // ends. Fail it now so Dart's `authenticate` future resolves.
        //
        // But only if this instance still OWNS the scheme's callback. launchMode
        // is `standard`: a second open() on the same scheme spawns a second
        // instance and the plugin advances activeSessionIds[scheme] to the new
        // session. A superseded instance reaching here must NOT remove the map
        // entry — that entry now belongs to the live session the user is still
        // completing, and evicting it would false-abort that login. The ownership
        // check gates the whole remove: a stale instance leaves the map alone. If
        // the id matches but nothing is pending, the result was already delivered
        // (success/cancel) and removed — a normal return, so there is nothing to
        // fail.
        val ownsCallback =
            FlutterWebAuth2Plugin.activeSessionIds[callbackScheme] == sessionId
        if (ownsCallback) {
            val pending = FlutterWebAuth2Plugin.callbacks.remove(callbackScheme)
            FlutterWebAuth2Plugin.activeSessionIds.remove(callbackScheme)
            if (pending != null) {
                if (shouldUseAuthTabs()) {
                    // Auth Tab path: a real cancel arrives through handleAuthResult
                    // (RESULT_CANCELED) and removes the callback before this point,
                    // so a callback still pending here is a genuine drop — the tab
                    // returned without ever delivering a result.
                    Log.w(LOG_TAG, "returning without delivering callback for scheme $callbackScheme; failing it")
                    pending.error("CALLBACK_DROPPED", "Browser returned without delivering a redirect.", null)
                } else {
                    // Custom Tabs path has no result signal at all (launchUrl, no
                    // ActivityResult): returning here without a redirect is the user
                    // dismissing the tab. Report it as a cancel — not a device error
                    // — to match the Auth Tab cancel and keep the Sentry signal clean.
                    Log.w(LOG_TAG, "custom tab dismissed without a redirect for scheme $callbackScheme")
                    pending.error("CANCELED", "User canceled authentication", null)
                }
            }
        } else {
            // Superseded by a newer session on the same scheme (or the process was
            // restarted). Leave the live callback for its own instance to resolve.
            Log.w(LOG_TAG, "stale AuthenticationManagementActivity for scheme $callbackScheme; leaving the live session untouched")
        }
        finish()
    }

    fun shouldUseAuthTabs(): Boolean {

        if (!preferEphemeral || targetPackage == null) return true
        val packageMajorVersion = getInstalledVersion(targetPackage!!)?.substringBefore(".")?.toIntOrNull() ?: 0
        Log.d(LOG_TAG, "Chosen package: $targetPackage with version: $packageMajorVersion")

        val chromePackages = setOf(
            PackageNames.CHROME_STABLE,
            PackageNames.CHROME_BETA,
            PackageNames.CHROME_DEV,
        )

        if (chromePackages.contains(targetPackage)) {
            return packageMajorVersion >= 141
        } else if (targetPackage == PackageNames.MICROSOFT_EDGE) {
            return packageMajorVersion >= 141
        } else if (targetPackage == PackageNames.SAMSUNG_INTERNET) {
            return packageMajorVersion >= 28
        } else if (targetPackage == PackageNames.FIREFOX) {
            return packageMajorVersion >= 143
        }

        return true
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_AUTH_STARTED, authStarted)
        outState.putParcelable(KEY_AUTH_URI, authenticationUri)
        outState.putInt(KEY_AUTH_OPTION_INTENT_FLAGS, intentFlags)
        outState.putString(KEY_AUTH_OPTION_TARGET_PACKAGE, targetPackage)
        outState.putBoolean(KEY_AUTH_OPTION_PREFER_EPHEMERAL, preferEphemeral)
        outState.putString(KEY_AUTH_CALLBACK_SCHEME, callbackScheme)
        outState.putString(KEY_AUTH_CALLBACK_HOST, callbackHost)
        outState.putString(KEY_AUTH_CALLBACK_PATH, callbackPath)
        outState.putLong(KEY_AUTH_SESSION_ID, sessionId)
    }

    private fun extractState(state: Bundle?) {
        if (state == null) {
            finish()
            return
        }
        authStarted = state.getBoolean(KEY_AUTH_STARTED, false)
        authenticationUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            state.getParcelable(KEY_AUTH_URI, Uri::class.java)
        } else {
            @Suppress("deprecation")
            state.getParcelable(KEY_AUTH_URI)
        } ?: throw IllegalStateException("Authentication URI is null")
        intentFlags = state.getInt(KEY_AUTH_OPTION_INTENT_FLAGS, 0)
        targetPackage = state.getString(KEY_AUTH_OPTION_TARGET_PACKAGE)
        preferEphemeral = state.getBoolean(KEY_AUTH_OPTION_PREFER_EPHEMERAL, false)
        callbackScheme = state.getString(KEY_AUTH_CALLBACK_SCHEME)!!
        callbackHost = state.getString(KEY_AUTH_CALLBACK_HOST)
        callbackPath = state.getString(KEY_AUTH_CALLBACK_PATH)
        sessionId = state.getLong(KEY_AUTH_SESSION_ID, -1L)
    }
}
