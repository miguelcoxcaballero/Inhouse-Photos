# Sharp grid reflow

## Shipped path

- Grid resizing reuses real thumbnail pixels by asset identity, independent of
  column count. Cached sheets are leased once per panel, not decoded into one
  new bitmap per cell. The extra cache is capped at 24 MiB / 12,000 entries.
- Capturing the old grid also retains sharp cells from completed disk-restored
  sheets. Coarser zooms cannot overwrite a sharper cache entry.
- FLIP rectangles animate photo rearrangement. Interrupted transitions start
  from current visual rectangles; scroll anchoring no longer adds a second-frame
  jump. New thumbnail decoding yields while interacting. Stationary thumbnails
  use full physical pixel resolution, including dense zooms.
- Asset-change notifications refresh metadata separately from bucket geometry.
  Same-count uploads, edits and hashes are not discarded. The bounded refresh
  queue still coalesces database notifications.
- Main pagination uses `(timeline_at, created_at, source, id)` consistently in
  both ordering and cursor predicates, including ties between local/cloud IDs.
- Failed local thumbnail generation advances to the next ID and retries on the
  next sweep instead of blocking the first batch forever.

## Cold-load native prototype (not enabled in the gallery)

`ContactSheetPrototype` / `ContactSheetPlugin` combine up to 96 Android local
thumbnails into one platform response and one Dart image upload. It accepts
only MediaStore IDs, bounds dimensions, runs off the platform/UI thread, allows
one outstanding sheet, preserves gaps for failed cells, and cancels on detach.
Android <29 returns unsupported. It does not handle cloud-only assets.

Run on an Android phone with media permission and representative local IDs:

```sh
flutter test integration_test/contact_sheet_benchmark_test.dart --profile -d DEVICE \
  --dart-define=CONTACT_SHEET_IDS=123,124,125
```

Compare its native and end-to-end timings with the existing per-cell gallery
instrumentation on the same assets, cold and warm, and check orientation,
HDR, videos, cancellation and peak memory. Do not enable it merely because
platform round trips are fewer. No attached physical phone was available for
this change's device benchmark; this prototype is deliberately not a claimed
performance win or a replacement for the verified production path.

Previously unseen cloud photos still require a first network fetch. Cache reuse
removes repeat decoding during zoom; it cannot promise zero cold-load time or
120 Hz on every device. Profile frame-time percentiles on target phones.
