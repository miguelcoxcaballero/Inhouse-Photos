package com.inhousesoftware.photos

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Creates disposable Storage saver copies. Device originals are read-only. */
@OptIn(UnstableApi::class)
class BackupMediaProcessorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var context: android.content.Context
  private lateinit var channel: MethodChannel
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val transformers = mutableSetOf<Transformer>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
    channel.setMethodCallHandler(this)
    cleanupStaleFiles()
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    transformers.toList().forEach(Transformer::cancel)
    transformers.clear()
    scope.cancel()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "prepare") {
      result.notImplemented()
      return
    }

    val sourcePath = call.argument<String>("sourcePath")
    val originalFileName = call.argument<String>("originalFileName")
    val operationId = call.argument<String>("operationId")
    val isVideo = call.argument<Boolean>("isVideo") ?: false
    if (sourcePath.isNullOrBlank() || originalFileName.isNullOrBlank() || operationId.isNullOrBlank()) {
      result.error("invalid_arguments", "sourcePath, originalFileName and operationId are required", null)
      return
    }

    scope.launch {
      try {
        emitProgress(operationId, 0.02)
        val prepared = if (isVideo) {
          prepareVideo(File(sourcePath), originalFileName, operationId)
        } else {
          preparePhoto(File(sourcePath), originalFileName, operationId)
        }
        emitProgress(operationId, 1.0)
        result.success(prepared)
      } catch (error: Throwable) {
        result.error("storage_saver_failed", error.message ?: error.javaClass.simpleName, null)
      }
    }
  }

  private suspend fun preparePhoto(source: File, originalFileName: String, operationId: String): Map<String, Any>? =
    withContext(Dispatchers.IO) {
      require(source.isFile) { "Photo source does not exist" }

      val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
      BitmapFactory.decodeFile(source.path, bounds)
      require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported photo format" }
      emitProgressFromWorker(operationId, 0.15)

      val targetScale = min(1.0, sqrt(MAX_PHOTO_PIXELS.toDouble() / (bounds.outWidth.toLong() * bounds.outHeight)))
      val targetWidth = (bounds.outWidth * targetScale).roundToInt().coerceAtLeast(1)
      val targetHeight = (bounds.outHeight * targetScale).roundToInt().coerceAtLeast(1)
      var sampleSize = 1
      while (bounds.outWidth / (sampleSize * 2) >= targetWidth && bounds.outHeight / (sampleSize * 2) >= targetHeight) {
        sampleSize *= 2
      }

      val decoded = BitmapFactory.decodeFile(
        source.path,
        BitmapFactory.Options().apply {
          inSampleSize = sampleSize
          inPreferredConfig = Bitmap.Config.ARGB_8888
        },
      ) ?: error("Unable to decode photo")
      emitProgressFromWorker(operationId, 0.45)

      val scaled = if (decoded.width != targetWidth || decoded.height != targetHeight) {
        Bitmap.createScaledBitmap(decoded, targetWidth, targetHeight, true).also { if (it !== decoded) decoded.recycle() }
      } else {
        decoded
      }

      val sourceExif = runCatching { ExifInterface(source.path) }.getOrNull()
      val rotated = rotateFromExif(scaled, sourceExif)
      emitProgressFromWorker(operationId, 0.65)
      val hasAlpha = rotated.hasAlpha()
      val outputWidth = rotated.width
      val outputHeight = rotated.height
      val extension = if (hasAlpha) ".png" else ".jpg"
      val output = newOutputFile(extension)

      try {
        FileOutputStream(output).use { stream ->
          val format = if (hasAlpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
          check(rotated.compress(format, PHOTO_JPEG_QUALITY, stream)) { "Unable to encode photo" }
        }
        emitProgressFromWorker(operationId, 0.9)
        if (rotated !== scaled) scaled.recycle()
        rotated.recycle()

        if (!hasAlpha && sourceExif != null) {
          copyExif(sourceExif, output, outputWidth, outputHeight)
        }
        emitProgressFromWorker(operationId, 0.97)
        useOnlyWhenSmaller(source, output, replaceExtension(originalFileName, extension))
      } catch (error: Throwable) {
        output.delete()
        throw error
      }
    }

  private suspend fun prepareVideo(source: File, originalFileName: String, operationId: String): Map<String, Any>? {
    require(source.isFile) { "Video source does not exist" }
    val retriever = MediaMetadataRetriever()
    val (width, height) = try {
      retriever.setDataSource(source.path)
      val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
      val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
      width to height
    } finally {
      retriever.release()
    }
    require(width > 0 && height > 0) { "Unable to read video dimensions" }

    val shortSide = min(min(width, height), MAX_VIDEO_SHORT_SIDE)
    val effects = Effects(emptyList(), listOf<Effect>(Presentation.createForShortSide(shortSide)))
    val editedMedia = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source))).setEffects(effects).build()
    val output = newOutputFile(".mp4")

    val encoderFactory = DefaultEncoderFactory.Builder(context)
      .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(VIDEO_BITRATE).build())
      .build()

    return suspendCancellableCoroutine { continuation ->
      lateinit var transformer: Transformer
      var progressJob: Job? = null
      val listener = object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          progressJob?.cancel()
          transformers.remove(transformer)
          emitProgress(operationId, 0.98)
          if (continuation.isActive) {
            continuation.resume(useOnlyWhenSmaller(source, output, replaceExtension(originalFileName, ".mp4")))
          }
        }

        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
          progressJob?.cancel()
          transformers.remove(transformer)
          output.delete()
          if (continuation.isActive) {
            continuation.resume(null)
          }
        }
      }

      transformer = Transformer.Builder(context)
        .setEncoderFactory(encoderFactory)
        .setVideoMimeType(MimeTypes.VIDEO_H264)
        .setAudioMimeType(MimeTypes.AUDIO_AAC)
        .addListener(listener)
        .build()
      transformers.add(transformer)
      continuation.invokeOnCancellation {
        progressJob?.cancel()
        transformer.cancel()
        transformers.remove(transformer)
        output.delete()
      }
      transformer.start(editedMedia, output.path)
      progressJob = scope.launch {
        val holder = ProgressHolder()
        while (continuation.isActive) {
          if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
            emitProgress(operationId, 0.02 + (holder.progress.coerceIn(0, 100) / 100.0 * 0.94))
          }
          delay(200)
        }
      }
    }
  }

  private fun emitProgress(operationId: String, progress: Double) {
    channel.invokeMethod(
      "progress",
      mapOf("operationId" to operationId, "progress" to progress.coerceIn(0.0, 1.0)),
    )
  }

  private suspend fun emitProgressFromWorker(operationId: String, progress: Double) {
    withContext(Dispatchers.Main.immediate) { emitProgress(operationId, progress) }
  }

  private fun rotateFromExif(bitmap: Bitmap, exif: ExifInterface?): Bitmap {
    val orientation = exif?.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
      ?: ExifInterface.ORIENTATION_NORMAL
    val matrix = Matrix()
    when (orientation) {
      ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
      ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
      ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
      ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
      ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
      ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
      ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
      else -> return bitmap
    }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
  }

  private fun copyExif(source: ExifInterface, output: File, width: Int, height: Int) {
    runCatching {
      val target = ExifInterface(output.path)
      EXIF_TAGS.forEach { tag -> source.getAttribute(tag)?.let { target.setAttribute(tag, it) } }
      target.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
      target.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, width.toString())
      target.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, height.toString())
      target.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
      target.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
      target.saveAttributes()
    }
  }

  private fun useOnlyWhenSmaller(source: File, output: File, fileName: String): Map<String, Any>? {
    if (!output.isFile || output.length() <= 0 || output.length() >= source.length()) {
      output.delete()
      return null
    }
    return mapOf("path" to output.path, "fileName" to fileName)
  }

  private fun newOutputFile(extension: String): File {
    val directory = File(context.cacheDir, CACHE_DIRECTORY).apply { mkdirs() }
    return File(directory, "${UUID.randomUUID()}$extension")
  }

  private fun cleanupStaleFiles() {
    val cutoff = System.currentTimeMillis() - STALE_FILE_AGE_MS
    File(context.cacheDir, CACHE_DIRECTORY).listFiles()?.filter { it.lastModified() < cutoff }?.forEach(File::delete)
  }

  private fun replaceExtension(fileName: String, extension: String): String {
    val dot = fileName.lastIndexOf('.')
    val stem = if (dot > 0) fileName.substring(0, dot) else fileName
    return stem + extension
  }

  companion object {
    private const val CHANNEL_NAME = "com.inhousesoftware.photos/backup_media"
    private const val CACHE_DIRECTORY = "storage-saver"
    private const val MAX_PHOTO_PIXELS = 16_000_000L
    private const val MAX_VIDEO_SHORT_SIDE = 1080
    private const val PHOTO_JPEG_QUALITY = 88
    private const val VIDEO_BITRATE = 5_000_000
    private const val STALE_FILE_AGE_MS = 24 * 60 * 60 * 1000L

    private val EXIF_TAGS = listOf(
      ExifInterface.TAG_DATETIME,
      ExifInterface.TAG_DATETIME_ORIGINAL,
      ExifInterface.TAG_DATETIME_DIGITIZED,
      ExifInterface.TAG_OFFSET_TIME,
      ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
      ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
      ExifInterface.TAG_MAKE,
      ExifInterface.TAG_MODEL,
      ExifInterface.TAG_LENS_MAKE,
      ExifInterface.TAG_LENS_MODEL,
      ExifInterface.TAG_F_NUMBER,
      ExifInterface.TAG_EXPOSURE_TIME,
      ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
      ExifInterface.TAG_FOCAL_LENGTH,
      ExifInterface.TAG_FLASH,
      ExifInterface.TAG_WHITE_BALANCE,
      ExifInterface.TAG_GPS_LATITUDE,
      ExifInterface.TAG_GPS_LATITUDE_REF,
      ExifInterface.TAG_GPS_LONGITUDE,
      ExifInterface.TAG_GPS_LONGITUDE_REF,
      ExifInterface.TAG_GPS_ALTITUDE,
      ExifInterface.TAG_GPS_ALTITUDE_REF,
      ExifInterface.TAG_GPS_TIMESTAMP,
      ExifInterface.TAG_GPS_DATESTAMP,
      ExifInterface.TAG_USER_COMMENT,
      ExifInterface.TAG_COPYRIGHT,
      ExifInterface.TAG_ARTIST,
    )
  }
}
