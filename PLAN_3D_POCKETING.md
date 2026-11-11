# Plan: 3D pocketing (`.pocket3D`) for StratumCAM

## 1. Goal

Add an operation that clears a pocket **in layers from the top**. Islands inside the pocket have their own **top height**.

- Layers above an island's top cut straight over it, as if it weren't there.
- The layer that ends exactly on the island's top leaves a flat top face.
- Every layer deeper than that goes **around** the island and leaves it standing.
- This continues until the pocket floor.

This is 2.5D: every island is a vertical-walled column from the floor up to its top. The result is a height map made of flat levels. Sloped or free-form surfaces (waterline / 3D rest machining) are out of scope.

## 2. What the existing code gives us

| Piece | Where | Relevance |
|---|---|---|
| Island-aware 2D pocketing | `SCEngine+Pocketing.swift`, `+PocketIslands.swift`, `+PocketAdaptive.swift` | Already clears a pocket around islands for `.concentric` and `.adaptive`. Islands are a flat, constant-height keep-out for **all** Z layers. |
| Island auto-detection | `resolvePocketIslands` (`+PocketIslandDetection.swift`) | Even-odd nesting turns a flat list of closed shapes into pocket + `islands`. The shape is copied as a whole, so a new field on `SC.Contour` survives. |
| Island merging | `closingOpenContours`, `mergingTouchingIslands` (`+PocketBoundary.swift`) | Islands touching the wall are **subtracted from the wall**, so they stop being islands. This is wrong for a low island, which must still be cut over. Needs care (§4.4). |
| Z layers | `EngineTools.calculateZPasses(targetDepth:stepdown:)` | One regular grid from 0 to the target. It knows nothing about island tops. |
| Pocket builder | `buildPocketToolpath` | One function plans the XY geometry once, then loops over `zDepths` emitting waypoints. Planning and emission are tangled together. |
| Output | `SC.OutputToolpath` / `ToolpathPass(depthZ, waypoints)` | Generic. All three G-code engines iterate `passes` without caring how they were built. **No post-processor changes needed.** |
| Demo | `DemoPocketing.swift`, `Demo.run`, `ContentView.swift` | One function and one button per demo. `Demo.run` draws input outlines at Z=0. |

The key point is that the planned XY geometry (rings, groups, helices) is already computed once and reused for every Z layer. With islands of different heights, the XY geometry only changes at a few Z levels (the island tops). So the design is:

> Split the Z range into **bands** that share the same set of "active" islands. Plan the 2D pocket once per band, using the existing machinery. Emit that band's layers.

## 3. Design

### 3.1 Public API

1. `SC.Contour` gets a new optional field:
   ```swift
   /// Islands of a .pocket3D: Z of the island's top face, in the same coordinates as the
   /// pass depths. Z0 = top of the stock, going down is negative (-3 = 3 mm below the stock
   /// top). A positive value is a boss standing above the stock top.
   /// nil = stands up through every layer (same as a boss).
   public var topZ: Double?
   ```
   - The value is used **as given, with no `abs()`**: the sign carries meaning (negative = below the stock top, positive = boss).
   - `MachineSettings.targetDepth` stays a positive depth as everywhere else. Only island heights are signed. Document this next to the field.
   - It is added to `init` with a default of `nil`, so existing callers don't break.
   - It works for contours passed in a flat list and for `contour.islands` set by hand.
2. A new case `SC.MachiningOperation.pocket3D(direction:pattern:entry:)`.
   - It has the same parameters as `.pocket`, so the UI and docs can be reused.
   - Add `Kind.pocket3D`.
   - Update every exhaustive `switch`: `kind`, `direction`, `entry` (get and set), `requirements`, `validate`, and `buildPlainToolpath`.
