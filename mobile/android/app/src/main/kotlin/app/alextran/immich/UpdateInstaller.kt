package com.inhousesoftware.photos

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

class UpdateInstaller(
  private val activity: MainActivity,
  messenger: BinaryMessenger,
) {
  private val channel = MethodChannel(messenger, CHANNEL_NAME)
  private val downloadRunning = AtomicBoolean(false)

  init {
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "installUpdate" -> {
          val url = call.argument<String>("url")
          if (url.isNullOrBlank()) {
            result.error("invalid_url", "The update URL is missing.", null)
          } else {
            installUpdate(url, result)
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  fun dispose() {
    channel.setMethodCallHandler(null)
  }

  private fun installUpdate(url: String, result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !activity.packageManager.canRequestPackageInstalls()) {
      activity.startActivity(
        Intent(
          Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
          Uri.parse("package:${activity.packageName}"),
        ),
      )
      result.success("permission_required")
      return
    }

    if (!downloadRunning.compareAndSet(false, true)) {
      result.error("already_downloading", "The update is already downloading.", null)
      return
    }

    Thread({
      try {
        val updateDirectory = File(activity.cacheDir, "updates")
        if (!updateDirectory.exists() && !updateDirectory.mkdirs()) {
          throw IllegalStateException("Could not prepare secure update storage.")
        }
        val apkFile = File(updateDirectory, "inhouse-photos-update.apk")
        download(url, apkFile)
        verifyApk(apkFile)

        val apkUri = FileProvider.getUriForFile(
          activity,
          "${activity.packageName}.update-provider",
          apkFile,
        )
        activity.runOnUiThread {
          try {
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
              setDataAndType(apkUri, APK_MIME_TYPE)
              addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(installIntent)
            result.success("ready")
          } catch (error: Exception) {
            result.error("installer_unavailable", error.message ?: "Android could not open the installer.", null)
          }
        }
      } catch (error: Exception) {
        activity.runOnUiThread {
          result.error("update_failed", error.message ?: "The update could not be installed.", null)
        }
      } finally {
        downloadRunning.set(false)
      }
    }, "InhousePhotosUpdate").start()
  }

  private fun download(initialUrl: String, destination: File) {
    var currentUrl = URL(initialUrl)
    var redirects = 0

    while (true) {
      validateUrl(currentUrl)
      val connection = currentUrl.openConnection() as HttpURLConnection
      connection.instanceFollowRedirects = false
      connection.connectTimeout = 15_000
      connection.readTimeout = 120_000
      connection.setRequestProperty("Accept", APK_MIME_TYPE)

      try {
        val responseCode = connection.responseCode
        if (responseCode in 300..399) {
          val location = connection.getHeaderField("Location")
            ?: throw IllegalStateException("The update redirect is invalid.")
          if (++redirects > MAX_REDIRECTS) {
            throw IllegalStateException("The update has too many redirects.")
          }
          currentUrl = URL(currentUrl, location)
          continue
        }
        if (responseCode !in 200..299) {
          throw IllegalStateException("Update download failed ($responseCode).")
        }

        var totalBytes = 0L
        BufferedInputStream(connection.inputStream).use { input ->
          FileOutputStream(destination, false).use { output ->
            val buffer = ByteArray(32 * 1024)
            while (true) {
              val count = input.read(buffer)
              if (count < 0) break
              output.write(buffer, 0, count)
              totalBytes += count
            }
            output.fd.sync()
          }
        }
        if (totalBytes < MINIMUM_APK_BYTES) {
          throw IllegalStateException("The downloaded update is incomplete.")
        }
        return
      } finally {
        connection.disconnect()
      }
    }
  }

  private fun validateUrl(url: URL) {
    if (!url.protocol.equals("https", ignoreCase = true) || url.host.lowercase() !in ALLOWED_HOSTS) {
      throw SecurityException("The update URL is not allowed.")
    }
  }

  private fun verifyApk(apkFile: File) {
    val archive = getArchivePackageInfo(apkFile)
      ?: throw SecurityException("The downloaded file is not a valid Android package.")
    val installed = getInstalledPackageInfo()

    if (archive.packageName != activity.packageName) {
      throw SecurityException("The update belongs to a different application.")
    }
    if (getVersionCode(archive) <= getVersionCode(installed)) {
      throw SecurityException("The downloaded build is not newer than the installed app.")
    }
    if (getSigningDigests(archive) != getSigningDigests(installed)) {
      throw SecurityException("The update signature does not match Inhouse Photos.")
    }
  }

  @Suppress("DEPRECATION")
  private fun getArchivePackageInfo(apkFile: File): PackageInfo? {
    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      PackageManager.GET_SIGNING_CERTIFICATES
    } else {
      PackageManager.GET_SIGNATURES
    }
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      activity.packageManager.getPackageArchiveInfo(
        apkFile.absolutePath,
        PackageManager.PackageInfoFlags.of(flags.toLong()),
      )
    } else {
      activity.packageManager.getPackageArchiveInfo(apkFile.absolutePath, flags)
    }
  }

  @Suppress("DEPRECATION")
  private fun getInstalledPackageInfo(): PackageInfo {
    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      PackageManager.GET_SIGNING_CERTIFICATES
    } else {
      PackageManager.GET_SIGNATURES
    }
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      activity.packageManager.getPackageInfo(
        activity.packageName,
        PackageManager.PackageInfoFlags.of(flags.toLong()),
      )
    } else {
      activity.packageManager.getPackageInfo(activity.packageName, flags)
    }
  }

  @Suppress("DEPRECATION")
  private fun getSigningDigests(packageInfo: PackageInfo): Set<String> {
    val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      packageInfo.signingInfo?.apkContentsSigners.orEmpty()
    } else {
      packageInfo.signatures.orEmpty()
    }
    if (signatures.isEmpty()) {
      throw SecurityException("The update signature could not be verified.")
    }
    return signatures.map { signature ->
      MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { byte ->
        "%02x".format(byte)
      }
    }.toSet()
  }

  @Suppress("DEPRECATION")
  private fun getVersionCode(packageInfo: PackageInfo): Long =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) packageInfo.longVersionCode else packageInfo.versionCode.toLong()

  companion object {
    private const val CHANNEL_NAME = "com.inhousesoftware.photos/updates"
    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    private const val MINIMUM_APK_BYTES = 100_000L
    private const val MAX_REDIRECTS = 5
    private val ALLOWED_HOSTS = setOf(
      "github.com",
      "raw.githubusercontent.com",
      "objects.githubusercontent.com",
      "release-assets.githubusercontent.com",
    )
  }
}
