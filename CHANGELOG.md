# Changelog

## 0.9.3

**Performance window**

- New **View → Performance…** window (⌥⌘P) showing what Chartdesk is costing the machine,
  refreshed once a second.
- **This Process** — CPU use with a peak reading, thread count, memory footprint with a peak
  reading, and how long the app has been running. Memory is `phys_footprint`, the same figure
  Activity Monitor shows in its Memory column.
- **System** — GPU utilisation, the GPU's name, core count and installed memory.
- **Charts** — image cache occupancy, cache hit rate, the time taken to decode the last chart
  and the slowest decode so far, plus library totals. These are the numbers that actually
  explain a stall when opening a large plate.
- **Reset Peaks** and **Empty Image Cache** buttons.
- GPU use is reported for the whole system, not for Chartdesk alone, and the window says so.
  macOS exposes no public per-process GPU figure.
- Sampling only runs while the window is open, so the tracker costs nothing when closed.

**Internal**

- `ChartImageStore` now tracks cache hits, misses, occupancy and decode timings behind a lock.
  `NSCache` does not expose its own count, so occupancy is counted here and is an upper bound.
- `clearCache()` was previously dead code and is now reachable from the Performance window.

## 0.9.2

**In-app updates**

- Chartdesk now checks GitHub for a newer release on launch and offers to install it.
- Choosing **Update and Relaunch** downloads the new release, quits Chartdesk, replaces the
  copy in your Applications folder, and reopens it.
- The previous version is removed automatically, but only once the new one is safely in
  place — if the copy fails, the old version is restored rather than leaving you with
  nothing installed.
- New **Chartdesk → Check for Updates…** menu item for checking on demand. An automatic
  check stays silent unless there is something to install; a manual one always reports back.
- New **Settings → General → Startup** toggle, "Check for updates on launch", on by default.
- Updates go through the GitHub CLI, because the repository is private and there is no token
  the app could safely carry. If `gh` is missing or signed out, the updater stays quiet
  instead of nagging.

**Fixed**

- Ad-hoc signing no longer fails when the project lives in an iCloud-synced folder. iCloud
  stamps Finder information onto the app bundle, which `codesign` refuses; `build.sh` now
  clears it before signing.

## 0.9.1

**Navigraph colour scheme**

- Reworked the entire interface to match the Navigraph Charts app: a dark navy shell with a
  blue accent, sampled from the real app.
- Chartdesk is now always dark and no longer follows the macOS light/dark setting.
- The sidebar and the chart list are painted as distinct panels, with matching hairlines
  between them.
- Accent-coloured text and icons use a brighter blue than filled controls do. The fill colour
  is only 2.7:1 against the dark shell and fails accessibility contrast as a foreground
  colour, while remaining perfectly legible as a button background.
- The two floating overlays are solid panels instead of translucent material, which was
  picking up the desktop wallpaper and casting colour across the navy.
- The canvas preset formerly called "Match System" is now "Chart Navy" and matches the rest
  of the app. Existing saved preferences still load.

**Chart categories**

- Reordered the category tabs to ARR, APP, APT, DEP, REF to match the Navigraph Charts app.
- The filename parser now has its own classification order, independent of the tab order.
  Previously the two were the same list, so rearranging the tabs could silently change which
  category a chart was filed under.

**Fixed**

- The "No Chart Selected" placeholder ignored both the canvas background preference and night
  mode, so it did not match the canvas it replaced.

## 0.9

- First release.
