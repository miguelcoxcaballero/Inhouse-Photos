package com.inhousesoftware.photos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaEditGeometryTest {
  @Test fun fullImageDoesNotLoseTheLastPixel() {
    assertEquals(MediaEditGeometry.Crop(0, 0, 4033, 3025), MediaEditGeometry.crop(listOf(0.0, 0.0, 1.0, 1.0), 4033, 3025))
  }
  @Test fun cropIncludesFractionalEdgePixelsAndFitsOriginal() {
    assertEquals(MediaEditGeometry.Crop(100, 40, 234, 360), MediaEditGeometry.crop(listOf(0.1, 0.1, 0.3333, 1.0), 1000, 400))
    assertEquals(MediaEditGeometry.Crop(9, 9, 1, 1), MediaEditGeometry.crop(listOf(0.99, 0.99, 1.0, 1.0), 10, 10))
  }
  @Test fun invalidCropsAreRejectedBeforeBitmapAllocation() {
    listOf(listOf(-0.1, 0.0, 1.0, 1.0), listOf(0.0, 0.0, 1.1, 1.0), listOf(0.5, 0.0, 0.5, 1.0), listOf(Double.NaN, 0.0, 1.0, 1.0)).forEach {
      assertThrows(IllegalArgumentException::class.java) { MediaEditGeometry.crop(it, 100, 100) }
    }
  }
  @Test fun rotationNormalizesClockwiseAndCounterclockwiseTurns() {
    assertEquals(270, MediaEditGeometry.rotation(-90))
    assertEquals(90, MediaEditGeometry.rotation(450))
    assertEquals(0, MediaEditGeometry.rotation(720))
    assertThrows(IllegalArgumentException::class.java) { MediaEditGeometry.rotation(45) }
  }
  @Test fun trimPreservesMillisecondPrecisionAndRejectsEmptyOrOutOfBoundsRanges() {
    assertEquals(123L to 2345L, MediaEditGeometry.trim(123, 2345, 5000))
    assertEquals(0L to 5000L, MediaEditGeometry.trim(0, null, 5000))
    listOf(-1L to 10L, 10L to 10L, 20L to 10L, 0L to 5001L).forEach { (start, end) ->
      assertThrows(IllegalArgumentException::class.java) { MediaEditGeometry.trim(start, end, 5000) }
    }
  }
  @Test fun videoLocationPreservesEquatorAndMeridian() {
    assertEquals(0.0 to 0.0, MediaEditorMetadata.parseVideoLocation("+00.0000+000.0000/"))
    assertEquals(-33.9 to 151.2, MediaEditorMetadata.parseVideoLocation("-33.9+151.2+010.0/"))
    assertNull(MediaEditorMetadata.parseVideoLocation("+91.0+000.0/"))
    assertNull(MediaEditorMetadata.parseVideoLocation("not a location"))
  }
}
