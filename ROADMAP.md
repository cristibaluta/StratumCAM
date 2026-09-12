# StratumCAM — Implementation Roadmap

Last updated after: spiral pocket clearing (`.spiral`, Step 1B.1)
concave-row bug fix (`SCEngine+Pocketing.swift`, `Raster_Tests.swift`) + raster
helix-entry bounding fixes (`SCEngine+Contour.swift`, `SCEngine+Pocketing.swift`,
`PocketEntry_Tests.swift`) + Track 1C added (raster multi-span rows +
selectable axis, not yet started)

## How to use this doc with Claude

Each step below is sized to be **one self-contained Claude session**: one new file
(or one focused edit to an existing one) + its test, compiling and green before
moving on. Don't ask for a whole "Track" in one message — ask for one step, review,
commit, then move to the next. That's what keeps sessions from blowing up mid-feature.

Suggested prompt shape per step:
> "Implement Step X.Y from the roadmap. Follow the existing code style in SCEngine+Contour.swift. Add a test file in the style of Engraving_Tests.swift and add also a demo following the DemoContour style."

---

## Track 1 — Pocketing (`.pocket`) — Phase 3

Track 1 is complete. Boundary offsetting and the concentric ring stack
(`pocketRings` / `chainedRingSegments`), the raster pattern, entry integration
(plunge/ramp/helix for both pattern types), Z stepdown, and test coverage are
all done -- see 1.1-1.4 below. Next up is Track 1C (raster multi-span rows +
selectable axis), Track 1B (new `ClearingPattern` cases), or Track 2 (new
`MachiningOperation` cases), whichever you'd rather pick up.

- DONE **1.1 — `raster` pocket: parallel scanline clearing**
  Independent algorithm from the ring stack — bounding-box scanlines clipped against
  the contour, alternating direction (boustrophedon) or same-direction with rapid
  retracts, per `direction` (climb/conventional) via stepover sign. Its own
  multi-step item if large:
  - 1.1a: scanline generation + clipping against a single closed contour (no islands)
  - 1.1b: entry strategy integration (helix/ramp reused from `.contour`'s entry code)

- DONE **1.2 — Pocket entry integration**
  Wire `EntryStrategy` (already fully built for profile: plunge/ramp/helix) into
  pocket's first plunge point for both pattern types. Should be a thin reuse of
  `helixEntryWaypoints`/`rampWaypoints` from `SCEngine+Profile.swift`, not a rewrite.
  `buildPocketToolpath` currently plunges/retracts straight down via the shared
  `buildWaypoints` default — this replaces that for the pocket case specifically.

- DONE **1.3 — Multi-pass Z stepdown for pockets**
  Same `calculateZPasses` reuse as profile — confirm pocket geometry (rings or
  scanlines) is only computed once and Z-passes reuse it (don't regenerate per Z
  pass, that's wasted work and a source of divergent bugs between passes).
  `buildPocketToolpath` is currently single-pass at `settings.targetDepth`.

- DONE **1.4 — Tests**
  Coverage landed across four files rather than one extended `Pocket_Tests.swift`
  (`Raster_Tests.swift`, `PocketEntry_Tests.swift`, `PocketZPasses_Tests.swift`,
  plus the original `Pocket_Tests.swift`): raster coverage on a rectangle,
  stepover honored for raster (including the fencepost/uneven-stepover case and
  a direct `rasterScanlines` unit test), entry-strategy waypoints present for
  both pattern types (ramp + helix, single-pass and multi-pass `previousZ`
  threading), multi-pass Z depths correct for both pattern types.
  While extending this coverage, found and fixed a real bug: `rasterScanlines`
  took `xs.first`/`xs.last` regardless of how many times a row crossed the
  boundary, so a concave (non-convex) single-boundary contour with a re-entrant
  row -- e.g. a notch, no island/model-change needed -- would bridge straight
  across the empty gap as one wrong cut instead of being skipped, contradicting
  the function's own doc comment. Now guards on exactly 2 crossings (deduping
  crossings that land on a shared segment vertex first). Regression test:
  `Raster_Tests.testRasterSkipsConcaveReentrantRows`.

> Note: islands (pockets with interior obstacles to avoid) aren't in the current
> `Contour` model at all — it's a flat entity list with no "this is an island inside
> that boundary" relationship. That's a model change, bigger than pocketing itself.
> Worth a separate conversation before finishing this track if islands matter to
> you — flagging again so it doesn't get silently assumed away.

---

## Track 1C — Raster pattern: multi-span rows + selectable axis

Follow-up to 1.1/1.4 above, prompted by `demoRasterConcaveStapleSkipsBridgingRows`:
`rasterScanlines` currently only handles the single-span case (exactly 2 boundary
crossings per row) and only rasters along X. A concave boundary with a
re-entrant notch (the staple demo -- two prongs joined by a wide base, no
island/model-change needed to reproduce it) correctly *skips* re-entrant rows
rather than bridging them wrong (that was 1.4's bug fix), but skipping means
the two prongs above the notch are never cleared by the raster pass at all.
Both pieces below are about closing that gap for real, plus letting the user
pick which axis rasters better for a given shape.

- **1C.1 — Multi-span scanline generation**
  Generalize `rasterScanlines`' per-row crossing logic from "expect exactly 2,
  skip otherwise" to the general scanline-fill rule: collect *all* crossings
  with the boundary, sort them, and pair them up sequentially (0↔1, 2↔3, 4↔5,
  ...) into N/2 independent spans for that row, rather than assuming one span
  or none. Each row's output becomes `[SC.Segment]` (already the per-row
  element type `chainedRingSegments` expects) instead of always exactly one
  `.line`. This is the same rule that'll be needed for islands later (an
  island's two edges just contribute two more crossings that carve a gap out
  of whatever span they land inside) -- worth writing it generally now even
  though islands themselves are still blocked on the `Contour` model change
  noted above.

