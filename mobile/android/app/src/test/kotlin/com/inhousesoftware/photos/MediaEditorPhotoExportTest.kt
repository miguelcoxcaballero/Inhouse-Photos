package com.inhousesoftware.photos

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Executes the actual Bitmap/Canvas export and EXIF writer, not a mocked codec. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MediaEditorPhotoExportTest {
  @get:Rule val files = TemporaryFolder()
  private val identity = listOf(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)

  private fun source(orientation: Int = ExifInterface.ORIENTATION_NORMAL): File {
    val file = files.newFile("source-${System.nanoTime()}.jpg")
    val image = Bitmap.createBitmap(120, 80, Bitmap.Config.ARGB_8888)
    image.eraseColor(Color.rgb(80, 80, 80))
    file.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 100, it) }
    image.recycle()
    ExifInterface(file).apply {
      setLatLong(0.0, 12.25)
      setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2024:03:23 12:17:19")
      setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
      saveAttributes()
    }
    return file
  }

  private fun call(crop: List<Double> = listOf(0.0, 0.0, 1.0, 1.0), rotation: Int = 0, color: List<Double> = identity, location: List<Double>? = null, replaceLocation: Boolean = false) = MethodCall("export", mapOf(
    "crop" to crop, "rotation" to rotation, "flipHorizontal" to false, "colorMatrix" to color,
    "location" to location, "replaceLocation" to replaceLocation,
  ))

  @Test fun rotatedExifIsNormalizedBeforeCropAndCaptureMetadataSurvives() = runBlocking {
    val source = source(ExifInterface.ORIENTATION_ROTATE_90)
    val originalHash = MessageDigest.getInstance("SHA-256").digest(source.readBytes())
    val output = files.newFile("edited.jpg")
    MediaEditorPlugin().exportPhoto(source, output, call(crop = listOf(0.0, 0.0, 0.5, 1.0), rotation = 90))
    val decoded = BitmapFactory.decodeFile(output.path)
    assertEquals(120, decoded.width)
    assertEquals(40, decoded.height)
    decoded.recycle()
    val exif = ExifInterface(output)
    assertEquals(ExifInterface.ORIENTATION_NORMAL, exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
    assertArrayEquals(doubleArrayOf(0.0, 12.25), exif.latLong, 0.000001)
    assertEquals("2024:03:23 12:17:19", exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
    assertArrayEquals(originalHash, MessageDigest.getInstance("SHA-256").digest(source.readBytes()))
  }

  @Test fun brightnessActuallyChangesExportedPixels() = runBlocking {
    val output = files.newFile("bright.jpg")
    val brighter = identity.toMutableList().apply { this[4] = 40.0; this[9] = 40.0; this[14] = 40.0 }
    MediaEditorPlugin().exportPhoto(source(), output, call(color = brighter))
    val decoded = BitmapFactory.decodeFile(output.path)
    assertEquals(120.0, Color.red(decoded.getPixel(60, 40)).toDouble(), 3.0)
    assertEquals(120.0, Color.green(decoded.getPixel(60, 40)).toDouble(), 3.0)
    decoded.recycle()
  }

  @Test fun webpCopyPreservesAlphaAndSupportsExif() = runBlocking {
    val source = files.newFile("transparent.png")
    val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888)
    bitmap.eraseColor(Color.argb(64, 200, 100, 50))
    source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    bitmap.recycle()
    val output = files.newFile("edited.webp")
    MediaEditorPlugin().exportPhoto(source, output, call())
    val decoded = BitmapFactory.decodeFile(output.path)
    assertEquals(64.0, Color.alpha(decoded.getPixel(8, 8)).toDouble(), 1.0)
    assertEquals(16, decoded.width)
    decoded.recycle()
    assertEquals(ExifInterface.ORIENTATION_NORMAL, ExifInterface(output).getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
  }

  @Test fun authoritativeLocationChangesAndRemovalOverrideEmbeddedGps() = runBlocking {
    val source = source()
    val moved = files.newFile("moved.jpg")
    MediaEditorPlugin().exportPhoto(source, moved, call(location = listOf(51.5, -0.12), replaceLocation = true))
    assertArrayEquals(doubleArrayOf(51.5, -0.12), ExifInterface(moved).latLong, 0.000001)
    val removed = files.newFile("removed.jpg")
    MediaEditorPlugin().exportPhoto(source, removed, call(replaceLocation = true))
    assertNull(ExifInterface(removed).latLong)
    assertArrayEquals(doubleArrayOf(0.0, 12.25), ExifInterface(source).latLong, 0.000001)
  }

}
