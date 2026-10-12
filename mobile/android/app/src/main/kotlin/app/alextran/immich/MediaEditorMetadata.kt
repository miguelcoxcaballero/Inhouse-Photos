package com.inhousesoftware.photos

import android.media.MediaMetadataRetriever
import androidx.exifinterface.media.ExifInterface
import androidx.media3.common.Metadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.container.Mp4LocationData
import java.io.File

/** Metadata belonging to the capture, rather than the newly rendered pixels. */
@UnstableApi
object MediaEditorMetadata {
  // Do not copy offset-based MakerNotes, thumbnails, dimensions, or the old
  // orientation: those describe the original encoding and may corrupt a copy.
  private val captureTags = listOf(
    ExifInterface.TAG_DATETIME_ORIGINAL,
    ExifInterface.TAG_DATETIME_DIGITIZED,
    ExifInterface.TAG_DATETIME,
    ExifInterface.TAG_SUBSEC_TIME,
    ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
    ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
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
    ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
    ExifInterface.TAG_FLASH,
    ExifInterface.TAG_WHITE_BALANCE,
    ExifInterface.TAG_IMAGE_DESCRIPTION,
    ExifInterface.TAG_ARTIST,
    ExifInterface.TAG_COPYRIGHT,
    ExifInterface.TAG_USER_COMMENT,
    // Copy GPS rational values verbatim, including 0 latitude/longitude.
    ExifInterface.TAG_GPS_VERSION_ID,
    ExifInterface.TAG_GPS_LATITUDE,
    ExifInterface.TAG_GPS_LATITUDE_REF,
    ExifInterface.TAG_GPS_LONGITUDE,
    ExifInterface.TAG_GPS_LONGITUDE_REF,
    ExifInterface.TAG_GPS_ALTITUDE,
    ExifInterface.TAG_GPS_ALTITUDE_REF,
    ExifInterface.TAG_GPS_TIMESTAMP,
    ExifInterface.TAG_GPS_DATESTAMP,
    ExifInterface.TAG_GPS_PROCESSING_METHOD,
    ExifInterface.TAG_GPS_AREA_INFORMATION,
    ExifInterface.TAG_GPS_IMG_DIRECTION,
    ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
    ExifInterface.TAG_GPS_SPEED,
    ExifInterface.TAG_GPS_SPEED_REF,
    ExifInterface.TAG_GPS_MAP_DATUM,
    ExifInterface.TAG_GPS_H_POSITIONING_ERROR,
  )

  fun copyPhoto(
    source: File,
    target: File,
    width: Int,
    height: Int,
    locationOverride: Pair<Double, Double>? = null,
    replaceLocation: Boolean = false,
  ) {
    val original = ExifInterface(source)
    val edited = ExifInterface(target)
    captureTags.forEach { tag ->
      original.getAttribute(tag)?.let { edited.setAttribute(tag, it) }
    }
    if (replaceLocation || locationOverride != null) {
      // A location edited/removed on the server takes precedence over older
      // GPS still embedded in the untouched original. Drop stale altitude too.
      captureTags.filter { it.startsWith("GPS") }.forEach { edited.setAttribute(it, null) }
      locationOverride?.let { (latitude, longitude) -> edited.setLatLong(latitude, longitude) }
    }
    edited.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
    edited.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, width.toString())
    edited.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, height.toString())
    edited.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
    edited.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
    edited.saveAttributes()
  }

  fun videoMetadata(source: File): List<Metadata.Entry> {
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(source.absolutePath)
      val raw = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION) ?: return emptyList()
      val location = parseVideoLocation(raw) ?: return emptyList()
      return listOf(Mp4LocationData(location.first.toFloat(), location.second.toFloat()))
    } finally {
      retriever.release()
    }
  }

  /** Android exposes ISO 6709 signed decimal degrees, with optional altitude. */
  internal fun parseVideoLocation(value: String): Pair<Double, Double>? {
    val match = Regex("^([+-]\\d+(?:\\.\\d+)?)([+-]\\d+(?:\\.\\d+)?)(?:[+-]\\d+(?:\\.\\d+)?)?/?$")
      .matchEntire(value.trim()) ?: return null
    val latitude = match.groupValues[1].toDoubleOrNull() ?: return null
    val longitude = match.groupValues[2].toDoubleOrNull() ?: return null
    if (!latitude.isFinite() || !longitude.isFinite() || latitude !in -90.0..90.0 || longitude !in -180.0..180.0) {
      return null
    }
    return latitude to longitude
  }
}