- **1C.2 — Span-linking: rapid across already-cleared material, retract/re-enter otherwise**
  Once a row can produce multiple spans, chaining them (in `chainedRingSegments`
  or a raster-specific variant) needs to decide *how* to move from the end of
  one span to the start of the next, and that decision depends on whether the
  gap between them has already been cut away by an earlier row:
  - Track the X-range(s) actually cut by each row as rows accumulate top-to-
    bottom (or bottom-to-top, per `direction`) -- a running "cleared so far"
    interval set, not just the current row's own spans.
  - If the gap between two spans on the *current* row falls entirely inside
    the cleared-so-far region (i.e. a previous row already passed straight
    through what's now a notch, like the staple's base), link with a plain
    feed move through it at depth -- no retract needed, that space is open air.
  - If it doesn't (nothing below has cleared it yet -- this is exactly the
    first-row case flagged in conversation, but also any row whose gap is the
    *first* row to reach a given lobe, e.g. the very first row that enters
    each of the staple's two prongs), retract to `safeZ`, rapid to the next
    span's start, and re-enter with the operation's own `entry` strategy
    (plunge/ramp/helix, same `helixEntryWaypoints`/`rampWaypoints` reuse 1.2
    already established) rather than assuming a feed move is safe.
  - Reuse/extend `boundarySegments` (added in the helix-entry-offset fix) as
    the source of truth for "inside the pocket" -- the cleared-tracking above
    is a separate, additional bookkeeping structure, not a replacement for it.

- **1C.3 — Selectable raster axis (X or Y)**
  `rasterScanlines` hardcodes horizontal (X-direction) rows; add the option to
  raster along Y instead (vertical rows, stepping across in X) so the user can
  pick whichever axis suits a given pocket's shape better -- e.g. a long
  narrow pocket rasters far more efficiently (fewer rows, fewer entries/
  retracts) along its long axis than across it, and 1C.2's span-splitting
  above is itself axis-sensitive (a shape re-entrant along X may be simple
  along Y, like the staple: rastering along Y instead of X would clear both
  prongs and the base with zero multi-span rows at all). Likely surfaces as a
  new `axis: .x | .y` parameter on `.raster` (`SC+ClearingPattern.swift`) with
  `.x` as the default so existing callers/demos are unaffected; `rasterScanlines`
  internally transposes X/Y (scan along the chosen axis, step along the other)
  rather than duplicating the whole function for each axis.

