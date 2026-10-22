![Stratum CAM](https://myimgs.org/storage/images/37816/stratum.png)

Swift library that generates CNC toolpaths and G-code for CAM software. It is used by https://github.com/cristibaluta/Stratum-CNC

- Pure Swift, no third-party dependencies. Input geometry is the library-native `SC.Geometry`.
- All models live under the `SC` namespace.
- Two stages: **toolpaths** (`SCEngine`) and **G-code** (`SCGCodeEngine`, `SCMakeraGCodeEngine`, `SCPostEngine`).

Requires Swift 5.9+, macOS 13+ / iOS 15+.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/cristibaluta/StratumCAM", branch: "main")
// target dependency:
.product(name: "StratumCAM", package: "StratumCAM")
```

The package also contains `StratumCAMDemo`, a macOS Metal app that previews every operation (`swift run StratumCAMDemo`), and a Swift Testing suite (`swift test`).

## Pipeline

```
[SC.Geometry] ──EntityChainer──▶ [SC.Contour]
                                    │  + SC.ToolParams + SC.MachineSettings + SC.MachiningOperation
                                    ▼
                          SCEngine.generateToolpaths
                                    │
                                    ▼
                          [SC.OutputToolpath]  ──▶  preview (waypoints)
                                    │
                                    ▼
                  SCGCodeEngine / SCMakeraGCodeEngine / SCPostEngine
                                    │
                                    ▼
                                 G-code
```

## Toolpaths

### Input

| Type | Purpose |
|---|---|
| `[SC.Contour]` | Chain of `SC.Geometry` primitives. Each continuous selectable path is one contour. |
| `SC.ToolParams` | The cutter: type, diameter, V-angle, flute length, plus tool number/comment for the post. |
| `SC.MachineSettings` | Cutting data (`SC.CuttingData`), `safeZ`, `retractZ`, `targetDepth`, `retractPolicy`. |
| `SC.MachiningOperation` | What to machine (see below). |

**Geometry.** `SC.Geometry` cases: `.line`, `.circle`, `.arc` (degrees, CCW from start to end), `.ellipse`, `.point`, `.polyline(vertices:closed:)` (vertices carry a DXF-style `bulge`). Everything is converted internally to lines and arcs, which is all a CNC understands.

If you have loose primitives rather than ready-made contours, chain them:

```swift
let contours = EntityChainer.chain(geometries, tolerance: 1e-3)
```

Circles, points and ellipses stay standalone contours. Closed contours nested inside other closed contours are detected as **islands** automatically for pockets.

**Depth convention.** Z = 0 is the top of the stock; `targetDepth` may be given negative (`-1.0`) or positive, the engine always cuts to `-abs(targetDepth)`. Depth is split into passes using `settings.cutting.stepdown` (slotting uses its own `depthPerPass`).

### Output

`[SC.OutputToolpath]`, one per contour that produced a path. Each has `operation`, `tool`, `settings`, `passes: [SC.ToolpathPass]` and `restCorners: [SC.RestCorner]` (sharp pocket corners the tool was too big to reach, for a follow-up pass with a smaller tool).

A `ToolpathPass` holds `depthZ` and `[SC.Waypoint]`. A `Waypoint` has `position: SIMD3<Double>`, `motion` (`.rapid`, `.linear`, `.arcCW(center:)`, `.arcCCW(center:)`) and `feedRate`, so it can be drawn directly as a preview.

### Quick start

```swift
import StratumCAM

let engine = SCEngine()

let tool = SC.ToolParams(name: "3.175mm Flat End Mill",
                         type: .flatEndMill,
                         diameter: 3.175,
                         number: 1)

let settings = SC.MachineSettings(
    cutting: SC.CuttingData(spindleSpeed: 12000,
                            feedRate: 1200,
                            plungeRate: 300,
                            stepdown: 0.1,
                            stepoverPercentage: 0.4),
    safeZ: 5.0,
    retractZ: 1.0,
    targetDepth: -1.0
)

// A 10x10 square
let square = SC.Contour(entities: [
    .init(geometry: .line(a: [0, 0],   b: [10, 0]),  reversed: false),
    .init(geometry: .line(a: [10, 0],  b: [10, 10]), reversed: false),
    .init(geometry: .line(a: [10, 10], b: [0, 10]),  reversed: false),
    .init(geometry: .line(a: [0, 10],  b: [0, 0]),   reversed: false)
], isClosed: true)

let toolpaths = try engine.generateToolpaths(
    from: [square],
    tool: tool,
    settings: settings,
    operation: .contour(side: .outside,
                        direction: .climb,
                        entry: .plunge,
                        leadIn: nil,
                        leadOut: nil,
                        tabs: [])
)
```

`generateToolpaths` is `throws`; see [Errors](#errors).

### Operations

`SC.MachiningOperation` describes *what* is machined:

| Operation | Input contour | Notes |
|---|---|---|
| `.engrave` | any | Traces the geometry at cutter centre, no tool compensation. |
| `.contour(side:direction:entry:leadIn:leadOut:tabs:)` | any | `side`: `.inside`, `.outside`, `.onContour`. Optional lead-in/out (`SC.LeadInOut`) and holding tabs (`SC.HoldingTab`). Lead-in is not allowed with `.ramp`/`.helix` entry. |
| `.pocket(direction:pattern:entry:)` | closed | Islands supported with `.concentric`. See patterns below. |
| `.facing(direction:extensionLength:)` | any | Rasters the contour's bounding box (the part footprint). Stepover is derived from tool diameter. |
| `.slotting(depthPerPass:pattern:entry:)` | centre curve | `pattern` is `.raster` or `.trochoidal`. Helpers to derive the centreline from a slot outline: `rectangleSlotCenterline`, `openEndedSlotCenterline`, `bothEndsOpenSlotCenterline`. |
| `.drilling(peckDepth:)` | point / closed circle | Any other closed shape drills at its bounding-box centre. `peckDepth: nil` = straight plunge. |
| `.boring(targetDiameter:dwellTime:shiftRetract:)` | point / closed circle | Single-point boring by circular interpolation. |
| `.counterbore(diameter:depth:direction:entry:)` | point / closed circle | Flat-bottom recess cut with an ordinary end mill as concentric rings per Z level. |
| `.threadMilling(pitch:isInternal:direction:radialPasses:targetDiameter:)` | closed circle | Helical thread milling; `direction` is `.rightHand`/`.leftHand`. |
| `.chamfer(params:)` | any | `SC.ChamferParams(width:depth:side:direction:)`. With a `.vBit` tool and `vAngle`, depth is derived from width. |

### Pocket patterns

`SC.PocketClearingPattern` describes *how* the pocket is cleared:

| Pattern | Status |
|---|---|
| `.offset` | Offset rings. |
| `.concentric(direction: .outsideIn \| .insideOut)` | Rings in a chosen order. The only pattern that honors islands. |
| `.raster` | Parallel back-and-forth passes. |
| `.spiral(direction:)` | Spiral clearing. |
| `.trochoidal(settings: SC.TrochoidalSettings(radialEngagement:loopRadius:))` | Trochoidal loops. |
| `.adaptive(settings:)` | **Not implemented yet**, throws `.invalidParameter`. |

Slotting accepts `SC.SlotClearingPattern`: `.raster`, `.trochoidal(settings:)`, `.adaptive(settings:)` (adaptive has no dedicated implementation yet).

### Entry strategies

`SC.EntryStrategy`: `.plunge`, `.ramp(angleDegrees:)`, `.helix(rampAngleDegrees:)`, `.fromOpenEnd(stepoverPercentage:)`. Ramp/helix angles must be between 0 and 90 (exclusive). With islands, only `.plunge`, `.fromOpenEnd` and `.ramp` are accepted.

### Cutting settings

`SC.CuttingData`: `spindleSpeed` (12000), `feedRate` (1200), `plungeRate` (300), `stepdown` (0.1), `stepoverPercentage` (0.25, fraction of tool diameter), `maxOptimalLoad`.

`SC.MachineSettings.retractPolicy` controls what happens between Z layers: `.safeZ` (default, full retract), `.clearance` (lift only `retractZ`), `.none` (no lift). The engine falls back to `.safeZ` whenever the direct move isn't known to be collision-free (e.g. islands). The last layer always retracts to `safeZ`.

### Pockets with islands

Pass one flat list of closed contours. Contours nested inside another become its islands (a contour nested inside an island is a pocket again):

```swift
let toolpaths = try engine.generateToolpaths(
    from: [outerBoundary, islandA, islandB],
    tool: tool,
    settings: settings,
    operation: .pocket(direction: .climb,
                       pattern: .concentric(direction: .outsideIn),
                       entry: .ramp(angleDegrees: 3))
)
```

You can also set `SC.Contour.islands` manually.

### Other examples

```swift
// Drill with peck cycle at a circle marker
engine.generateToolpaths(from: [holeCircle], tool: drill, settings: settings,
                         operation: .drilling(peckDepth: 1.0))

// Thread mill an M6x1 internal thread
operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand,
                          radialPasses: 2, targetDiameter: 6.0)

