package com.linusu.flutter_web_auth_2

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle

class CallbackActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val viewUri = intent?.data
        val url = viewUri ?: fixAutoVerifyNotWorks(intent)
        val scheme = url?.scheme

        // A VIEW deep link (viewUri) was routed here by the OS matching one of our
        // intent-filters. A URI recovered from an ACTION_SEND extra was matched
        // only by the exported text/plain filter, so any installed app could have
        // forged it — deliver it only if it would ALSO satisfy one of our own VIEW
        // filters (app://<our host>, or https://<our host>/<our path prefix>).
        // That reuses the manifest's redirect host/path as the whitelist instead
        // of hardcoding it, and stops the SEND path from delivering anything a
        // VIEW could not: a forged code under an arbitrary scheme or host no
        // longer reaches the pending session.
        if (scheme != null && (viewUri != null || matchesOwnRedirectFilter(url))) {
            // The backend rewrites the redirect per browser (custom scheme for
            // Chromium, https App Link for Firefox) while the app registers the
            // callback under the app:// scheme, so a delivered redirect routinely
            // arrives under a different scheme than the one the session waits on.
            // Keep handing it to the single pending session on a scheme mismatch
            // instead of dropping the code.
            val callback = FlutterWebAuth2Plugin.callbacks.remove(scheme)
                ?: FlutterWebAuth2Plugin.callbacks.keys.singleOrNull()?.let {
                    FlutterWebAuth2Plugin.callbacks.remove(it)
                }
            callback?.success(url.toString())
        }
        startActivity(AuthenticationManagementActivity.createResponseHandlingIntent(this))
        finish()
    }

    /** True when [uri] would be delivered to this activity through one of its VIEW
     * intent-filters — i.e. it matches a redirect the app actually registered (the
     * app:// custom scheme, or the https App Link host and path). Used to vet a URI
     * recovered from an ACTION_SEND extra, which the OS did not route by those
     * filters. An unverified App Link still matches here: verification governs
     * auto-opening, not whether the filter matches, so this stays true on the
     * exact devices (App Links unverified) that need the SEND recovery. Returns
     * false when [uri] is null (the SEND extra did not parse to a URI). */
    @Suppress("DEPRECATION")
    private fun matchesOwnRedirectFilter(uri: Uri?): Boolean {
        if (uri == null) return false
        val probe = Intent(Intent.ACTION_VIEW, uri)
            .addCategory(Intent.CATEGORY_BROWSABLE)
        return packageManager.queryIntentActivities(probe, 0).any {
            it.activityInfo?.packageName == packageName &&
                it.activityInfo?.name == CallbackActivity::class.java.name
        }
    }


    /** Fix sometimes android:autoVerify="true" cannot works when it can't access Google after installation.
     * See https://stackoverflow.com/questions/76383106/auto-verify-not-always-working-in-app-links-using-android
     *
     * must register in AndroidManifest.xml :
     * <intent-filter>
     *     <action android:name="android.intent.action.SEND" />
     *     <category android:name="android.intent.category.DEFAULT" />
     *     <data android:mimeType="text/plain" />
     *</intent-filter>
     */
    private fun fixAutoVerifyNotWorks(intent: Intent?): Uri? {
        if (intent?.action == Intent.ACTION_SEND && "text/plain" == intent.type) {
            return intent.getStringExtra(Intent.EXTRA_TEXT)?.let {
                try {
                    //scheme://host/path#id_token=xxx
                    return Uri.parse(it)
                } catch (e: Exception) {
                    return null
                }
            }
        }
        return null
    }

}