- **1C.4 — Tests**
  New coverage in `Raster_Tests.swift`: multi-span row count/geometry matches
  a known re-entrant boundary (the staple shape makes a natural fixture,
  reused from the demo), the staple's two prongs are now actually cut (not
  just skipped) after 1C.1, span-linking picks feed-through vs.
  retract-and-re-enter correctly for both the "already cleared below" and
  "first row into a lobe" cases from 1C.2, and raster-along-Y produces the
  transposed geometry of the equivalent X-axis raster on a rotated fixture.
  Also worth a regression test asserting the now-fixed helix-entry bounding
  behavior (Step 1.2's follow-up fix, `PocketEntry_Tests.testRasterHelixEntryStaysWithinStockBoundary`)
  still holds once entries can happen per-span rather than only at the very
  first row.

---

## Track 1B — New `ClearingPattern` cases (`.spiral`, `.trochoidal`, `.morph`, `.adaptive`)

`SC+ClearingPattern.swift` picked up four new cases that `buildPocketToolpath`'s
`switch` in `SCEngine+Pocketing.swift` already has stubbed out as
`fatalError("Not implemented yet")` for each — no roadmap history yet. Same track
as `.offsetPattern`/`.raster` above because they're the same switch, the same
`buildPocketWaypoints` entry/Z-pass wrapper, and the same file — just four more
ways to produce `toolpathSegments` before that wrapper runs. Do these in the
order below; each is progressively harder to slot into the existing shape.

> Naming heads-up: this track's `.adaptive` is a `ClearingPattern` case used by
> `.pocket`. It is **not** the same thing as Track 3's `.adaptiveClearing`
> `MachiningOperation` (which takes an `AdaptiveType`, not a `ClearingPattern`).
> They're conceptually related — both chase constant radial engagement — which
> is exactly why `.adaptive` here should reuse Track 3's core algorithm rather
> than growing a second, divergent implementation. See 1B.4.

- DONE **1B.1 — `spiral` pocket: continuous inward/outward spiral**
  Reuses `pocketRings`' ring stack as interpolation control points: one full turn
  per ring, radius interpolating linearly between consecutive rings' radii, with
  a final closing turn held at the innermost ring's radius. Only takes effect on
  a genuinely circular boundary (`isSpiralEligible`: every segment a concentric
  arc, matching how a DXF `.circle` linearizes) -- anything else, including
  ellipses and rounded rectangles this doesn't specifically detect, falls back
  to the exact `.offsetPattern` ring-and-chain path instead of spiraling around
  a center that doesn't fit the boundary. `SC.Segment` has no continuously-varying-
  radius arc primitive, so the spiral itself is a polyline of short `.line`
  chords, tessellated finer (5°/step) than `helixEntryWaypoints`' own circular
  entry move, since this is the whole cut rather than a short hop clear of a wall.

- **1B.1b — `spiral` pocket: selectable direction (outside-in / inside-out)**
  1B.1 only walks `pocketRings`' ring stack in the order it's produced -- outer
  wall ring first, shrinking inward -- with `spiralSegments`' opening turn held
  at the outer (wall) radius and its closing turn held at the innermost radius.
  That's one legitimate real-world choice (engage the wall first while the tool's
  fresh, clear the floor last) but not the only one: entering near the center and
  finishing by cutting the wall once, last, is closer to what canned circular-
  pocket cycles (e.g. Fanuc G12/G13) and several CAM packages default to when
  wall finish matters most -- nothing re-touches the wall after that final pass.
  Add a `direction: .outsideIn | .insideOut` parameter on `.spiral`
  (`SC+ClearingPattern.swift`, mirroring 1C.3's `axis: .x | .y` parameter style)
  with `.outsideIn` as the default so existing callers/demos are unaffected:
  - For `.insideOut`, reverse the ring order (or generate rings inside-out to
    begin with) before interpolating in `spiralSegments`, and swap which end
    gets the "hold and fully close" bookend treatment -- opening turn holds at
    the innermost radius, closing turn holds at the outermost (wall) radius.
  - Entry moves too: `.outsideIn`'s first-ring entry (already wired per Step
    1.2) is the outer wall ring, still correct for that direction, but
    `.insideOut` needs to plunge at/near the innermost ring instead. Because
    `isSpiralEligible` only allows this path on a genuinely circular boundary,
    the innermost ring is itself a real (small) circle with a well-defined
    center -- this doesn't need the general "center of an arbitrary pocket"
    detection that's still blocked on the `Contour` model change flagged under
    Track 1 and 1B.3, it's just "plunge at the smallest ring instead of the
    largest one" once the ring order is reversed.
  - `isSpiralEligible`'s fallback behavior (non-circular boundary -> exact
    `.offsetPattern` ring-and-chain path) is unaffected either way; `direction`
    only matters once a boundary is already spiral-eligible.

- **1B.2 — `trochoidal` pocket: overlapping circular loop clearing**
  Advance along the pocket's centerline/boundary (reuse the same oriented
  chain `.offsetPattern` builds via `orientedForDirection`) while looping the
  cutter in small overlapping circles rather than a straight or offset pass —
  same shape of problem as Track 2B's slotting, so this is a reasonable one to
  pair with that step if working both tracks. Loop diameter/overlap driven off
  `tool.diameter` and `settings.cutting.stepoverPercentage`, same inputs raster
  already reads.