3. Requirements for `.pocket3D`:
   - It is the same as `.pocket`: same `pocketPatterns` (all six, `SC.PocketClearingPattern.defaults`), same `entries`, same direction, stepdown and stepover rules. The only difference is `usesAllowance`, which is off in phase 1 (see §6) and on from phase 2.
   - **Island support is the same as `.pocket` today**, and is checked **up front**, before any layer is built: if at least one island stands in the cut range (its top is above the floor), then
     - `.concentric` accepts plunge and ramp entries and rejects helix,
     - `.adaptive` accepts every entry,
     - `.offset`, `.raster`, `.spiral` and `.trochoidal` throw `invalidParameter("islands are only supported by the .concentric and .adaptive patterns")`.
   - With no island standing (none drawn, or all of them below the floor) every pattern works and the result is the same as `.pocket`.
   - Checking up front avoids a toolpath that is fine in the island-free bands and fails halfway in the others.

**Alternative considered:** a flag on `.pocket`. It's less code but hides a different algorithm behind a boolean, and `INFO.md` already organises operations by WHAT is being machined. A separate case is the consistent choice.

### 3.2 Z levels and bands

Input: `targetDepth` (floor), `stepdown`, and each island's `topZ` (Z0 = stock top, negative downwards; nil is a boss).

1. **Classify islands** (no sign change, `topZ` is used as given).
   - `topZ >= 0` or nil: a **boss**. It stands above the first layer, so it is active in **every** layer and is always avoided. It is never clamped and never an error. This also holds if the first layer ever starts below Z0: any island whose top is above the first layer's top is active in every layer.
   - `topZ <= floorZ` (at or below the floor): never stands, so drop it and emit a warning.
   - Anything in between is a **stepped island** and creates a breakpoint.
2. **Breakpoints.** Collect `[0] + sorted unique island tops (strictly between 0 and floor, tolerance ~1e-6) + [floorZ]`.
3. **Layers per segment.** For each consecutive pair of breakpoints, call `calculateZPasses` on that segment's thickness and offset the result.
   - Layers never exceed `stepdown`.
   - The cut lands exactly on every island top, so each island gets an exact flat top.
   - Layers between breakpoints are evenly split by the existing function, so there are no sliver layers except where an island top is itself very close to another breakpoint.
4. **Active set for a layer that ends at `z`:** islands with `topZ > z + eps`. An island whose top is flush with `z` is already inactive, because that layer is the one that creates its top.
5. **Bands:** consecutive layers with the same active set.

Worked example for the demo (floor -8, stepdown 1, island A top -3, island B top -6):

| Layers (floor Z) | Active islands |
|---|---|
| -1, -2, -3 | none |
| -4, -5, -6 | A |
| -7, -8 | A, B |

### 3.3 Refactor: split planning from emission

This is the one real refactor. `buildPocketToolpath` is ~300 lines that validate, plan XY geometry per pattern, then loop over Z. Split it into:

```swift
struct PocketPlan {                 // everything that depends on XY only
    var baseSegments: [SC.Segment]  // the wall as given; `restCorners` reads it
    var toolpathSegments: [SC.Segment]
    var boundarySegments: [SC.Segment]
    var islandGroups: [[SC.Segment]]?
    var groupHelices: [(center: CGPoint, radius: Double, startAngle: Double, isCCW: Bool)?]
    var toolCenterRegion: [SC.Segment]
    var helixIsCCW: Bool
}

func planPocket(for contour:, tool:, settings:, direction:, pattern:, entry:) throws -> PocketPlan
func pocketPassWaypoints(plan:, toolRadius:, atZ:, previousZ:, settings:, entry:) -> [SC.Waypoint]   // the body of today's loop
func applyPocketRetractPolicy(to passes:, plan:, pattern:, tool:, settings:)                        // the tail of today's function
```

- `buildPocketToolpath` becomes `planPocket` followed by the existing loop, so `.pocket` behaviour is unchanged.
- This is a pure move of code. It must be verified (§7) before any 3D logic is added.
- A `.pocket3D` builder is then roughly: per band, `planPocket` with the active islands, then `pocketPassWaypoints` for each layer.
- `previousZ` is threaded across bands, so a ramp or helix entry in the first layer of a new band starts from the previous layer's floor. That area is already cleared, because the previous layer was cut without the newly standing island in the way.
- **Validation** (entry angle, pattern vs islands, closed contour) stays in a shared helper.

