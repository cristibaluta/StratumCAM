# StratumCAM — Implementation Roadmap

Last updated after: spiral pocket clearing (`.spiral`, Step 1B.1)
concave-row bug fix (`SCEngine+Pocketing.swift`, `Raster_Tests.swift`) + raster
helix-entry bounding fixes (`SCEngine+Contour.swift`, `SCEngine+Pocketing.swift`,
`PocketEntry_Tests.swift`) + Track 1C added (raster multi-span rows +
selectable axis, not yet started) + trochoidal pocket clearing (`.trochoidal`,
Step 1B.2, `SC+ClearingPattern.swift`/`SCEngine+Pocketing.swift`/
`Trochoidal_Tests.swift`/`DemoPocketing.swift`) + `SC+ClearingPattern.swift`
and `SC+MachiningOperation.swift` picked up a `PocketClearingPattern` /
`SlottingPattern` / `ClearingPattern` split (see Track 1B intro and Track 2B
below) + facing footprint/scanline geometry (`facingArea`/`facingScanlines`,
Step 2A.1, `SCEngine+Facing.swift`/`Facing_Tests.swift`, not yet wired into
`buildToolpath`)

## How to use this doc with Claude

Each step below is sized to be **one self-contained Claude session**: one new file
(or one focused edit to an existing one) + its test, compiling and green before
moving on. Don't ask for a whole "Track" in one message — ask for one step, review,
commit, then move to the next. That's what keeps sessions from blowing up mid-feature.

Suggested prompt shape per step:
> "Implement Step X.Y from the roadmap. Follow the existing code style in SCEngine+Contour.swift. Add a test file in the style of Engraving_Tests.swift and add also a demo following the DemoContour style."

---

## Track 4 — Cross-cutting, do opportunistically alongside the tracks above

Not urgent, don't block feature work on these, but pick them up when convenient:

- **4.1 — G-code: per-tool spindle speed / tool change (`M6 T#`, `M3 S#` per tool)**
  Becomes necessary once a job mixes drilling + profile + chamfer + the new
  operations from Track 2. `SCGCodeEngine` currently only overrides spindle speed
  for the drilling case (Step 1.5's scope) — needs to generalize that to read
  `toolpath.tool` / `toolpath.settings` per toolpath for every operation type.

- **4.2 — Stock model integration**
  `SC.Stock` exists and Track 2A (facing) will be its first real consumer, but
  nothing else checks against it yet. At minimum: warn/clip when a toolpath goes
  outside stock bounds. Real stock-aware simulation (remaining material tracking)
  is a much bigger effort than clipping and can stay a stretch goal.

---

## Track 5 — StratumCAMDemo: toolpath progress scrubber

Demo-app-only track — nothing here touches `StratumCAM`'s toolpath generation.
Goal: a slider in the demo UI that scrubs through the currently-shown toolpath's
`SIMD3<Float>` points, draws a small marker circle at the current position, and
draws the toolpath only from its start up to that position (not the whole path)
so it reads as "how far the cut has gotten," not just a static preview. Each
step below should compile and look right in the running app before moving to
the next; verify by temporarily hardcoding a scrub value/index if the previous
step's plumbing isn't wired to UI yet.

- DONE **5.1 — Expose the raw toolpath points from `Demo.DemoResult`**
  `Demo.run(contours:...)` already builds `toolpathPoints: [SIMD3<Float>]`
  internally (`Demo.swift`, ~line 49) before turning it into a prebuilt
  `RenderBatch` and discarding the array. Add a `toolpathPoints: [SIMD3<Float>]`
  field to `DemoResult` and return it alongside `batches`/`gcode`. For now,
  flatten every Z pass's points into one continuous array in generation order
  (same order the existing full-toolpath batch already draws) — per-pass
  awareness is deferred to 5.6. Pure data plumbing, no UI or rendering change
  yet.

- DONE **5.2 — Prefix-slice helper: partial toolpath batch from an index**
  Add a small, testable helper (free function or a method that doesn't need
  `self`/Metal state beyond a device) that takes `toolpathPoints` and an
  integer index and returns just the point prefix up to that index. Reuse
  `buildVertices(points:color:zOffset:)`'s existing logic (make it accessible
  from this new helper, or duplicate the few lines if that's cleaner) to turn
  the prefix into a `RenderBatch` the same way the full toolpath is built
  today. Verify by hardcoding an index partway through a demo's points and
  confirming the yellow toolpath visibly stops short instead of drawing the
  whole thing.

- DONE **5.3 — Marker circle geometry at a point**
  Add a pure-geometry helper that generates a small flat circle's worth of
  `RenderVertex`s (e.g. 24-32 point loop, `.lineStrip`, closed) centered on a
  given `SIMD3<Float>`, in its own distinct color (something that reads clearly
  against the existing blue contour / yellow toolpath — e.g. bright red or
  white) so it's obviously "you are here" rather than part of the path. Wire it
  as one more `RenderBatch` appended alongside the sliced toolpath batch from
  5.2. Verify the same way as 5.2: hardcode a test index/point first.

- DONE **5.4 — Slider UI in `ContentView`, wired to 5.1-5.3**
  Add `@State private var toolpathPoints: [SIMD3<Float>] = []` and
  `@State private var scrubIndex: Double = 0` to `ContentView`. Add a
  `Slider` bound to `scrubIndex`, ranged `0...Double(max(0, toolpathPoints.count - 1))`,
  placed somewhere sensible (a bottom overlay on the 3D canvas next to the
  existing "Controls: Drag to Orbit..." hint is the natural spot). On change,
  rebuild `renderBatches` as `[contour batch, sliced toolpath batch (5.2),
  marker batch (5.3)]` and reassign. In `show(_:)`, store the new demo's
  `toolpathPoints` and reset `scrubIndex` to the last index, so switching demos
  always starts fully drawn rather than at a stale scrub position from whatever
  was previously selected.

- DONE **5.5 — Smooth marker interpolation between points**
  The marker currently jumps point-to-point, which is fine at the tessellation
  density most curved demos already produce, but looks chunky on coarse paths
  (e.g. a rectangle's 4 corners, or `demoPocketRectangle`'s straight ring
  edges). Let `scrubIndex` stay a `Double`, and linearly interpolate the
  marker's position (not the drawn toolpath prefix — that stays index-based)
  between `floor(scrubIndex)` and `ceil(scrubIndex)` for smoother scrubbing
  without changing the underlying point density.

- **5.6 — Split z layers**
  Make a panel with a list of all layers and their z value. by default an option to see all layers will be selected. then i can select individual layers and preview them. the slider will scrub only the selected layer, i want to have finer control of the movement for long operations this way. the panel will open from the scrub bar in a tooltip

- **5.7 — different colors for different commands**
  I want to see fast moving segments with a more reddish color.