- **1B.3 — `morph` pocket: interpolated inner/outer boundary transition**
  Per the enum doc, this morphs passes between two differing boundary curves
  (e.g. an outer wall and an inner island) rather than offsetting one boundary
  repeatedly — which means it depends on the same island/inner-boundary
  relationship flagged as missing at the end of Track 1 above. Until `Contour`
  can express "this loop is nested inside that one," `morph` has no second
  boundary to interpolate toward. Treat this as blocked on that model change,
  not as a pure algorithm step — flag it again here so it isn't quietly
  attempted against a single flat boundary.

- **1B.4 — `adaptive` pocket: constant-engagement fill**
  Do this last in the sub-track, and ideally after Track 3.1 lands. Track 3.1
  builds the trochoidal/constant-engagement core algorithm for
  `.adaptiveClearing`'s `.clearing2D` case against the same "concentric rings as
  safe corridor" input this track already has from Step 1.1/2.2. `.adaptive`
  here should call into that same core (parameterized by
  `settings.cutting.stepoverPercentage` in place of `optimalLoad`, since
  `ClearingPattern` has no load parameter of its own to pass in) rather than
  re-deriving constant-radial-load geometry a second time. If Track 3 hasn't
  landed yet when this is picked up, flag that dependency rather than building
  a parallel adaptive engine here.

- **1B.5 — Tests**
  New cases in `Pocket_Tests.swift` (or a new `PocketClearingPatterns_Tests.swift`
  if `Pocket_Tests.swift` is getting large): spiral continuity on a circular
  pocket, spiral fallback behavior on a non-circular one, trochoidal loop
  overlap honors stepover, `adaptive` pattern matches Track 3's core output on
  the same input geometry once 1B.4 lands. No test for `morph` until 1B.3's
  model-change blocker is resolved.
  > Spiral's two cases (continuity + fallback) are already covered, in their own
  > `PocketSpiral_Tests.swift` rather than `Pocket_Tests.swift` -- landed
  > alongside 1B.1 itself rather than deferred here. What's left for this step
  > is trochoidal (1B.2) and adaptive (1B.4)'s coverage, plus 1B.1b's
  > `.insideOut` direction once that lands: same continuity check as
  > `.outsideIn`'s but bookends swapped (opens at innermost radius, closes at
  > outermost), and entry-point placement at the innermost ring instead of the
  > outer wall ring.

---

## Track 2 — New operations from the `MachiningOperation` model

Four cases exist on `SC.MachiningOperation` (`facing`, `slotting`, `tapping`,
`boring`) and are already wired into `SCEngine.buildToolpath`'s switch, but each
is currently a `print(...); return nil` stub with no roadmap history. Treat these
as four small independent sub-tracks — none of them depend on each other.

### 2A — Facing (`.facing`)

- **2A.1 — Facing bounds + raster geometry**
  Compute the area to clear from `SC.Stock` bounds expanded by `extensionLength`
  (facing needs a footprint, not a contour — it cleans the whole top surface, not
  a selected feature). Generate scanline geometry only, per `stepover`, no
  waypoints yet. This likely wants a `Stock`-driven entry point separate from
  `buildToolpath`'s per-contour signature — flag if so rather than forcing it in.

- **2A.2 — Facing toolpath + direction**
  Turn the scanlines into waypoints (rapid/retract wrapper, single Z pass — facing
  is a one-pass datum operation), honoring `direction` for climb/conventional
  scanline order. Wire into the switch, replacing the stub.

- **2A.3 — Tests**
  New `Facing_Tests.swift`: stepover honored, extension applied beyond stock
  bounds, scanline order flips with direction.

### 2B — Slotting (`.slotting`)

- **2B.1 — Basic slot toolpath (no entry)**
  `buildSlottingToolpath`: follow the contour's centerline directly (no offset —
  slotting cuts full width on the curve itself, unlike profile), single pass at
  `depthPerPass` depth. Wire into the switch.

- **2B.2 — Multi-pass depth + entry integration**
  Repeat at successive `depthPerPass` increments down to target depth (reuse
  `calculateZPasses`-style logic), and wire `entry` (plunge/ramp/helix, reused
  from profile) for the first pass's start point.

- **2B.3 — Tests**
  New `Slotting_Tests.swift`: centerline followed with no lateral offset, correct
  number of passes for a given total depth, entry waypoints present.