### 3.4 Island pre-processing per band

Today `generateToolpaths` runs `closingOpenContours`, `resolvePocketIslands` and `mergingTouchingIslands` once, up front, for `.pocket`. For `.pocket3D`:

1. Run `closingOpenContours` and `resolvePocketIslands` up front, as now.
   - Carry `topZ` through every place that builds a new `SC.Contour` from segments. For example `contour(from:)` in `closingOpenContours` loses it, so copy it from the source.
2. **Do not run `mergingTouchingIslands` globally.** Run it per band, on a copy of the pocket whose `islands` are only that band's active islands.
   - An island touching the wall is subtracted from the wall only in the bands where it stands. In the layers above its top it is cut over like any other material.
3. Overlapping islands of different heights need no special handling. The union of columns has height = max of the tops.
   - In bands where only the taller one stands, the shorter one's overlap is already protected by the taller outline, and its non-overlapping part is correctly cleared.
   - In bands where both stand, the existing island merge/zone logic handles the union.

### 3.5 Retract policy and entry height

- `applyEntryHeight` runs on the whole `OutputToolpath`, as now. No change.
- `RetractPolicy`:
  - Bands with no active islands can keep the shortcut (`.clearance` / `.none`) inside the band, via `applyRetractPolicy`.
  - Bands with islands keep the full retract to `safeZ`, same as `.pocket` today.
  - Transitions between bands retract to `safeZ`.
- Possible later optimisation: hover just above the tallest active island's top instead of `safeZ`.

### 3.6 Output

One `OutputToolpath` for the pocket, with all layers in one `passes` array in top-to-bottom order.

- `passIndex` runs 0..n-1 across all bands.
- `depthZ` is the layer floor.
- No G-code engine changes.

### 3.7 Multiple tools

**Yes, it can be done, and the structure already allows it.**

How the library works today:
- One `generateToolpaths` call is one operation with **one tool**. The result, `SC.OutputToolpath`, carries its own `tool` and `settings`.
- The G-code engines emit a tool change whenever the tool of the next toolpath differs from the previous one (`T<n>M6` in the Makera engine).
- Rest machining already works this way: `generateRestToolpaths` returns **separate** `OutputToolpath`s with a smaller tool.

So multi-tool is simply **several `OutputToolpath`s in the right order**. No G-code change is needed.

What 3D pocketing adds:
- The XY plan depends on the **band and the tool radius** (the keep-out zone around an island is its outline offset by the tool radius). `planPocket` (§3.3) already takes the tool as a parameter, and nothing in §3.2–3.4 assumes one tool. Running it again with another tool is just another call.

The jobs a second tool can do, from simplest to hardest:

