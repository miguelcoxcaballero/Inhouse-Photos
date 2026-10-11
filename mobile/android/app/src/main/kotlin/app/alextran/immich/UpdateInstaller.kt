package com.inhousesoftware.photos

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import com.inhouse.services.updater.PhotosUpdateInstaller
import com.inhouse.services.updater.UpdateActivity

// Host adapter only. Canonical updater: github.com/miguelcoxcaballero/inhouse-services-updater.
// Change it there first and sync ALL five apps. New releases A + tiny changelog; B only on explicit user request.
class UpdateInstaller(private val activity: MainActivity, messenger: BinaryMessenger) {
  private val channel = MethodChannel(messenger, "com.inhousesoftware.photos/updates")
  private val installer = PhotosUpdateInstaller(activity, object : PhotosUpdateInstaller.Listener {
    override fun progress(downloadedBytes: Long, totalBytes: Long) {
      activity.runOnUiThread { channel.invokeMethod("downloadProgress", mapOf("downloadedBytes" to downloadedBytes, "totalBytes" to totalBytes)) }
    }
    override fun stage(value: String) { activity.runOnUiThread { channel.invokeMethod("updateStage", value) } }
  })
  init {
    channel.setMethodCallHandler { call, result ->
      when(call.method) {
        "openUpdater" -> { activity.startActivity(Intent(activity, UpdateActivity::class.java).putExtra("settings",true)); result.success(null) }
        "installUpdate" -> {
          val url = call.argument<String>("url")
          if(url.isNullOrBlank()) result.error("invalid_url","Missing update URL",null)
          else installer.installUpdate(url,call.argument<String>("sha256"),object : PhotosUpdateInstaller.Result {
            override fun success(value: String) { result.success(value) }
            override fun error(code: String,message: String?,details: Any?) { result.error(code,message,details) }
          })
        }
        "restartApp" -> { result.success("restarting");activity.startActivity(Intent(activity,RestartActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)) }
        else -> result.notImplemented()
      }
    }
  }
  fun dispose() { channel.setMethodCallHandler(null) }
}
