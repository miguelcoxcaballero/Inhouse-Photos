package com.inhousesoftware.photos

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process

/**
 * Restarts the main application from a short-lived secondary process.
 * Shorebird loads a newly installed patch when the next Flutter engine starts,
 * so this removes the need for the user to close and reopen the app manually.
 */
class RestartActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    val restartProcessId = Process.myPid()
    val appUid = Process.myUid()
    val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

    activityManager.runningAppProcesses.orEmpty()
      .filter { process -> process.uid == appUid && process.pid != restartProcessId }
      .forEach { process -> Process.killProcess(process.pid) }

    Handler(Looper.getMainLooper()).postDelayed({
      val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
      }
      if (launchIntent != null) {
        startActivity(launchIntent)
      }
      finishAndRemoveTask()
      Process.killProcess(restartProcessId)
    }, RESTART_DELAY_MS)
  }

  companion object {
    private const val RESTART_DELAY_MS = 220L
  }
}
