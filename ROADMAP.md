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
`switch` in `SCEngine+Pocketing.swift` had stubbed out as
`fatalError("Not implemented yet")` for each. `.spiral` (1B.1/1B.1b) and now
`.trochoidal` (1B.2, below) are wired up; `.adaptive` and `.morph` are still the
`fatalError` stub. Same track as `.offsetPattern`/`.raster` above because
they're the same switch, the same `buildPocketWaypoints` entry/Z-pass wrapper,
and the same file — just four more ways to produce `toolpathSegments` before
that wrapper runs. Do these in the order below; each is progressively harder to
slot into the existing shape.

> Naming heads-up: this track's `.adaptive` is a `ClearingPattern` case used by
> `.pocket`. It is **not** the same thing as Track 3's `.adaptiveClearing`
> `MachiningOperation` (which takes an `AdaptiveType`, not a `ClearingPattern`).
> They're conceptually related — both chase constant radial engagement — which
> is exactly why `.adaptive` here should reuse Track 3's core algorithm rather
> than growing a second, divergent implementation. See 1B.4.

> Model shape update: `SC.MachiningOperation.pocket` now takes a
> `PocketClearingPattern` (offset/raster/spiral/morph/trochoidal/adaptive), not
> the raw `ClearingPattern` enum directly, and a new `SC.SlottingPattern`
> (raster/trochoidal/adaptive — the subset that makes sense on a slot's
> centerline, no offset/spiral/morph) has been added alongside it for `.slotting`
> to eventually use (see Track 2B). Both front-end enums expose a computed
> `.strategy: ClearingPattern` that maps their cases onto the same shared
> low-level enum — presumably so `.pocket` and `.slotting` can eventually share
> one pattern-implementation switch instead of each engine function growing its
> own copy. That indirection isn't wired up anywhere yet: `buildPocketToolpath`
> still `switch`es on `PocketClearingPattern`'s own cases directly (never reads
> `.strategy`), and `.slotting` doesn't take a pattern parameter at all yet. Flag
> this for whoever picks up 1B.4/1B.5 or starts Track 2B — either wire
> `buildPocketToolpath` to switch on `.strategy` so `buildSlottingToolpath` can
> reuse the same cases later, or, if that's overkill for two callers, consider
> whether the unused `ClearingPattern`/`.strategy` layer should be trimmed back
> rather than carried forward unused. Worth a quick conversation before assuming
> either way.

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

- DONE **1B.1b — `spiral` pocket: selectable direction (outside-in / inside-out)**
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

- DONE **1B.2 — `trochoidal` pocket: overlapping circular loop clearing**
  `trochoidalSegments` advances along the same oriented boundary chain
  `.offsetPattern`/`.spiral` build via `orientedForDirection`, centering a loop
  of radius `tool.diameter / 2` every `stepoverPercentage * tool.diameter`
  along that chain (same fencepost convention as `rasterScanlines`' last row
  and `calculateZPasses`' last depth — the final loop is pinned exactly at the
  boundary's end rather than landing short of or past it), connecting
  consecutive loops with a short straight move in `chainedRingSegments`'
  one-move-per-transition style. Because every loop is centered directly on
  the boundary, consecutive loops always overlap by construction, so unlike
  raster's span-linking (1C.2) it never needs retract/re-entry bookkeeping
  between loops. Wired into `buildPocketToolpath`'s `switch` and covered by
  `Trochoidal_Tests.swift` (loop diameter/spacing on a straight boundary,
  scaling with a different tool/stepover, entry/Z-pass wrapper reuse, geometry
  reused unchanged across Z passes, rejects open contours) plus three demos in
  `DemoPocketing.swift` (rectangle, conventional-direction rectangle, circle).
  > Flag: `trochoidalSegments` currently ignores `PocketClearingPattern
  > .trochoidal`'s own `TrochoidalSettings` payload (`radialEngagement`,
  > `loopRadius`) entirely — the switch case doesn't even bind it
  > (`case .trochoidal:`). Loop size and spacing are derived purely from
  > `tool.diameter` and `settings.cutting.stepoverPercentage` instead, the same
  > inputs raster/spiral already read. Either `TrochoidalSettings` needs wiring
  > in (so a caller's explicit `radialEngagement`/`loopRadius` actually takes
  > effect) or the struct's fields are redundant with the machine-settings-driven
  > approach and should be reconsidered — worth resolving before more callers
  > start passing settings that get silently ignored.

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
  > alongside 1B.1 itself rather than deferred here. 1B.1b's `.insideOut`
  > direction is also already covered, in `PocketSpiralDirection_Tests.swift`
  > (bookend swap vs. `.outsideIn`, innermost-ring entry placement, same ring
  > radii visited in reverse, bare `.spiral` still defaulting to `.outsideIn`).
  > Trochoidal (1B.2) is covered too, in `Trochoidal_Tests.swift`. What's left
  > for this step is adaptive (1B.4)'s coverage once that lands.