### 2C — Boring (`.boring`)

Closest in shape to drilling — reuse its structure.

- **2C.1 — Basic boring cycle**
  `buildBoringToolpath`: rapid to XY at safeZ, plunge to depth, then circular
  interpolation at `targetDiameter / 2` radius (unlike drilling's straight plunge,
  boring cuts a circle at the bottom), retract. Wire into the switch.

- **2C.2 — Dwell + shift retract**
  Add `dwellTime` (`G04`) at the bottom before retracting when non-nil, and offset
  the tool off-center (`shiftRetract`) before the retract move when true, to avoid
  dragging the tool across the finished bore wall.

- **2C.3 — Tests**
  New `Boring_Tests.swift`: circular interpolation radius matches
  `targetDiameter / 2`, dwell emitted only when `dwellTime` is set, retract path
  shifts off-center only when `shiftRetract` is true.

### 2D — Tapping (`.tapping`)

Most algorithmically involved of the four — do it last within this track.

- **2D.1 — Helical thread-milling core**
  `buildTappingToolpath`: generate a helical path stepping down by `pitch` per
  revolution around the hole (internal) or boss (external) at the tool's
  compensated radius. This is a genuinely new geometry shape, not a reuse of
  existing offset/helix code — expect sub-steps once you're in it.

- **2D.2 — Internal vs external (`isInternal`) + direction**
  Handle the offset sign difference between milling threads inside a hole vs. on
  an external boss, and wire `direction` (climb/conventional) to the helix's
  winding sense.

- **2D.3 — Tests**
  New `Tapping_Tests.swift`: Z increment per revolution matches `pitch`, internal
  vs. external radius offset sign, winding direction matches `direction`.

---

## Track 3 — Adaptive clearing (`.adaptiveClearing`) — Phase 4

Do this last — it's the most algorithmically involved, and steps 3.x below assume
Track 1's ring-offset and raster machinery already exist to build on.

- **3.1 — Trochoidal/constant-engagement core algorithm (2D clearing only)**
  Start with `.clearing2D` only, ignore `.adaptiveContour` for now. Reuse Track 1's
  concentric offset rings as the "safe corridor," then generate a path that
  maintains `optimalLoad` engagement rather than pocketing's simple concentric
  fill. This is a genuinely hard geometry problem — expect several sub-steps once
  you're in it.

- **3.2 — Helical/ramped entry for adaptive** (thin reuse of existing entry code, same as 1.2)

- **3.3 — `.adaptiveContour` variant**

- **3.4 — Tests**

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

- DINE **5.5 — Smooth marker interpolation between points**
  The marker currently jumps point-to-point, which is fine at the tessellation
  density most curved demos already produce, but looks chunky on coarse paths
  (e.g. a rectangle's 4 corners, or `demoPocketRectangle`'s straight ring
  edges). Let `scrubIndex` stay a `Double`, and linearly interpolate the
  marker's position (not the drawn toolpath prefix — that stays index-based)
  between `floor(scrubIndex)` and `ceil(scrubIndex)` for smoother scrubbing
  without changing the underlying point density.

- **5.6 — Multi-pass awareness**
  If 5.1 flattened every Z pass into one array, scrubbing across a multi-pass
  demo (e.g. `demoMultiPassZStepdown`, `demoHelixEntryMultiPass`) will jump in Z
  when crossing from one pass's last point into the next pass's first point,
  since consecutive passes retrace the same XY at different depths. Decide
  whether that's acceptable as-is (it does reflect real machine motion --
  retract, move to the next pass) or whether the slider should be pass-aware
  (e.g. a segmented pass picker alongside the intra-pass slider). This is a
  decision point, not an assumed follow-up -- flag it rather than picking
  silently.

- **5.7 — Optional: play/pause animation**
  A play button that auto-increments `scrubIndex` on a timer for a hands-free
  walkthrough. Nice-to-have on top of manual scrubbing, not required for the
  core ask.

- **5.8 — Tests**
  This track lives in `StratumCAMDemo`, which currently has zero test coverage
  of its own (all existing tests target the `StratumCAM` package). Only the
  pure-geometry helpers from 5.2/5.3 are realistically unit-testable -- if
  they're written as standalone functions/methods rather than inline closures,
  add a small new test file for them (e.g. prefix-slice returns the right
  point count and leaves later points untouched; circle-vertex generator
  produces the requested point count centered on the given point). If they end
  up as inline SwiftUI/Metal glue instead, note that as a deliberate trade-off
  rather than silently skipping coverage.