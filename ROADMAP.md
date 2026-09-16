# StratumCAM — Implementation Roadmap

- 1.0 Add posibility to ramp before the z0, to allow for the movement to settle in and spindle achieve correct speed. in fusion360 the default value is 2.5mm

## Track 1B.3 — Adaptive (constant-engagement) clearing

This is the direct sequel to Track 1B (`.spiral`, `.trochoidal`): the last
unimplemented case in `SC.PocketClearingPattern`/`SC.ClearingPattern` and
`SC.SlotClearingPattern`. Today `buildPocketToolpath`'s `.adaptive` branch is
a stub (`SCEngine+Pocketing.swift:114-115`, `fatalError("Not implemented
yet")`), and `SC.AdaptiveSettings` only carries `optimalLoad` — `AdaptiveType`
(`.clearing2D` / `.adaptiveContour`) exists as a documented enum but isn't
wired to anything yet.

**Read this before starting Step 1:** FreeCAD's `Adaptive.cpp` leans on
ClipperLib for almost everything — polygon offsetting, boolean ops, and
nesting/topology (island detection) all come from it. StratumCAM has no
equivalent: `OffsetTools`/`SCEngine+Offset.swift` only offset-and-trim a
*single* closed segment chain (used by `pocketRings`), there's no general
polygon union/intersection, and `SC.Contour` has no concept of islands. That
gap is real and shouldn't be quietly designed around — Step 1B.3.6 below
calls it out as a hard dependency for anything beyond a single-boundary
pocket, rather than something to fake inside the adaptive code itself.

The scope for 1B.3.1–1B.3.5 is deliberately the same as `.offset`/`.spiral`/
`.trochoidal` already support today: one closed outer boundary, no islands.
That's not a simplification unique to adaptive — it's the existing ceiling
of the whole pocketing pipeline, so adaptive reaching it first is consistent
with what's already shipped.

- **1B.3.1 — Engagement-angle primitive**
  Add `EngineTools.engagementAngle(toolCenter:toolRadius:cutBoundary:)`. This
  is the one geometric fact the whole algorithm is built on — the direct
  analog of what `Line2CircleIntersect`/`Circle2CircleIntersect` feed into in
  `Adaptive.cpp`: given a candidate tool-center position and the boundary of
  material already cut, how much of the tool's circumference (in radians) is
  currently touching uncut stock. Build it on top of `GeoTools.circleLineIntersections`
  and `GeoTools.circleCircleIntersections`, which already exist and already
  do the same intersection math libarea's versions do. Test in isolation
  first, no engine wiring yet: tool fully in air → 0, tool fully buried → 2π,
  tool half over a straight wall → π. Cheap to get wrong and everything else
  in this track depends on it being right.

- **1B.3.2 — Pocket centroid helper**
  Add a `centroid` computed property to `[SC.Segment]` (same file as the
  existing `boundingBox`/`pathLength` extensions in `SC+Segment.swift`),
  mirroring `Compute2DPolygonCentroid` from `Adaptive.cpp` — sample arcs the
  same way `OffsetTools.isCCWWinding` already does for its own area
  calculation, then run the standard signed-area centroid formula. This is
  the adaptive pass's start point, same role it plays in libarea.

- **1B.3.3 — Adaptive step generator, single boundary, no islands**
  New file `SCEngine+Adaptive.swift`. Implement
  `adaptiveClearingSegments(boundary:tool:optimalLoad:)`: start at 1B.3.2's
  centroid, and grow an outward-spiraling/looping path where each forward
  step is sized using 1B.3.1's `engagementAngle` so engagement never exceeds
  `optimalLoad` — the loop tightens near corners and widens across open
  space, instead of `ringTrochoidalSegments`' fixed-amplitude bounce. Reuse
  that function's `local(u, v)` origin/tangent/normal coordinate trick for
  building loop geometry, since the shape-in-local-frame approach is already
  proven there. Keep this un-thrown (return `[]` on collapse) matching the
  convention `ringTrochoidalSegments` documents for itself — the `throws`
  boundary stays at `buildPocketToolpath`.

- **1B.3.4 — Wire `.adaptive` into `buildPocketToolpath`**
  Replace the `fatalError` at `SCEngine+Pocketing.swift:114-115` with a call
  into 1B.3.3, passing `settings.optimalLoad`. Add `Adaptive_Tests.swift`
  (structure it like `Trochoidal_Tests.swift`): non-empty output for a plain
  rectangle; sampled engagement along the path stays at or below
  `optimalLoad` plus tolerance; no waypoint lands outside the tool-radius
  offset boundary. Add an adaptive case to `DemoPocketing.swift` alongside
  the existing spiral/trochoidal demos.

- **1B.3.5 — Concave corner handling**
  Extend 1B.3.3 so the loop pattern tightens correctly where two
  already-cut walls meet at a concave corner — the part of `Adaptive.cpp`
  that leans hardest on repeated engagement checks against the real cut
  boundary. Validate against the existing notched "staple" fixture already
  shared by `Raster_Tests.swift` and `DemoPocketing.swift`, so this doesn't
  need a new test shape.

- **1B.3.6 — Flag island support as blocked, not skipped**
  Don't implement islands here. Write up (as a comment block in
  `SCEngine+Adaptive.swift` plus a new top-level Track in `ROADMAP.md`,
  something like "Track 7 — polygon offset/boolean engine") what real
  island-aware adaptive clearing needs: multi-contour boundaries, polygon
  boolean subtraction (material minus islands minus already-cut area), and
  nesting-level classification the way `getPathNestingLevel`/
  `appendDirectChildPaths` do in `Adaptive.cpp`. This is a prerequisite for
  more than adaptive — `.offset`/`.raster` would also benefit — so it
  shouldn't be built as an adaptive-only side path.

- **1B.3.7 — `AdaptiveType.adaptiveContour` (profile-peel mode)**
  `AdaptiveType` already documents `.clearing2D` vs `.adaptiveContour`, but
  `AdaptiveSettings` doesn't carry which one is active. Add a `type:
  AdaptiveType` field, default `.clearing2D`, and implement the
  `.adaptiveContour` path in `SCEngine+Profiling.swift`: instead of
  spiraling from a centroid, walk 1B.3.1's engagement check along a single
  offset wall (peeling inward), the way `Adaptive.cpp`'s outside-profile
  mode does. Reuses the same engagement primitive and loop-shape code as
  1B.3.3 — this step is mostly about the walking/boundary logic, not new
  geometry math.

- **1B.3.8 — Wall finishing pass**
  `Adaptive.cpp` always finishes with a clean wall pass (`finishingProfile`).
  Match that: after adaptive clearing, run one more `offsetContour` pass at
  the wall (same call `pocketRings`' first ring already makes) so `.adaptive`
  leaves as clean a boundary as `.offset`/`.spiral` do today. Simplest
  version: always run it, no new setting — add one only if a real case shows
  up wanting it skipped.

- **1B.3.9 — Feed-rate scaling from engagement (opportunistic, Track 4 style)**
  `SC.Waypoint` already carries a per-waypoint `feedRate` — no model change
  needed. Once 1B.3.1's engagement value is available per step, thread it
  through so waypoints with lower measured engagement get a higher feed and
  vice versa, the way `Adaptive.cpp`'s motion-type tags (`mtCutting` vs the
  `mtLink*` variants) exist specifically so a downstream layer can vary feed.
  Don't block 1B.3.4 on this — land it as a follow-up once the base path
  works, same spirit as Track 4's "pick this up opportunistically."