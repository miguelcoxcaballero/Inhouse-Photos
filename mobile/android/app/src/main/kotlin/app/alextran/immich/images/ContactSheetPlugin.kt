package com.inhousesoftware.photos.images

import android.content.ContentUris
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Benchmark prototype: one platform round trip / GPU upload per sheet.
 * Not selected by the gallery until device benchmarks prove an improvement.
 * Only local MediaStore IDs are accepted; never paths or arbitrary URLs.
 */
class ContactSheetPlugin : FlutterPlugin {
  private var channel: MethodChannel? = null
  private val worker = Executors.newSingleThreadExecutor()
  private val busy = AtomicBoolean(false)
  private val main = Handler(Looper.getMainLooper())
  private var signal: CancellationSignal? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    val resolver = binding.applicationContext.contentResolver
    channel = MethodChannel(binding.binaryMessenger, "inhouse.photos/contact-sheet")
    channel!!.setMethodCallHandler { call, result ->
      if (call.method != "render" || Build.VERSION.SDK_INT < 29) {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val ids = call.argument<List<String>>("ids") ?: emptyList()
      val pixels = call.argument<Int>("pixels") ?: 0
      val columns = call.argument<Int>("columns") ?: 0
      if (ids.isEmpty() || ids.size > 96 || pixels !in 8..256 || columns !in 1..48 || ids.any { it.toLongOrNull() == null }) {
        result.error("invalid", "Invalid contact sheet dimensions or IDs", null)
        return@setMethodCallHandler
      }
      if (!busy.compareAndSet(false, true)) {
        result.error("busy", "One sheet is already being generated", null)
        return@setMethodCallHandler
      }
      val cancellation = CancellationSignal()
      signal = cancellation
      worker.execute {
        var sheet: Bitmap? = null
        try {
          val started = System.nanoTime()
          val width = columns * pixels
          val height = ((ids.size + columns - 1) / columns) * pixels
          sheet = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
          val canvas = Canvas(sheet)
          val paint = Paint(Paint.FILTER_BITMAP_FLAG)
          val completed = ArrayList<Int>()
          ids.forEachIndexed { index, id ->
            cancellation.throwIfCanceled()
            try {
              val uri = ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), id.toLong())
              val thumbnail = resolver.loadThumbnail(uri, Size(pixels, pixels), cancellation)
              try {
                val side = minOf(thumbnail.width, thumbnail.height)
                val x = (thumbnail.width - side) / 2
                val y = (thumbnail.height - side) / 2
                val left = (index % columns) * pixels
                val top = (index / columns) * pixels
                canvas.drawBitmap(thumbnail, Rect(x, y, x + side, y + side), Rect(left, top, left + pixels, top + pixels), paint)
                completed.add(index)
              } finally { thumbnail.recycle() }
            } catch (_: Exception) { cancellation.throwIfCanceled() }
          }
          val bytes = ByteBuffer.allocate(width * height * 4)
          sheet.copyPixelsToBuffer(bytes)
          val response = mapOf("rgba" to bytes.array(), "width" to width, "height" to height,
            "completed" to completed, "nativeMicros" to (System.nanoTime() - started) / 1000)
          main.post { if (channel != null) result.success(response) }
        } catch (error: Exception) {
          main.post { if (channel != null) result.error("render", error.message, null) }
        } finally {
          sheet?.recycle()
          busy.set(false)
        }
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    signal?.cancel()
    worker.shutdownNow()
  }
}
