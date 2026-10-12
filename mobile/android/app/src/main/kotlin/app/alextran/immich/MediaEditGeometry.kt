package com.inhousesoftware.photos

import kotlin.math.ceil
import kotlin.math.floor

/** Export boundary validation shared by photo and video paths; no Android state. */
internal object MediaEditGeometry {
  data class Crop(val x: Int, val y: Int, val width: Int, val height: Int)
  fun crop(values: List<Double>, width: Int, height: Int): Crop {
    require(width > 0 && height > 0) { "Invalid photo dimensions" }
    require(values.size == 4 && values.all(Double::isFinite)) { "Invalid crop" }
    val (left, top, right, bottom) = values
    require(left >= 0 && top >= 0 && right <= 1 && bottom <= 1 && right > left && bottom > top) { "Crop is outside the photo" }
    val x = floor(left * width).toInt().coerceIn(0, width - 1)
    val y = floor(top * height).toInt().coerceIn(0, height - 1)
    return Crop(x, y, (ceil(right * width).toInt() - x).coerceIn(1, width - x), (ceil(bottom * height).toInt() - y).coerceIn(1, height - y))
  }
  fun rotation(value: Int): Int {
    require(value % 90 == 0) { "Rotation must be a quarter turn" }
    return ((value % 360) + 360) % 360
  }
  fun trim(startMs: Long, endMs: Long?, durationMs: Long): Pair<Long, Long> {
    require(durationMs > 0) { "Video has no duration" }
    val end = endMs ?: durationMs
    require(startMs >= 0 && end <= durationMs && end > startMs) { "Invalid video selection" }
    return startMs to end
  }
}