---

## Track 2 — New operations from the `MachiningOperation` model

Four cases exist on `SC.MachiningOperation` (`facing`, `slotting`, `tapping`,
`boring`) and are already wired into `SCEngine.buildToolpath`'s switch, but each
is currently a `print(...); return nil` stub with no roadmap history. Treat these
as four small independent sub-tracks — none of them depend on each other.

### 2A — Facing (`.facing`)

- DONE **2A.1 — Facing bounds + raster geometry**
  `SCEngine+Facing.swift`: `facingArea(stock:extensionLength:)` grows the stock's
  own top-face rectangle by `extensionLength` on every side (no tool-radius
  compensation folded in beyond that — `extensionLength` is the operation's own
  explicit margin). `facingScanlines(stock:extensionLength:stepover:direction:)`
  fills that rectangle with parallel rows spaced by `stepover`, boustrophedon
  (alternating direction row to row, same convention as pocketing's
  `rasterScanlines`), snapping the last row to the footprint's far edge on an
  unevenly-divisible stepover (same fencepost rule as `rasterScanlines`/
  `calculateZPasses`). Unlike pocketing's raster there's no boundary to clip
  against — the footprint is already a plain rectangle — so no intersection math
  is needed; every row spans the full width directly. Geometry only, returned as
  `[[SC.Segment]]` (same per-row shape `rasterScanlines` uses) so a later
  waypoint wrapper can reuse `chainedRingSegments` to link rows. Not wired into
  `SCEngine.buildToolpath`'s switch yet — that's 2A.2 — and deliberately not
  exposed as a new `Stock`-driven public entry point yet either, since there's
  nothing to call it from until 2A.2 decides that shape (see the flag below).
  Covered by `Facing_Tests.swift`: footprint expansion (zero and non-zero
  `extensionLength`, non-zero stock `origin`), row count/spacing/full-width span,
  climb-vs-conventional starting direction and per-row alternation, the uneven-
  stepover fencepost case, and empty output for a zero-area stock or non-positive
  stepover.
  > Flag (assumption, since `Stock` had no prior consumer to confirm against):
  > `facingArea` reads `stock.origin` as the top-face min-X/min-Y corner — the
  > rectangle spans `origin.x ... origin.x + width` / `origin.y ... origin.y +
  > height` — not a center-referenced stock. This matches `origin`'s own doc
  > comment ("WCS G54 origin") under the common shop convention of touching off
  > G54 at a stock corner, and is consistent with `targetDepth` treating Z=0 as
  > the stock's top surface rather than its middle. Worth confirming before 2A.2
  > builds waypoints on top of it — if stock is actually center-referenced, or
  > `origin` marks a different corner, `facingArea` needs revisiting first.
  > Also still open: `SCEngine.buildToolpath`/`generateToolpaths` are per-contour
  > (one `SC.Contour` in, zero-or-one `OutputToolpath` out), but facing has no
  > selected contour to iterate — it clears the whole stock footprint once. 2A.2
  > still needs to decide the actual entry point shape: a `Stock`-taking overload
  > of `generateToolpaths` (mirroring the existing `DrillingOperation` overload
  > that already solves a similar per-strategy signature mismatch), or something
  > else. Flagging again here so 2A.2 doesn't default into forcing `.facing`
  > through the per-contour path just because that's what's already wired up.

