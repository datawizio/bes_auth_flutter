package com.linusu.flutter_web_auth_2

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.browser.customtabs.CustomTabsClient

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class FlutterWebAuth2Plugin(
    private var context: Context? = null,
    private var channel: MethodChannel? = null,
    private var activity: Activity? = null,
) : MethodCallHandler, FlutterPlugin, ActivityAware {
    companion object {
        val callbacks = mutableMapOf<String, Result>()

        // The session id that currently owns each scheme's pending callback, and
        // a monotonic source for it. `callbacks` is keyed only by scheme, but a
        // `standard`-launchMode AuthenticationManagementActivity can outlive its
        // session when a second open() on the same scheme replaces it; the stale
        // instance carries an older id and consults this map to avoid evicting the
        // live session that took its place. Written together with `callbacks` on
        // the main thread, so an entry here always names the session whose Result
        // is under the same scheme in `callbacks`. Never needs pruning: it is
        // overwritten per authenticate and only ever read behind a `callbacks`
        // presence check, so a stale entry from a delivered session is harmless.
        val activeSessionIds = mutableMapOf<String, Long>()
        private var sessionCounter = 0L
        fun nextSessionId(): Long = ++sessionCounter
    }

    private fun initInstance(messenger: BinaryMessenger, context: Context) {
        this.context = context
        channel = MethodChannel(messenger, "flutter_web_auth_2")
        channel?.setMethodCallHandler(this)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        initInstance(binding.binaryMessenger, binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = null
        channel = null
    }

    override fun onMethodCall(call: MethodCall, resultCallback: Result) {
        when (call.method) {
            "authenticate" -> {
                val url = Uri.parse(call.argument("url"))
                val callbackUrlScheme: String = call.argument<String>("callbackUrlScheme")!!
                val options = call.argument<Map<String, Any>>("options")!!

                val activity = this.activity
                if (activity == null) {
                    // No attached activity: nothing can launch the browser, so
                    // storing the callback would leave Dart's `authenticate`
                    // future pending forever (no browser opens → no redirect → no
                    // resume to complete it). Fail it now with a distinct code the
                    // host can report, and store nothing that could dangle.
                    resultCallback.error(
                        "NO_ACTIVITY",
                        "Plugin is not attached to an activity; cannot launch the browser.",
                        null
                    )
                    return
                }

                // A previous authenticate for this same scheme whose callback
                // never resolved would be silently overwritten by the next line,
                // stranding its Result forever. Fail it first so its Dart future
                // resolves instead of hanging.
                callbacks.remove(callbackUrlScheme)?.error(
                    "CALLBACK_DROPPED",
                    "Superseded by a newer authentication for the same callback scheme.",
                    null
                )

                // Tag this session so a superseded (stale) management activity can
                // tell it no longer owns the scheme's callback (see
                // AuthenticationManagementActivity). Set together with `callbacks`
                // on the main thread, so the two never disagree.
                val sessionId = nextSessionId()
                callbacks[callbackUrlScheme] = resultCallback
                activeSessionIds[callbackUrlScheme] = sessionId
                activity.startActivity(Intent(activity, AuthenticationManagementActivity::class.java).apply {
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_URI, url)
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_OPTION_INTENT_FLAGS, options["intentFlags"] as Int)
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_OPTION_TARGET_PACKAGE, findTargetBrowserPackageName(options))
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_CALLBACK_SCHEME, callbackUrlScheme)
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_CALLBACK_HOST, options["httpsHost"] as String?)
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_CALLBACK_PATH, options["httpsPath"] as String?)
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_OPTION_PREFER_EPHEMERAL, options["preferEphemeral"] as Boolean? ?: false)
                    putExtra(AuthenticationManagementActivity.KEY_AUTH_SESSION_ID, sessionId)
                })
            }

            "cleanUpDanglingCalls" -> {
                // Every one of these reaches Dart as a cancellation the user
                // never performed. A non-zero count here is a sign-in that was
                // still pending when the app came back up.
                if (callbacks.isNotEmpty()) {
                    Log.w(LOG_TAG, "cancelling ${callbacks.size} dangling call(s)")
                }
                callbacks.forEach { (_, danglingResultCallback) ->
                    danglingResultCallback.error("CANCELED", "User canceled login", null)
                }
                callbacks.clear()
                resultCallback.success(null)
            }

            else -> resultCallback.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    /**
     * Find Support CustomTabs Browser.
     *
     * Priority:
     * 1. Custom Browser Order (if supported)
     * 2. default Browser
     * 3. Installed Browsers (if supported)
     * 4. null (System backup aka. some obscure browser that may work)
     */
    private fun findTargetBrowserPackageName(options: Map<String, Any>): String? {
        val context = requireNotNull(context) { "Context is null" }

        val selectedPackage = (options["customTabsPackageOrder"] as? Iterable<*>)
            ?.mapNotNull { (it as? String)?.trim() }
            ?.filter { it.isNotEmpty() }
            ?.firstOrNull { isSupportCustomTabs(it) }

        if (selectedPackage != null) {
            return selectedPackage
        }

        // Check default browser
        val defaultBrowserSupported = CustomTabsClient.getPackageName(context, emptyList<String>())
        if (defaultBrowserSupported != null) {
            return defaultBrowserSupported
        }
        // Check installed browser
        val matchedBrowser = getInstalledBrowsers().firstOrNull { isSupportCustomTabs(it) }

        // Don't fall back to Chrome here. It is not installed anyway because it would already be in matchedBrowser.
        // Instead, fall back to null so we can use the system backup (if one is available).
        return matchedBrowser
    }

    private fun getInstalledBrowsers(): List<String> {
        val context = requireNotNull(context) { "Context is null" }

        // Get all apps that can handle VIEW intents
        val activityIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://"))
        val viewIntentHandlers = context.getPackagesForIntent(activityIntent)

        val preferredKnownBrowsers = listOf(
            PackageNames.CHROME_STABLE,
            PackageNames.CHROME_BETA,
            PackageNames.SAMSUNG_INTERNET,
            PackageNames.MICROSOFT_EDGE,
            PackageNames.FIREFOX,
            PackageNames.CHROME_DEV,
        )

        val preferred = mutableListOf<String>()
        val others = mutableListOf<String>()
        val pushToEnd = mutableListOf<String>() // for the least-favorite apps

        for (pkg in viewIntentHandlers) {
            if (preferredKnownBrowsers.contains(pkg)) preferred += pkg
            else others += pkg
        }

        preferred.sortBy { preferredKnownBrowsers.indexOf(it) }

        return buildList {
            addAll(preferred)
            addAll(others)
            addAll(pushToEnd)
        }
    }

    private fun isSupportCustomTabs(packageName: String): Boolean {
        val value = CustomTabsClient.getPackageName(
            context!!,
            arrayListOf(packageName),
            true
        )
        return value == packageName
    }
}
