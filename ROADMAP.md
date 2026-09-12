# StratumCAM — Implementation Roadmap

Last updated after: Track 1 (Pocketing) test coverage complete + raster
concave-row bug fix (`SCEngine+Pocketing.swift`, `Raster_Tests.swift`)

## How to use this doc with Claude

Each step below is sized to be **one self-contained Claude session**: one new file
(or one focused edit to an existing one) + its test, compiling and green before
moving on. Don't ask for a whole "Track" in one message — ask for one step, review,
commit, then move to the next. That's what keeps sessions from blowing up mid-feature.

Suggested prompt shape per step:
> "Implement Step X.Y from the roadmap. Follow the existing code style in SCEngine+Profile.swift. Add a test file in the style of Engraving_Tests.swift."

---

## Track 1 — Pocketing (`.pocket`) — Phase 3

Track 1 is complete. Boundary offsetting and the concentric ring stack
(`pocketRings` / `chainedRingSegments`), the raster pattern, entry integration
(plunge/ramp/helix for both pattern types), Z stepdown, and test coverage are
all done -- see 1.1-1.4 below. Next up is Track 1B (new `ClearingPattern`
cases) or Track 2 (new `MachiningOperation` cases), whichever you'd rather
pick up.

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

- **1B.1 — `spiral` pocket: continuous inward/outward spiral**
  Closest relative of the two done patterns: like `offsetPattern`'s ring stack,
  but instead of chaining discrete closed rings with connecting transitions
  (`chainedRingSegments`), interpolate each ring's radius/offset continuously
  from one ring to the next so the path never closes on itself until the final
  pass. `pocketRings` already gives the discrete ring stack (Step 1.1's
  boundary-offset machinery) — reuse its ring geometry as the interpolation
  control points rather than recomputing offsets. Only well-defined for
  boundaries close to circular/elliptical/near-symmetrical, per the enum's own
  doc comment — for anything else, fall back to `.offsetPattern`'s ring-and-chain
  behavior (flag this fallback rule rather than silently producing a bad spiral
  on odd shapes).

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
  is a much bigger