| Job | Tool | Phase | How |
|---|---|---|---|
| **Rough + finish with one tool** | same tool | 2a | `allowance` + `finishingPass`, exactly as `.pocket` does it (wider stand-in tool for the roughing, then a finishing pass appended to the same `OutputToolpath`). |
| **Rough with a big tool, finish with a smaller one** | two tools | 2b | The roughing leaves `allowance` mm everywhere (walls, floor, island tops). A separate function, `generatePocket3DFinishing(from:tool:settings:)`, mirrors `generateRestToolpaths`: wall passes per band and one flat pass per horizontal face, with the **finishing tool's** radius. It needs the same contours and the allowance, not the roughing tool. |
| **Rest roughing**: a smaller tool clears what the big one could not reach (corners, gaps between islands narrower than the big tool) | two tools | 3 | Needs a per-band "what is left" region (the band's pocket minus what the big tool swept). Today `restCorners` only knows the outer wall's corners, and `islandZones` throws when the big tool does not fit between islands. With a rest pass that throw could become "skip for the big tool, leave it for the small one". Not planned before the single-tool version is solid. |

Rules:
- **Order of the output:** all layers of tool A, then all layers of tool B. Never alternate tools band by band; that would be a tool change per band.
- Each toolpath has its own `settings`, so each tool has its own feed, stepdown and stepover. The stepover is a fraction of that tool's diameter, as everywhere else.
- Tool types: flat end mills only, as for `.pocket`. A ball end mill is a later topic, because it only matters for sloped surfaces, which are out of scope (§1).
- The flute-length warning (§4.7) is checked **per tool**.
- A tool change **inside** one pocket by depth (a long tool for the deep bands, a short one for the shallow bands) is not supported.

## 4. Edge cases and rules

1. **Island with nil `topZ`.** A boss: it stands through every layer. With every island nil, `.pocket3D` must produce exactly the same passes as `.pocket` (a regression property, see §7).
2. **Island top above the stock top (`topZ > 0`).** A boss, handled like nil: active in every layer and avoided everywhere. No clamping, no error. The layer grid is not affected, because a boss creates no breakpoint.
3. **Island top at or below the floor.** The island never stands. Ignore it and add a `Warning` case.
4. **Island top very close to a breakpoint** (e.g. 0.01 mm below the stock top). This creates a very thin layer. It is correct, just wasteful. Option: `minLayerThickness` that merges thin layers upward, which leaves a little extra material and never gouges.
5. **Nesting depth >= 2** (an island inside an island). The 2D engine treats it as a new pocket. The height semantics for that case are unclear, so reject it for `.pocket3D` with `invalidParameter("nested islands are not supported")`.
6. **Tool can't fit between islands or between an island and the wall.** `islandZones` already throws. This is evaluated only for islands active in a band, so a pair that never stands together is fine.
7. **Flute length.** Warn if `abs(floorZ) > tool.fluteLength`. This is not enforced elsewhere in the engine today.
8. **Tool or holder collision with a standing island above the cut** is not modelled (flat end mill assumed).
9. **Concave or open islands closed against the wall** use the existing `closingOpenContours`, then take `topZ` from the open contour.

## 5. Files to touch

**Library (`Sources/StratumCAM`)**

| File | Change |
|---|---|
| `models/SC+Contour.swift` | Add `topZ`. |
| `models/SC+MachiningOperation.swift` | Add `.pocket3D` and `Kind.pocket3D`; update `kind`. |
| `models/SC+OperationRequirements.swift` | `requirements`, `validate`, `direction` and `entry` accessors for `.pocket3D`. |
| `models/SC+OutputToolpath.swift` | New `Warning` cases (island ignored, island below floor). |
| `toolpaths-engine/SCEngine.swift` | Dispatch `.pocket3D`; pre-processing without the global merge (§3.4). |
| `toolpaths-engine/SCEngine+Pocketing.swift` | Refactor into `planPocket` + `pocketPassWaypoints` (§3.3). |
| `toolpaths-engine/SCEngine+Pocket3D.swift` (**new**) | Breakpoints, bands, active sets, per-band merge, band loop. |
| `toolpaths-engine/SCEngine+PocketBoundary.swift`, `+PocketIslandDetection.swift` | Carry `topZ` through any contour rebuilt from segments. |
| `utils/EngineTools.swift` | Optional: `calculateLayeredZPasses(floor:stepdown:breakpoints:)` (pure, easy to test). |

**Demo (`Sources/StratumCAMDemo`)**

| File | Change |
|---|---|
| `demos/DemoPocketing.swift` | New demo functions (§7). |
| `ContentView.swift` | New button(s) in the "Pocketing" section. |
| `demos/Demo.swift` | Draw each outline at its own `topZ` (see §7). |

## 6. Phases

**Phase 0 — Refactor (no behaviour change) — DONE in code, not yet built**
Split `buildPocketToolpath` into plan and emit (`PocketPlan`, `planPocket`, `pocketPassWaypoints`, `applyPocketRetractPolicy`, all in `SCEngine+Pocketing.swift`). The code was written without a Swift toolchain, so it has not been compiled. Still to do on a Mac: build, then check that every existing pocket demo gives an identical toolpath before and after (§7, test 5).

**Phase 1 — Roughing, allowance = 0**
`topZ`, `.pocket3D`, breakpoints and bands, per-band island merge, the band loop, validation, warnings, demo. Throw `invalidParameter("allowance")` if `allowance > 0` or `finishingPass` is on, rather than doing it wrong silently.

**Phase 2 — Stock to leave and finishing**
- Rough with the existing "wider stand-in tool" trick for walls.
- Rough island tops at `topZ + allowance` so each island keeps stock on its top.
- Finishing pass:
  - Wall passes per band, with the real tool.
  - One flat pass per horizontal face (the pocket floor and every island top).
- Open question: how far the tool may overhang an island's top edge. It is air only once the surrounding layers are fully cleared.

**Phase 2a / 2b — Finishing with the same tool, then with another tool**
2a is the list above (same tool). 2b adds `generatePocket3DFinishing` so the finishing can use a different, usually smaller, tool (§3.7). Both are built on the same finishing code; 2b only moves it behind its own entry point.

**Phase 3 — Quality of life**
Smarter retracts between groups, `minLayerThickness`, layer ordering to reduce rapids, rest roughing with a second tool (§3.7).

## 7. Tests and demo

**Demo: rectangle with two circular islands of different heights**

- Pocket: 60 × 36 rectangle.
- Island A: circle r = 7 at (18, 18), top at Z = -3.
- Island B: circle r = 6 at (42, 18), top at Z = -6.
- Floor: Z = -8.
- Tool: Ø6 flat, 40 % stepover, stepdown 1.
- Pattern: `.concentric(.insideOut)`, climb, plunge entry. This matches the existing island demos.
- Pass shape follows the table in §3.2: layers -1..-3 are one plain rectangle, -4..-6 avoid A, -7..-8 avoid A and B.
- Pass the three shapes as one flat list, as `demoPocketRectangleConcentricAutoIslands` does.

**Visualising it.** `Demo.run` currently draws every outline at Z=0. Draw any contour with a `topZ` at that Z instead:
- A one-line change: `buildWaypoints(for:, atZ: contour.topZ ?? 0, ...)`.
- Optionally add a few vertical struts from each island top down to the floor, using the existing line batch.
- This makes the island heights visible in the 3D preview.

**Extra demos (cheap once the first works)**
- Same pocket with `.adaptive` and helix entry.
- "Wedding cake": a taller square partly overlapping a shorter disc, to exercise the union-of-columns behaviour.
- Island touching the wall at a lower height (the per-band merge case).

**Unit tests** (the archive has no test target; the demos reference a `Pocket_Tests.swift`, so these should go there)
1. Breakpoint and layer calculation: a table of (floor, stepdown, island tops) → layer Z list. Cover an even split, an island top already on the grid, and an island top 0.05 from another breakpoint.
2. Active-set rule: an island is inactive in the layer that ends exactly on its top and active in the next.
3. Band count equals the number of distinct island tops + 1 (capped by layer count).
4. **Regression:** `.pocket3D` with all `topZ == nil` gives the same passes as `.pocket` on the same input, for `.concentric` and `.adaptive`.
5. **Refactor check:** existing `.pocket` demos give identical waypoints before and after Phase 0.
6. **No gouging invariant:**
   - For every pass at `depthZ` below an island's top, no `linear` or arc waypoint of the cut lies inside that island's keep-out zone (island outline offset by the tool radius).
   - For passes at or above the top, cutting across the island is allowed and expected.
7. **Exact top:** a pass exists with `depthZ == topZ` for every island whose top is inside the cut range.
8. Validation: nested island, island too close to the wall, and island below floor each give the expected error or warning.
9. **Boss:** an island with `topZ > 0` (and one with nil) is avoided in every layer, adds no breakpoint, and gives the same passes as `topZ = 0`.
10. **Patterns:** `.offset`, `.raster`, `.spiral` and `.trochoidal` throw when an island stands in the cut range and work when none does (none drawn, or all below the floor). `.concentric` with helix throws only when an island stands.
11. **Two tools (phase 2b):** rough with Ø6 then finish with Ø3. The result is two `OutputToolpath`s, roughing first, each carrying its own tool, and the Makera G-code has exactly one tool change between them.

## 8. Decisions

**Decided**

| # | Question | Decision |
|---|---|---|
| 2 | Sign convention for `topZ` | Z0 is the top of the stock, values go negative downwards. Used as given, no `abs()`. A positive value is a boss above the stock. |
| 3 | Island top above the stock top | It is a boss that is avoided in every layer, because the cut may start from a different Z. No clamp, no error (§3.2, §4.2). |
| 5 | Patterns | The same as the existing pocket: all six are offered. Islands work only with `.concentric` and `.adaptive`, exactly as `.pocket` today, checked up front (§3.1). |

**Taken by default (say so if you disagree)**

| # | Question | Default |
|---|---|---|
| 1 | Where the height lives | The `topZ` field on `SC.Contour`. It works for a flat list and for hand-set `islands`, and in the UI it is a property of the island shape (§9). |
| 4 | What to build first | Phase 1 (roughing only, allowance = 0), then phase 2. What this question meant: it is not about the cutting direction, which is always top to bottom. It is about **stock to leave**. Roughing can stop e.g. 0.2 mm short of every wall, of the floor and of each island's top, and a final finishing pass then cuts that thin skin to the true size. `.pocket` already offers this (`allowance` and `finishingPass`). Phase 1 does not do it, so the roughing cuts to full size in one go. Building it in two steps keeps the first delivery small and testable. |

**Still open**

1. **Finishing tool (phase 2b):** is "rough with a big tool, finish with a smaller one" what you need, or is rough + finish with one tool enough at first?
2. **Start Z:** `MachineSettings` has no start Z today, so the layers always start at Z0. Do you want an explicit start Z on the operation (cut from Z = -2 down, say), or is "a boss is avoided in every layer" all you meant?

## 9. UI

The app UI is in Stratum-CNC, not in this archive. The library describes itself through `SC.OperationRequirements`, so the app only draws the controls the operation lists. The proposal below follows that.

**1. Operation list.** "3D Pocket" appears next to "Pocket". Each operation has its own tool, so two 3D pocket operations on the same shapes with two tools are possible (see 5).

**2. Operation panel.** The same controls as Pocket, drawn from `requirements`:

```
3D Pocket
  Tool            Ø6 flat end mill   ▾
  Depth (floor)   8.0
  Stepdown        1.0
  Direction       Climb ▾
  Pattern         Concentric (inside out) ▾     <- same six patterns as Pocket
  Entry           Plunge ▾
  Stepover        40 %                          <- optimal load for Adaptive
  Stock to leave  0.2     [x] Finishing pass    <- hidden in phase 1
```

If an island is present and the pattern can't handle islands, the panel shows the library's error under the Pattern field instead of silently changing it (or greys out those patterns).

**3. Island height: one field on the shape.** Islands need no new drawing step. A closed shape inside another is already detected as an island. When such a shape is selected and the operation is a 3D Pocket, the shape inspector shows:

```
Island
  Top Z    -3.0     (Z0 = stock top)
```

- Empty or "Stock top" = nil: stands through every layer.
- A positive number is allowed and shown with the hint "boss above stock".
- The field is not shown for shapes that aren't islands, or when the operation is a plain Pocket.
- The 2D drawing labels each island with its Top Z, so the heights can be read without selecting anything.

**4. Layer summary (read-only, under the panel).** It comes from the same pure function that computes the breakpoints (§3.2), so it is cheap to show live:

```
8 layers, 3 bands
  Z  -1 … -3    whole pocket
  Z  -4 … -6    around island A
  Z  -7 … -8    around islands A, B
⚠ Island C is below the floor and is ignored
```

**5. Two tools.** Two operations in the list, in this order:

```
1. 3D Pocket  – roughing    Ø6 flat   stock to leave 0.2
2. 3D Pocket  – finishing   Ø3 flat   (phase 2b)
```

The preview shows both in order, and the G-code has one tool change between them. The roughing is always the first in the list; the app should not reorder them band by band.

**6. 3D preview.** Outlines are drawn at their own `topZ` (§7), so the island heights are visible, and the pass scrubber goes through all layers top to bottom.