- DONE **2A.2 — Facing toolpath + direction**
  `buildFacingToolpath` (`SCEngine+Facing.swift`) chains `facingScanlines`' rows
  with `chainedRingSegments` (same row-linking helper pocketing's raster uses)
  and wraps the result with `buildWaypoints`' rapid/plunge/retract pass -- single
  `ToolpathPass` at `-abs(settings.targetDepth)`, no `calculateZPasses` stepdown,
  since facing is a one-pass datum operation. `direction` was already fully
  resolved by `facingScanlines` (2A.1) into which way each row travels, so there's
  nothing further for this step to do with it beyond passing it through. `.facing`
  has no `EntryStrategy` of its own, so there's no ramp/helix branch the way
  `buildPocketWaypoints` has -- always the plain straight-down plunge.
  This resolved 2A.1's open flag: since `.facing` clears a whole `Stock` footprint
  rather than iterating a selected contour, it can't go through the per-contour
  `buildToolpath` switch the way every other operation does. Added a new
  `SC.FacingOperation` struct (mirroring `DrillingOperation`'s existing solution to
  the same signature mismatch) and a matching
  `SCEngine.generateToolpaths(from operations: [SC.FacingOperation])` overload that
  calls `buildFacingToolpath` directly. The per-contour switch's `.facing` case is
  now a `nil`-returning stub with a comment pointing at the new overload, rather
  than the old `print(...)` placeholder.

- DONE **2A.3 — Tests**
  New coverage in `Facing_Tests.swift`: single-pass depth at `-abs(targetDepth)`
  with rows chained into one continuous rapid-plunge-trace-retract sequence,
  scanline order (and therefore the toolpath's own trace order) flipping with
  `direction` while the waypoint count stays the same, `extensionLength` wired
  end to end so the toolpath's own bounding box reflects it, a degenerate
  zero-area stock producing no toolpath, `.facing` yielding nothing through the
  per-contour `buildToolpath` switch (confirming 2A.2's flag stays true), and a
  batch of `FacingOperation`s each keeping its own tool/settings/depth
  independent. Also added `DemoFacing.swift` (climb, conventional, extended
  footprint, a larger-stock finer-stepover pass, and a two-stock batch) wired
  into `ContentView`'s sidebar under a new "Facing" section, plus a
  `Demo.run(facing:)` overload (mirroring `run(contours:...)`) since facing has
  no `SC.Contour` to linearize for the blue reference geometry -- it draws the
  stock's own top-face rectangle instead and calls
  `generateToolpaths(from operations: [SC.FacingOperation])` rather than the
  per-contour overload.

### 2B — Slotting (`.slotting`)

> Model shape update: `SC.SlottingPattern` (raster/trochoidal/adaptive) now
> exists in `SC+ClearingPattern.swift`, but `MachiningOperation.slotting` still
> only takes `(depthPerPass, entry)` — no pattern parameter yet, and
> `SCEngine.swift`'s `.slotting` case is still the original `print(...); return
> nil` stub, untouched by this. Before starting 2B.1, decide whether `.slotting`
> should grow a `pattern: SlottingPattern` parameter now (so "follow the
> centerline directly" becomes just one pattern case rather than the only
> option) or whether `SlottingPattern` is intentionally ahead of the operation
> it belongs to and 2B.1 should still ship the simple centerline-only version
> first. Trochoidal slotting in particular was already flagged as related work
> when 1B.2 (trochoidal *pocket*) landed — a slot is the same "advance along a
> chain, loop the cutter" problem `trochoidalSegments` already solves, so
> `SlottingPattern.trochoidal` reusing that function directly (rather than a
> second trochoidal implementation) is likely the intended path once this
> track picks a direction.

- DONE **2B.1 — Basic slot toolpath (no entry)**
  `buildSlottingToolpath` (`SCEngine+Slotting.swift`): `linearize`s the contour and
  traces it directly via `buildWaypoints` -- no `offsetContour` call, since a slot
  cuts full width on the curve itself rather than compensating to one side of it
  (`CutSide.onContour`'s own doc comment already describes exactly this "slotting
  grooves" case, even though `.slotting` doesn't take a `CutSide` parameter at
  all -- there's only ever the one side). Single `ToolpathPass` at
  `-abs(depthPerPass)`, same single-pass sign convention `buildDrillingToolpath`/
  `buildFacingToolpath` use. `entry` is destructured in the switch but not read
  yet (`case .slotting(let depthPerPass, _):`) -- every pass is a plain
  straight-down plunge until 2B.2 wires it in. Didn't grow `.slotting` a
  `pattern: SlottingPattern` parameter for this step (see the open note above) --
  shipped the simple centerline-only version first, per that note's second
  option, since this step is scoped to "no entry" and picking the pattern-vs-not
  question isn't needed to land it.

- DONE **2B.2 — Multi-pass depth + entry integration**
  `buildSlottingToolpath` now derives `zDepths` via `calculateZPasses(targetDepth:
  settings.targetDepth, stepdown: depthPerPass)` -- same reuse `.contour`/`.pocket`
  already do for their own `settings.cutting.stepdown`, just fed `depthPerPass`
  since that's slotting's own per-pass parameter rather than a shared cutting
  setting. `entry` is wired into `buildSlottingWaypoints` (new, private): `.plunge`
  is the existing `buildWaypoints` straight-down wrapper; `.ramp`/`.helix` are a
  thin reuse of `SCEngine+Contour.swift`'s `rampWaypoints`/`helixEntryWaypoints`,
  each pass covering only its own fresh stepdown (`previousZ` -> `z`, `previousZ`
  starting at `0` for pass 0), same convention `.contour`/`.pocket` use. Unlike
  `.pocket`'s `buildPocketWaypoints`, there's no separate wall-boundary parameter:
  slotting has no wall to stay clear of on either side, so `helixEntryWaypoints` is
  always called with `side: .onContour`, which resolves its internal
  `offsetDistance` to zero -- the helix circles centered exactly on the slot's own
  centerline, cutting material symmetrically on both sides as it descends, same as
  the straight trace itself already does.

- DONE **2B.3 — Tests**
  New `Slotting_Tests.swift`: centerline followed with no lateral offset (and
  independent of tool diameter), a multi-segment centerline traced vertex for
  vertex, correct pass count/depths for both an unevenly divisible depth and an
  evenly divisible one, geometry reused unchanged across Z passes (same
  guarantee `.pocket`/`.contour` already give), and entry waypoints present for
  all three `EntryStrategy` cases -- `.plunge` (retract/re-plunge every pass),
  `.ramp` (descends from `previousZ` to each pass's own target without
  overshooting), and `.helix` (arc motions present, centered exactly on the
  centerline since `side: .onContour` zeroes the offset) -- plus a batch case
  confirming multiple contours each get their own independent toolpath. Also
  added `DemoSlotting.swift` (straight-line and L-shaped centerlines, no-entry,
  multi-pass, ramp entry, helix entry) wired into `ContentView`'s sidebar under
  a new "Slotting" section.

- DONE **2B.4 — Rectangle slot boundary recognition (derive centerline from a boundary, not a line)**
  Real-world slots aren't drawn as their own centerline -- people draw the slot's
  actual physical boundary (the walls a same-width tool leaves behind), the same
  way any other feature gets drawn. `rectangleSlotCenterline(fromBoundary:tool:)`
  (`SCEngine+Slotting.swift`) bridges that gap for the plain-rectangle case:
  given a closed 4-straight-side rectangle, one pair of opposite sides within
  `tolerance` of `tool.diameter`, it derives the single centerline segment that
  reproduces exactly that boundary when traced by the tool -- inset by the tool
  radius at each end (along the long axis) so the swept circle reaches exactly
  the rectangle's own short ends, naturally rounding what a round tool can't
  help but round anyway. Handles any rotation (not axis-aligned-only), rejects
  anything that isn't recognizably that shape (wrong segment count, a curved
  side, non-perpendicular corners, unequal opposite sides, neither side pairing
  matching the tool, or too short once both ends are inset) by returning `nil`
  rather than guessing. Output is a plain open `SC.Contour` (one line), ready to
  hand straight to `generateToolpaths(from:tool:settings:operation:)` the same
  as any other `.slotting` centerline -- this is purely a preprocessing step,
  `buildSlottingToolpath` itself is unchanged.
  > Flag: a circular channel needs no equivalent step -- a single circle already
  > fully specifies its own centerline, so it's used directly (see
  > `demoSlottingClosedCircle`). The boundary equivalent for a circular slot --
  > two concentric circles `tool.diameter` apart, an annular boundary rather
  > than its already-known centerline -- can't be accepted yet: two disjoint
  > circles have no "these two loops are one feature" relationship in
  > `SC.Contour`'s current flat entity-list model, the same structural gap
  > already blocking pocket islands and `.morph` (see the note at the end of
  > Track 1 and Step 1B.3). Revisit once that model change lands.
  > Also flagged, unchanged from Track 2B's own intro: this still doesn't touch
  > the wider-than-tool case (`SlottingPattern.raster`/`.trochoidal`, model
  > exists, not wired into `.slotting` or this recognition step). A boundary
  > wider than the tool isn't a plain rectangle-minus-tool-radius centerline
  > problem at all -- it needs the pattern-based clearing this recognition step
  > deliberately doesn't attempt.
  Covered by new cases in `Slotting_Tests.swift`: correct inset for an
  axis-aligned rectangle, the derived centerline reproducing the boundary's own
  extents when actually traced, a rotated rectangle (long axis along Y),
  rejection for a mismatched width, a too-short rectangle, a non-rectangular
  parallelogram, a curved (stadium) boundary, and a non-closed boundary. Also
  added two demos to `DemoSlotting.swift`: `demoSlottingClosedCircle` (the
  already-supported direct-centerline case, for contrast) and
  `demoSlottingRectangleBoundary` (the new boundary-recognition path, blue
  reference drawn from the boundary itself rather than the derived centerline).

### 2C — Boring (`.boring`)

Closest in shape to drilling — reuse its structure.

- DONE **2C.1 — Basic boring cycle**
  `buildBoringToolpath` (`SCEngine+Boring.swift`): reuses `drillPoint(for:)` for
  hole-location recognition, same as drilling. Rapid to the hole's 3 o'clock edge
  (`point.x + targetDiameter / 2`) at safeZ, plunge straight down to depth at that
  off-center edge point, then circular interpolation around `point` at
  `targetDiameter / 2` radius back to the same edge point, then retract to safeZ.
  The circle is swept as two 180° arcs (`arcCCW`) rather than one 360° arc, matching
  `convert(entity:reversed:)`'s existing DXF-circle handling, since a single arc
  command with identical start/end position is ambiguous on many controllers. One
  `ToolpathPass`, same reasoning as drilling -- not 2D-geometry `calculateZPasses`
  stepdown. Wired into `buildToolpath`'s switch; `dwellTime`/`shiftRetract` are
  still ignored (`_`), deferred to 2C.2.

- DONE **2C.2 — Dwell + shift retract**
  The two parameters split across two different layers, since only one of them
  changes the actual toolpath geometry:
  - `shiftRetract` (`SCEngine+Boring.swift`, `buildBoringToolpath`): when true,
    inserts a `.linear` waypoint at depth between the final arc and the retract,
    shifted from the bore's edge toward `point` by `min(tool.diameter / 2, radius)`
    -- the tool's own radius, clamped so it can't overshoot past the hole's center
    on a bore not much wider than the tool -- so the rapid retract that follows
    lifts clear of the wall instead of dragging back across it. `false` keeps the
    original straight-up retract from 2C.1 unchanged.
  - `dwellTime` (`SCGCodeEngine.swift`): doesn't touch waypoint geometry at all
    (a stationary pause, same as drilling's dwell), so it's injected purely at
    G-code text generation time as a `G04 P...` line. Unlike drilling's dwell --
    which lives on `MachineSettings.dwell` and can assume "always the penultimate
    waypoint" since a drill cycle never inserts anything after its last cutting
    move -- boring's dwell lives on the operation itself (`.boring`'s own
    `dwellTime`, not machine-wide), and the shift waypoint above can sit between
    the last cutting move and the final retract, so the penultimate-waypoint
    shortcut isn't reliable here. Finds the pass's actual last `arcCW`/`arcCCW`
    waypoint instead and emits the dwell right after it, before any shift/retract
    move -- matching conventional fine-boring cycle order (cut -> dwell -> shift
    off the wall -> retract).

- DONE **2C.3 — Tests**
  `Boring_Tests.swift`: circular interpolation radius matches `targetDiameter / 2`
  (both from a `.point` and a closed-circle contour), a non-drill-point contour
  yields no toolpath, a batch of holes each get their own independent toolpath,
  `shiftRetract` false leaves the retract straight above the bore's edge,
  `shiftRetract` true inserts the inward shift waypoint before retracting, the
  shift clamps to the hole's center rather than overshooting when the tool
  radius exceeds the bore radius (plus the exact-match boundary case, tool
  radius == bore radius), and the circular interpolation/retract cut at the
  ordinary feed rate rather than the plunge rate. `GCode_Boring_Tests.swift`
  (new, alongside `GCode_Drilling_Tests.swift`): dwell emitted after the final
  arc and before the retract when `dwellTime` is set, no `G04` at all when it's
  `nil` or exactly `0`, with both `dwellTime` and `shiftRetract` on together the
  dwell still lands right after the final arc and strictly before the
  shift-off-center move, and a batch of holes each gets its own independent
  dwell line. `DemoBoring.swift` (new, alongside `DemoDrilling.swift`), wired
  into `ContentView`'s sidebar under a new "Boring" section: plain bore (from
  both a point and a closed-circle contour), dwell alone, shift retract alone,
  both together, and a batch of four bores.

- **2C.4 — Helical boring variant (plain end mill, no dedicated boring head)**
  Flagged in conversation after reviewing the 2C.1-2C.3 demos: the current
  `buildBoringToolpath` plunges straight down on-center-offset, then cuts one
  flat circle at the bottom -- that's a real, named technique (the classic
  Fanuc `G76`-style fine boring cycle), but it specifically assumes a dedicated
  adjustable boring head, where the cutting edge sticks out at a fixed radius
  and just spinning the spindle normally traces the circle -- no `G02`/`G03`
  needed, hence the plain vertical plunge. That's a mismatch with what this
  codebase's `ToolType` actually models: there's no `boringBar`/boring-head
  case at all (only `flatEndMill`/`ballEndMill`/`vBit`/`drill`), so `.boring`
  here implicitly means an ordinary end mill -- and an end mill can't trace a
  circle by spinning in place, it needs continuous `G02`/`G03` motion. The
  realistic technique for an end mill is helical interpolation: descend
  continuously while sweeping the circle (corkscrewing from top to target
  depth around `targetDiameter / 2`), finishing with one flat lap at the
  bottom to clean up, rather than plunging first and circling only at the
  bottom.
  - Reuse the existing helix machinery (`helixEntryWaypoints`,
    `SCEngine+Contour.swift`) rather than writing new spiral-descent math from
    scratch -- same reasoning Step 1.2 already established for pocket entry.
  - `shiftRetract` and `dwellTime` (2C.2) both still apply unchanged at the
    bottom of the helical descent -- only the top-to-bottom entry motion
    changes, not what happens once the tool reaches final depth.
  - Open question worth resolving before starting: is this a variant of
    `.boring` itself (e.g. a new parameter distinguishing "fine boring head"
    vs. "helical end-mill boring"), or a genuinely separate
    `MachiningOperation` case? They produce different G-code shapes for a
    reason -- a real boring head literally cannot follow a helical path (its
    cutting edge is fixed radius, no way to vary it mid-cut), so collapsing
    both into one case with a mode flag may be modeling two different
    machine/tooling realities as if they were one operation with options.
  - Not started -- do this later, as its own session per the roadmap's usual
    one-step-at-a-time shape.

### 2D — Tapping (`.tapping`)

Most algorithmically involved of the four — do it last within this track.

- DONE **2D.1 — Helical thread-milling core**
  `buildTappingToolpath`: generate a helical path stepping down by `pitch` per
  revolution around the hole (internal) or boss (external) at the tool's
  compensated radius. This is a genuinely new geometry shape, not a reuse of
  existing offset/helix code — expect sub-steps once you're in it.

- DONE **2D.2 — Internal vs external (`isInternal`) + direction**
  Handle the offset sign difference between milling threads inside a hole vs. on
  an external boss, and wire `direction` (climb/conventional) to the helix's
  winding sense.

- DONE **2D.3 — Tests**
  New `Tapping_Tests.swift`: Z increment per revolution matches `pitch`, internal
  vs. external radius offset sign, winding direction matches `direction`. Extended
  with negative-pitch normalization, fencepost-safe partial final turns (both a
  multi-turn overshoot check and a depth-shallower-than-pitch case), feed-rate
  propagation, constant-radius/consistent-winding checks across an entire
  multi-turn helix (not just the first waypoint), `OutputToolpath` carrying the
  right tool/settings, and a mixed circle/non-circle contour batch. Demo app got
  a matching "Tapping" section in `DemoTapping.swift` covering all four
  internal/external x climb/conventional combinations, a deep multi-turn thread,
  and a multi-hole batch.

  **Bug fix, found while building the demos:** the original 2D.1/2D.2 helix cut
  top-to-bottom and entered/retracted at the cutting radius itself -- so the
  final retract dragged the tool straight back up through the thread it had
  just cut, at full engagement. Reworked `buildTappingToolpath` to match how
  thread milling actually works: rapid down the hole's/boss's own *center*
  (unobstructed) to the bottom, feed sideways once to engage the wall, helix
  *upward* one revolution per `pitch` so chips clear instead of packing in,
  flat closing lap at the top, then feed back to center to disengage *before*
  the final rapid retract. All of 2D.3's tests above were rewritten against
  this corrected waypoint layout.
  
  
### 2E --- buried holes for screws

Explore the idea of introducing a buried hole operation. it can be done with a special bit, but i don't think desktop cnc users have, so instead should be a pocketing operation with a normal bit. the advantage of having this operation is that we don't have to draw it in cad, we just tell it to what depth to go and the diameter. it should start from the middle and go sideways in a heliecal move to the desired depth.

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