// Trochoidal slot
operation: .slotting(depthPerPass: 1.0,
                     pattern: .trochoidal(settings: .init(radialEngagement: 0.5, loopRadius: 1.5)),
                     entry: .plunge)

// Facing the part footprint
operation: .facing(direction: .climb, extensionLength: 2.0)
```

### Errors

All operations throw a single type, `SC.Error`:

| Case | Meaning |
|---|---|
| `.contourNotClosed` | Operation needs a closed contour. |
| `.invalidContour` | No usable geometry (or wrong shape, e.g. thread milling needs a single closed circle). |
| `.missingDrillPoint` | No point/circle to drill, bore or counterbore. |
| `.toolIncompatible` | Wrong tool for the job (e.g. chamfer without a V-bit angle, tool too large for the feature). |
| `.invalidParameter(String)` | A parameter is out of range or unsupported; the string names it. |
| `.geometryCollapsed` | Input valid but nothing left to cut (e.g. tool radius collapses every offset ring). |

### Offset utilities

Also public: `SCEngine.offsetContour(_:side:toolRadius:isClosed:)` / `offsetContours(...)`, `SCEngine.convert(geometry:reversed:)`, `SCEngine.buildWaypoints(for:atZ:settings:)`, and `GeoTools` line/circle intersection helpers.

## G-Code

All G-code engines take `[SC.OutputToolpath]` and return G-code as a string.

### Generic: `SCGCodeEngine`

Simple generic G-code (G21/G90/G17, M03/M05/M30, G00/G01/G02/G03, boring dwell via G04):

```swift
let gcode = SCGCodeEngine().generateGCode(from: toolpaths, settings: settings)
```

### Carvera: `SCMakeraGCodeEngine`

Native Swift generator that follows Makera's `Carvera.cps` post (tool changes `T<n>M6`, G54, `M5`/`G28`/`M30` footer, arc I/J relative to the arc start). It throws `GenerationError.noToolpaths` for an empty list and `.toolNumberNotSupported(n)` for tool > 6 in `.stockC1` mode.

```swift
var options = SCMakeraGCodeEngine.Options()
options.toolChangeMode = .automatic   // .automatic | .stockC1 | .manual | .community
options.programName = "MyPart"

