package com.inhousesoftware.photos

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.container.Mp4LocationData
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.InAppMp4Muxer
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** On-device save-copy editor. Inputs are strictly read-only; output lives in app cache. */
@OptIn(UnstableApi::class)
class MediaEditorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var context: android.content.Context
  private lateinit var channel: MethodChannel
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val operations = mutableMapOf<String, Job>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "com.inhousesoftware.photos/media_editor")
    channel.setMethodCallHandler(this)
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    scope.cancel()
  }
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method == "cancel") {
      operations[call.argument<String>("operationId")]?.cancel()
      result.success(null)
      return
    }
    if (call.method != "inspect" && call.method != "export") { result.notImplemented(); return }
    val id = call.argument<String>("operationId") ?: UUID.randomUUID().toString()
    operations[id] = scope.launch {
      var output: File? = null
      try {
        val source = File(requireNotNull(call.argument<String>("sourcePath")))
        require(source.isFile) { "Original file is unavailable" }
        val directory = File(requireNotNull(call.argument<String>("outputDirectory"))).canonicalFile
        require(directory.path.startsWith(context.cacheDir.canonicalPath + File.separator)) { "Output must be in app cache" }
        directory.mkdirs()
        val video = call.argument<Boolean>("isVideo") ?: false
        if (call.method == "inspect") {
          result.success(if (video) inspectVideo(source) else inspectPhoto(source, directory))
        } else {
          val extension = if (video) ".mp4" else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(source.path, bounds)
            if (bounds.outMimeType in listOf("image/png", "image/webp")) ".webp" else ".jpg"
          }
          output = File(directory, "edited-${UUID.randomUUID()}$extension")
          if (video) exportVideo(source, output, call, id) else exportPhoto(source, output, call)
          ensureActive()
          require(output.length() > 0) { "The edited file is empty" }
          result.success(output.path)
        }
      } catch (error: CancellationException) {
        output?.delete()
        result.error("cancelled", "Export cancelled", null)
      } catch (error: Throwable) {
        output?.delete()
        result.error("edit_failed", error.message ?: "Unable to edit this file", null)
      } finally {
        operations.remove(id)
      }
    }
  }

  private suspend fun inspectVideo(source: File): Map<String, Any> = withContext(Dispatchers.IO) {
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(source.path)
      val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
      var width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
      var height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
      val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
      if (rotation % 180 != 0) { val swap = width; width = height; height = swap }
      require(width > 0 && height > 0 && duration > 0) { "Unsupported video" }
      mapOf("width" to width, "height" to height, "durationMs" to duration)
    } finally { retriever.release() }
  }

  private suspend fun inspectPhoto(source: File, directory: File): Map<String, Any> = withContext(Dispatchers.IO) {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(source.path, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported photo" }
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1800) sample *= 2
    val bitmap = decodeUpright(source, sample)
    try {
      val output = File(directory, "preview.png")
      FileOutputStream(output).use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
      mapOf("previewPath" to output.path, "width" to bitmap.width, "height" to bitmap.height)
    } finally { bitmap.recycle() }
  }

  internal suspend fun exportPhoto(source: File, output: File, call: MethodCall) = withContext(Dispatchers.IO) {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(source.path, bounds)
    // Fail explicitly instead of silently reducing the user's original resolution.
    require(bounds.outWidth.toLong() * bounds.outHeight * 16 < Runtime.getRuntime().maxMemory() * 0.75) {
      "This full-resolution photo is too large to edit on this device"
    }
    var bitmap = decodeUpright(source, 1)
    try {
      val values = requireNotNull(call.argument<List<Number>>("crop")).map(Number::toDouble)
      val crop = MediaEditGeometry.crop(values, bitmap.width, bitmap.height)
      val cropped = Bitmap.createBitmap(bitmap, crop.x, crop.y, crop.width, crop.height)
      if (cropped !== bitmap) { bitmap.recycle(); bitmap = cropped }
      ensureActive()
      val rotation = MediaEditGeometry.rotation(call.argument<Int>("rotation") ?: 0)
      val matrix = Matrix().apply {
        if (call.argument<Boolean>("flipHorizontal") == true) setScale(-1f, 1f)
        postRotate(rotation.toFloat())
      }
      val transformed = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
      if (transformed !== bitmap) { bitmap.recycle(); bitmap = transformed }
      val color = requireNotNull(call.argument<List<Number>>("colorMatrix")).map { it.toFloat() }.toFloatArray()
      require(color.size == 20 && color.all(Float::isFinite)) { "Invalid color adjustment" }
      val adjusted = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
      try {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { colorFilter = ColorMatrixColorFilter(color) }
        Canvas(adjusted).drawBitmap(bitmap, 0f, 0f, paint)
        ensureActive()
        // WebP retains transparency and supports EXIF; JPEG is used for opaque camera photos.
        val format = if (output.extension == "webp") {
          if (android.os.Build.VERSION.SDK_INT >= 30) Bitmap.CompressFormat.WEBP_LOSSLESS else Bitmap.CompressFormat.WEBP
        } else Bitmap.CompressFormat.JPEG
        FileOutputStream(output).use { check(adjusted.compress(format, if (output.extension == "webp") 100 else 95, it)) }
        MediaEditorMetadata.copyPhoto(source, output, adjusted.width, adjusted.height, locationOverride(call), call.argument<Boolean>("replaceLocation") == true)
      } finally { adjusted.recycle() }
    } finally { bitmap.recycle() }
  }

  private fun decodeUpright(source: File, sample: Int): Bitmap {
    val exif = ExifInterface(source)
    val decoded = requireNotNull(BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply {
      inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888
    })) { "Unable to decode photo" }
    val matrix = Matrix()
    when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
      ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
      ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
      ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
      ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
      ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
      ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
      ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
      else -> return decoded
    }
    return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true).also { if (it !== decoded) decoded.recycle() }
  }

  private fun locationOverride(call: MethodCall): Pair<Double, Double>? {
    val values = call.argument<List<Number>>("location") ?: return null
    require(values.size == 2) { "Invalid location" }
    val latitude = values[0].toDouble()
    val longitude = values[1].toDouble()
    require(latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0) { "Invalid location" }
    return latitude to longitude
  }

  private suspend fun exportVideo(source: File, output: File, call: MethodCall, id: String) {
    val info = inspectVideo(source)
    val (start, end) = MediaEditGeometry.trim(
      (call.argument<Number>("startMs") ?: 0).toLong(), call.argument<Number>("endMs")?.toLong(), info["durationMs"] as Long,
    )
    val rotation = MediaEditGeometry.rotation(call.argument<Int>("rotation") ?: 0)
    val media = MediaItem.Builder().setUri(Uri.fromFile(source)).setClippingConfiguration(
      MediaItem.ClippingConfiguration.Builder().setStartPositionMs(start).setEndPositionMs(end).build(),
    ).build()
    val effects = if (rotation == 0) emptyList() else listOf<Effect>(
      // Media3 uses counterclockwise degrees; the editor's rotate button is clockwise.
      ScaleAndRotateTransformation.Builder().setRotationDegrees(-rotation.toFloat()).build(),
    )
    val edited = EditedMediaItem.Builder(media).setRemoveAudio(call.argument<Boolean>("mute") == true)
      .setEffects(Effects(emptyList(), effects)).build()
    // H.264 copies use SDR. Explicit tone mapping supports common Samsung
    // HEVC/HDR10+ recordings instead of asking an H.264 encoder to keep HDR.
    val composition = Composition.Builder(EditedMediaItemSequence.Builder(edited).build())
      .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
      .build()
    val location = locationOverride(call)
    val metadata = when {
      location != null -> listOf(Mp4LocationData(location.first.toFloat(), location.second.toFloat()))
      call.argument<Boolean>("replaceLocation") == true -> emptyList()
      else -> withContext(Dispatchers.IO) { MediaEditorMetadata.videoMetadata(source) }
    }
    suspendCancellableCoroutine<Unit> { continuation ->
      var poll: Job? = null
      val transformer = Transformer.Builder(context)
        .setVideoMimeType(MimeTypes.VIDEO_H264)
        .setAudioMimeType(MimeTypes.AUDIO_AAC)
        .setMuxerFactory(InAppMp4Muxer.Factory { entries ->
          if (location != null || call.argument<Boolean>("replaceLocation") == true) {
            entries.removeAll { it is Mp4LocationData }
          }
          entries.addAll(metadata)
        })
        .addListener(object : Transformer.Listener {
          override fun onCompleted(composition: Composition, exportResult: ExportResult) {
            poll?.cancel()
            if (continuation.isActive) continuation.resume(Unit)
          }
          override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
            poll?.cancel()
            if (continuation.isActive) continuation.resumeWithException(exportException)
          }
        }).build()
      continuation.invokeOnCancellation {
        // Media3 must be cancelled on the same application looper it was created on.
        android.os.Handler(android.os.Looper.getMainLooper()).post { poll?.cancel(); transformer.cancel(); output.delete() }
      }
      try {
        transformer.start(composition, output.path)
        poll = scope.launch {
          val holder = ProgressHolder()
          while (continuation.isActive) {
            if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
              channel.invokeMethod("progress", mapOf("operationId" to id, "progress" to holder.progress / 100.0))
            }
            delay(250)
          }
        }
      } catch (error: Throwable) {
        transformer.cancel()
        if (continuation.isActive) continuation.resumeWithException(error)
      }
    }
  }
}
