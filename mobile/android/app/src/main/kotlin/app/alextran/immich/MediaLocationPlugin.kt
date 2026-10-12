package com.inhousesoftware.photos

import android.Manifest
import android.content.ContentUris
import android.content.pm.PackageManager
import android.media.MediaMetadataRetriever
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.OptIn
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Reads an opened asset's existing GPS without slowing down the library scan. */
@OptIn(UnstableApi::class)
class MediaLocationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var context: android.content.Context
  private lateinit var channel: MethodChannel
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "com.inhousesoftware.photos/media_location")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    scope.cancel()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "read") {
      result.notImplemented()
      return
    }
    val id = call.argument<String>("id")?.toLongOrNull()
    if (id == null || id < 0) {
      result.success(null)
      return
    }
    val isVideo = call.argument<Boolean>("isVideo") == true
    scope.launch {
      try {
        result.success(withContext(Dispatchers.IO) { readCoordinates(id, isVideo) })
      } catch (cancelled: CancellationException) {
        throw cancelled
      } catch (_: SecurityException) {
        result.success(null)
      } catch (_: java.io.IOException) {
        result.success(null)
      } catch (_: IllegalArgumentException) {
        result.success(null)
      } catch (_: Exception) {
        result.error("location_unavailable", "Could not read this asset's existing location", null)
      }
    }
  }

  private fun readCoordinates(id: Long, isVideo: Boolean): Map<String, Double>? {
    val collection = if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    var uri = ContentUris.withAppendedId(collection, id)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      // Respect the user's media-location permission. This is not device
      // tracking, and opening photo details never requests live GPS access.
      if (context.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
        return null
      }
      uri = MediaStore.setRequireOriginal(uri)
    }

    val coordinates: Pair<Double, Double> = if (isVideo) {
      context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
        val retriever = MediaMetadataRetriever()
        try {
          retriever.setDataSource(descriptor.fileDescriptor)
          val value = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION) ?: return null
          MediaEditorMetadata.parseVideoLocation(value) ?: return null
        } finally {
          retriever.release()
        }
      } ?: return null
    } else {
      context.contentResolver.openInputStream(uri)?.use { stream ->
        val value = ExifInterface(stream).latLong ?: return null
        value[0] to value[1]
      } ?: return null
    }
    val (latitude, longitude) = coordinates
    if (!latitude.isFinite() || !longitude.isFinite() || latitude !in -90.0..90.0 || longitude !in -180.0..180.0) {
      return null
    }
    return mapOf("latitude" to latitude, "longitude" to longitude)
  }
}
