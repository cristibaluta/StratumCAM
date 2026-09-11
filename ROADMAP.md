# StratumCAM — Implementation Roadmap

Last updated after: chamfering (`SCEngine+Chamfering.swift`)

## How to use this doc with Claude

Each step below is sized to be **one self-contained Claude session**: one new file
(or one focused edit to an existing one) + its test, compiling and green before
moving on. Don't ask for a whole "Track" in one message — ask for one step, review,
commit, then move to the next. That's what keeps sessions from blowing up mid-feature.

Suggested prompt shape per step:
> "Implement Step X.Y from the roadmap: <paste the step>. Follow the existing code
> style in SCEngine+Profile.swift. Add a test file mirroring Engraving_Tests.swift."

---

## Track 0 — Small fixes / debt before new features

These are quick, isolated, and reduce risk before building on top of profile/chamfer.

- DONE **0.1 — Wire up `ChamferParams.direction`**
  Orient the chamfer's base segments with the existing `orientedForDirection` helper
  (already public-ish inside `SCEngine+Profile.swift`) before offsetting, same as profile
  does. ~10 line change + 1 test.

- DONE **0.2 — Test coverage: `.profile`**
  New `Profile_Tests.swift`. Cover: outside/inside offset direction, climb vs conventional
  reversal, plunge/ramp/helix entry each produce sane waypoints, one holding-tab case.
  This is the highest-value test gap right now — profile is your biggest chunk of logic
  and has zero direct tests.

- DONE **0.3 — Test coverage: `.chamfer`**
  New `Chamfer_Tests.swift`. Cover: depth resolved from width+vAngle, explicit depth
  override, non-V-bit tool returns `nil`, inside vs outside offset sign.

- DONE **0.4 — `calculateZPasses` float-safety cleanup** (optional, low priority)
  Replace the epsilon-margin loop with a count-based `(0..<n).map` so pass count is exact
  regardless of float drift. Small, isolated, has an existing TODO pointing right at it.

---

## Track 1 — Drilling (`.drilling`) — Phase 2 in the code's own TODOs

Drilling is the smallest remaining strategy — good next feature after the Track 0 cleanup.

- DONE **1.1 — Point-contour recognition**
  Drilling needs a hole *center*, not a chain of segments. Add a helper that extracts a
  drill point from a contour: support `DXF.Entity.point` directly, and — since circles are
  common "drill here" markers in DXF — optionally treat a single closed `.circle` contour's
  center as a drill point too. Keep it to extraction only, no toolpath yet.

- DONE **1.2 — Basic drill cycle (no pecking)**
  `buildDrillingToolpath`: rapid to XY at safeZ, plunge straight to `targetDepth` at
  `plungeRate`, retract to safeZ. One `ToolpathPass`. Wire into `SCEngine.buildToolpath`
  switch, replacing the `nil` stub for the non-peck case.

- **1.3 — Peck drilling**
  When `peckDepth != nil`: repeated plunge-retract-plunge cycles to `retractZ` between pecks
  (using `settings.retractZ`, which already exists but is currently unused anywhere). Each
  peck deeper than the last until `targetDepth`. This is genuinely its own step — pecking
  has its own edge cases (last peck depth, dwell) worth isolating from the plain-plunge case.

- **1.4 — Multiple drill points / contours in one call**
  Confirm `generateToolpaths` already handles a list of point-contours correctly (it should,
  since it's one-toolpath-per-contour already) — add a test with 3+ holes and mixed
  peck/non-peck tools to lock in the behavior.

- **1.5 — G-code: dwell + tool-specific spindle speed for drilling**
  Add optional dwell (`G04`) after final peck, useful for spot-facing. This is the first
  place `SCGCodeEngine`'s single global spindle speed starts to feel wrong — flag it, but
  don't fix the multi-tool problem here (that's Track 3).

---

## Track 2 — Pocketing (`.pocket`) — Phase 3

Biggest remaining feature. Split by pocket pattern since they're genuinely independent
algorithms — don't try to do both in one pass.

