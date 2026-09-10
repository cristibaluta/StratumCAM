# StratumCAM
Swift Lib to create toolpaths for CAM softwares

All the models are under the SC namespace


## Toolpaths

### Input
To generate toolpaths the lib expects as input a `[SC.Contour]`, `SC.ToolParams`, `SC.MachineSettings`. A contour is a chain of `DXF.Entity`. Each continuous selectable path from your model should be a contour.
|
|
Convert the entities to lines and arcs that a CNC understands, based on the chosen tool and strategy.
|
|
### Output
The output is `[SC.OutputToolpath]` containing `[ToolpathPass]` from where you can extract the 3D points for drawing on screen.

```swift
import StratumCAM

let engine = SCEngine()
let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)
let settings = SC.MachineSettings(feedRate: 1000.0,
                                  plungeRate: 300.0,
                                  safeZ: 5.0,
                                  targetDepth: -1.0)
let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7)
let contour = SC.Contour(
    entities: [
        SC.Contour.Chained(entity: lineEntity, reversed: false)
    ],
    isClosed: false
)
let toolpaths = engine.generateToolpaths(from: contours, tool: tool, settings: settings)
```


## G-Code

### Input
`[SC.OutputToolpath]` from the previous operation

### Output
G-Code as string

```swift
import StratumCAM

let engine = SCGCodeEngine()
let settings = SC.MachineSettings(feedRate: 1000.0,
                                  plungeRate: 300.0,
                                  safeZ: 5.0,
                                  targetDepth: -1.0)
let toolpaths = engine.generateGCode(from: toolpaths, settings: settings) 
```
