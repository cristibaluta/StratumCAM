# StratumCAM — Implementation Roadmap

Last updated after: pocket ring stepping/chaining (`SCEngine+Pocketing.swift`)

## How to use this doc with Claude

Each step below is sized to be **one self-contained Claude session**: one new file
(or one focused edit to an existing one) + its test, compiling and green before
moving on. Don't ask for a whole "Track" in one message — ask for one step, review,
commit, then move to the next. That's what keeps sessions from blowing up mid-feature.

Suggested prompt shape per step:
> "Implement Step X.Y from the roadmap. Follow the existing code style in SCEngine+Profile.swift. Add a test file in the style of Engraving_Tests.swift."

---

## Track 1 — Pocketing (`.pocket`) — Phase 3

Boundary offsetting and the concentric ring stack are done (`pocketRings` /
`chainedRingSegments`, covered by `Pocket_Tests.swift`). Remaining: the raster
pattern, entry integration, Z stepdown, and rounding out test coverage.

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

- **1.3 — Multi-pass Z stepdown for pockets**
  Same `calculateZPasses` reuse as profile — confirm pocket geometry (rings or
  scanlines) is only computed once and Z-passes reuse it (don't regenerate per Z
  pass, that's wasted work and a source of divergent bugs between passes).
  `buildPocketToolpath` is currently single-pass at `settings.targetDepth`.

- **1.4 — Tests**
  Extend `Pocket_Tests.swift`: raster coverage on a rectangle, stepover honored
  within tolerance for raster, entry-strategy waypoints present for both pattern
  types, multi-pass Z depths correct.

> Note: islands (pockets with interior obstacles to avoid) aren't in the current
> `Contour` model at all — it's a flat entity list with no "this is an island inside
> that boundary" relationship. That's a model change, bigger than pocketing itself.
> Worth a separate conversation before finishing this track if islands matter to
> you — flagging again so it doesn't get silently assumed away.

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