let gcode = try SCMakeraGCodeEngine(options: options)
    .generateGCode(from: toolpaths, settings: settings)
```

Other options: `useExternalControl` (`M851/M852` around the spindle, default on), `returnToClearance` (`G28` before `M30`), `writeToolList`, `toolCommentAsChangeParameters`, `colletChangeOnShankSizeChange` (community firmware).

Tool fields read by this engine on `SC.ToolParams`: `number`, `comment` (`"TLO:A"`, `"TLO:M"`, `"TLO:-14"`), `clockwise`, `shaftDiameter`, `manualToolChange`.

### Post-processor: `SCPostEngine`

Runs a Fusion-style `.cps` post (e.g. `Carvera.cps`) inside JavaScriptCore through `SCPostKernel.js`, which emulates the Autodesk post-kernel API. Useful for any machine that has a `.cps` post, and as an oracle for `SCMakeraGCodeEngine`. The `.cps` file is **not** bundled; supply your own.

```swift
let post = try SCPostEngine(bundle: .main,            // your app bundle with Carvera.cps + SCPostKernel.js
                            properties: ["splitFile": "tool"],
                            stock: .init(zHigh: 0, zLow: -12))

let output = try post.generate(from: toolpaths,
                               settings: settings,
                               programName: "MyPart") { toolpath in
    SCPostEngine.Tool(number: toolpath.tool.number,
                      diameter: toolpath.tool.diameter,
                      name: toolpath.tool.name)
}
output.gcode              // main program
output.additionalFiles    // extra files when splitFile is enabled
output.diagnostics        // post warnings/errors, output.hasErrors
```

`SCPostEngine(postSource:kernelSource:properties:stock:)` takes the sources as strings. `generateGCode(from:settings:)` is a drop-in for `SCGCodeEngine` that returns a comment on failure.

`gcode-engine/run-post.js` is a Node harness to iterate on the kernel without building the app:

```
node run-post.js Carvera.cps SCPostKernel.js example-job.json
```

## Project layout

```
Sources/StratumCAM
  models/            SC.* types (see models/INFO.md for the operation / pattern hierarchy)
  toolpaths-engine/  SCEngine + per-operation extensions
  gcode-engine/      SCGCodeEngine, SCMakeraGCodeEngine, SCPostEngine, SCPostKernel.js
  utils/             EntityChainer, polygon offsetting, ramp/helix helpers, geometry tools
Sources/StratumCAMDemo   Metal preview app
Tests/StratumCAMTests    Swift Testing suite
```

## License

See [LICENSE](LICENSE).