- **2.1 — Pocket boundary offsetting (single ring)**
  Given a closed contour, generate the first inward offset ring at `toolRadius` using the
  *existing* `offsetContour`/`offsetDistance` machinery (it already handles closed-contour
  offsetting for profile/chamfer — pocketing reuses it, doesn't reinvent it). No stepover
  loop yet, just prove one ring offsets correctly inward for a simple rectangle and a
  rectangle-with-corner-radius.

- **2.2 — `offsetPattern` pocket: concentric ring stepping**
  Repeatedly offset inward by `stepoverPercentage * tool.diameter` until rings collapse
  (reuse the "segment collapsed" signal already in `offsetContour`). Chain rings
  outside-in or inside-out (pick one, document why) into one continuous pass per Z depth.
  This is the meat of the feature — expect this to be its own multi-step sub-track if the
  first attempt is too big:
  - 2.2a: generate the ring list (geometry only, no waypoints)
  - 2.2b: connect rings into waypoints with safe transitions (no plunge into un-cut stock)

- **2.3 — `raster` pocket: parallel scanline clearing**
  Independent algorithm from 2.2 — bounding-box scanlines clipped against the contour,
  alternating direction (boustrophedon) or same-direction with rapid retracts, per
  `direction` (climb/conventional) via stepover sign. Also its own multi-step item if large:
  - 2.3a: scanline generation + clipping against a single closed contour (no islands)
  - 2.3b: entry strategy integration (helix/ramp reused from `.profile`'s entry code)

- **2.4 — Pocket entry integration**
  Wire `EntryStrategy` (already fully built for profile: plunge/ramp/helix) into pocket's
  first plunge point for both pattern types. Should be a thin reuse of
  `helixEntryWaypoints`/`rampWaypoints` from `SCEngine+Profile.swift`, not a rewrite.

- **2.5 — Multi-pass Z stepdown for pockets**
  Same `calculateZPasses` reuse as profile — confirm pocket geometry is only computed once
  and Z-passes reuse it (don't regenerate the ring/raster geometry per Z pass, that's
  wasted work and a source of divergent bugs between passes).

- **2.6 — Tests**
  `Pocket_Tests.swift`: ring collapse on a small rectangle, raster coverage on a rectangle,
  stepover honored within tolerance.

> Note: islands (pockets with interior obstacles to avoid) aren't in the current `Contour`
> model at all — it's a flat entity list with no "this is an island inside that boundary"
> relationship. That's a model change, bigger than pocketing itself. Worth a separate
> conversation before Track 2 if islands matter to you — flagging now so it doesn't get
> silently assumed away.

---

## Track 3 — Adaptive clearing (`.adaptiveClearing`) — Phase 4

Do this last — it's the most algorithmically involved, and steps 3.x below assume Track 2's
ring-offset and raster machinery already exist to build on.

- **3.1 — Trochoidal/constant-engagement core algorithm (2D clearing only)**
  Start with `.clearing2D` only, ignore `.adaptiveContour` for now. Reuse Track 2's
  concentric offset rings as the "safe corridor," then generate a path that maintains
  `optimalLoad` engagement rather than pocketing's simple concentric fill. This is a
  genuinely hard geometry problem — expect several sub-steps once you're in it.

- **3.2 — Helical/ramped entry for adaptive** (thin reuse of existing entry code, same as 2.4)

- **3.3 — `.adaptiveContour` variant**

- **3.4 — Tests**

---

## Track 4 — Cross-cutting, do opportunistically alongside the tracks above

Not urgent, don't block feature work on these, but pick them up when convenient:

- **4.1 — G-code: per-tool spindle speed / tool change (`M6 T#`, `M3 S#` per tool)**
  Becomes necessary once a job mixes drilling + profile + chamfer tools. Currently
  `SCGCodeEngine` takes one global `MachineSettings` — needs to read `toolpath.tool` and
  `toolpath.settings` per toolpath (both already stored on `OutputToolpath`, just unused).

- **4.2 — Stock model integration**
  `SC.Stock` exists but nothing checks against it. At minimum: warn/clip when a toolpath
  goes outside stock bounds. Real stock-aware simulation (remaining material tracking) is a
  much bigger feature — start with bounds-checking only.

- **4.3 — Offset engine: self-intersection cleanup**
  Existing documented limitation in `SCEngine+Offset.swift` — when tool radius is bigger
  than a feature can support, it currently just returns the broken raw offset. Worth
  fixing once pocketing (Track 2) starts exercising this path harder, since pocketing hits
  tight inside corners far more often than profile cuts do.

- **4.4 — CI**
  No `.github/workflows` yet. A basic `swift test` on push would catch regressions across
  all these tracks for free.

---

## Suggested order

1. Track 0 (all of it — cheap, de-risks everything after)
2. Track 1 (drilling — smallest, builds confidence in the "small steps" workflow)
3. Track 2 (pocketing — biggest, lean hard on the sub-steps)
4. Track 4.1 once Track 1 or 2 needs multi-tool G-code
5. Track 3 (adaptive clearing — hardest, benefits from Track 2's geometry already existing)
6. Track 4 remainder, opportunistically
