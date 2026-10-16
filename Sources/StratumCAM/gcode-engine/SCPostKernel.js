/*
 * SCPostKernel.js
 *
 * A minimal emulation of the Autodesk post-processor kernel, just big enough to run
 * Makera's Carvera.cps for 3-axis (+ optional laser-free) jobs.
 *
 * Load order inside a fresh JSContext:
 *   1. set the global `__job` (a plain object parsed from JSON by the host)
 *   2. evaluate this file
 *   3. evaluate Carvera.cps
 *   4. call __run(), then read __collect()
 *
 * Written in sloppy-mode ES5-ish JavaScript on purpose: the .cps relies on implicit
 * globals (e.g. `for (i in arguments)`), so the shim and the post share one global scope.
 *
 * __job schema (JSON built by SCPostEngine.swift):
 *   { unit: "mm" | "in", programName, programComment?,
 *     properties: { <.cps property name>: value },       // overrides the post's defaults
 *     stock: { zHigh, zLow }?,                            // header comment only
 *     sections: [ { comment?, workOffset (1-6), spindleSpeed, forceToolChange?,
 *                   tool: { number, diameter, description, comment, type, clockwise,
 *                           shaftDiameter?, manualToolChange? },
 *                   moves: [ {t:"rapid", x,y,z} | {t:"linear", x,y,z,f}
 *                          | {t:"arc", cw, cx,cy, x,y,z, f}       // centre is ABSOLUTE
 *                          | {t:"dwell", seconds} | {t:"comment", text} | {t:"passthrough", text} ] } ] }
 *
 * Not supported yet: rotary (A) axis, probing, laser, radius compensation.
 */

// ---------------------------------------------------------------------------
// Constants (values only need to be distinct and self-consistent)
// ---------------------------------------------------------------------------
var MM = 1, IN = 2;
var unit = (__job.unit === "in") ? IN : MM;

var X = 0, Y = 1, Z = 2;
var ABC = 3;
var DEG = 180 / Math.PI;
var RAD = 1;

var CAPABILITY_MILLING = 1, CAPABILITY_TURNING = 2, CAPABILITY_JET = 4,
    CAPABILITY_SETUP_SHEET = 8, CAPABILITY_INTERMEDIATE = 16, CAPABILITY_MACHINE_SIMULATION = 32;

var TYPE_MILLING = 0, TYPE_TURNING = 1, TYPE_JET = 2, TYPE_ADDITIVE = 3;
var JET_MODE_THROUGH = 0, JET_MODE_ETCHING = 1, JET_MODE_VAPORIZE = 2;

// NOTE: placeholder numeric values (Fusion's real numbers are irrelevant to the output,
// except that the post prints `tool.type` in a comment).
var TOOL_UNSPECIFIED = 0, TOOL_DRILL = 1, TOOL_FLAT_END_MILL = 2, TOOL_BALL_END_MILL = 3,
    TOOL_BULL_NOSE_END_MILL = 4, TOOL_CHAMFER_MILL = 5, TOOL_ENGRAVING = 6,
    TOOL_FACE_MILL = 7, TOOL_PROBE = 8, TOOL_LASER_CUTTER = 9;

var COOLANT_FLOOD = 1, COOLANT_MIST = 2, COOLANT_THROUGH_TOOL = 3, COOLANT_AIR = 4,
    COOLANT_AIR_THROUGH_TOOL = 5, COOLANT_SUCTION = 6, COOLANT_FLOOD_MIST = 7,
    COOLANT_FLOOD_THROUGH_TOOL = 8, COOLANT_OFF = 0;

var COMMAND_STOP = "COMMAND_STOP", COMMAND_OPTIONAL_STOP = "COMMAND_OPTIONAL_STOP",
    COMMAND_END = "COMMAND_END", COMMAND_SPINDLE_CLOCKWISE = "COMMAND_SPINDLE_CLOCKWISE",
    COMMAND_SPINDLE_COUNTERCLOCKWISE = "COMMAND_SPINDLE_COUNTERCLOCKWISE",
    COMMAND_START_SPINDLE = "COMMAND_START_SPINDLE", COMMAND_STOP_SPINDLE = "COMMAND_STOP_SPINDLE",
    COMMAND_POWER_ON = "COMMAND_POWER_ON", COMMAND_POWER_OFF = "COMMAND_POWER_OFF",
    COMMAND_LOCK_MULTI_AXIS = "COMMAND_LOCK_MULTI_AXIS",
    COMMAND_UNLOCK_MULTI_AXIS = "COMMAND_UNLOCK_MULTI_AXIS",
    COMMAND_TOOL_MEASURE = "COMMAND_TOOL_MEASURE", COMMAND_BREAK_CONTROL = "COMMAND_BREAK_CONTROL";

var PLANE_XY = 0, PLANE_ZX = 1, PLANE_YZ = 2;
var RADIUS_COMPENSATION_OFF = 0, RADIUS_COMPENSATION_LEFT = 1, RADIUS_COMPENSATION_RIGHT = 2;
var FEED_INVERSE_TIME = 1, FEED_DPM = 2, FEED_FPM = 0, DPM_STANDARD = 0, DPM_COMBINATION = 1;
var OPTIMIZE_NONE = 0, OPTIMIZE_BOTH = 1, OPTIMIZE_TABLES = 2, OPTIMIZE_HEADS = 3, OPTIMIZE_AXIS = 4;
var PREFER_PREFERENCE = 0, ENABLE_ALL = 0;
var INVERSE_MINUTES = 0, INVERSE_SECONDS = 1;

// ---------------------------------------------------------------------------
// Diagnostics & output plumbing
// ---------------------------------------------------------------------------
var __diagnostics = [];
var __mainOutput = [];
var __redirects = [];          // [{path, lines}]
var __currentRedirect = null;
var __wordSeparator = " ";

function __emit(line) {
  (__currentRedirect ? __currentRedirect.lines : __mainOutput).push(line);
}
function writeln(text) { __emit(String(text === undefined ? "" : text)); }
function write(text) { __emit(String(text === undefined ? "" : text)); }
function error(message) { __diagnostics.push({severity: "error", message: String(message)}); }
function warning(message) { __diagnostics.push({severity: "warning", message: String(message)}); }
function warningOnce(message, id) { warning(message); }
function log(message) { /* host may ignore */ }
function localize(text) { return text; }
function validate(condition, message) { if (!condition) { error(message || "Validation failed"); } }

function setCodePage(name) { /* output encoding is the host's concern */ }
function setWordSeparator(s) { __wordSeparator = s; }
function getWordSeparator() { return __wordSeparator; }

function __flatten(args, out) {
  for (var i = 0; i < args.length; ++i) {
    var a = args[i];
    if (a === undefined || a === null) { continue; }
    if (typeof a === "object" && typeof a.length === "number" && typeof a !== "string") {
      __flatten(a, out);           // Arguments objects and arrays
    } else {
      var s = String(a);
      if (s !== "") { out.push(s); }
    }
  }
  return out;
}
function formatWords(args) { return __flatten(args, []).join(__wordSeparator); }
function writeWords(args) {
  var text = formatWords(args);
  if (text !== "") { writeln(text); }
}
function writeWords2(args) { writeWords(args); }

function redirectToFile(path) {
  __currentRedirect = {path: String(path), lines: []};
  __redirects.push(__currentRedirect);
}
function closeRedirection() { __currentRedirect = null; }
function isRedirecting() { return __currentRedirect !== null; }

var FileSystem = {
  getCombinedPath: function (a, b) { return (a ? a + "/" : "") + b; },
  getFolderPath: function (p) { var i = String(p).lastIndexOf("/"); return i < 0 ? "" : String(p).substring(0, i); }
};
function getOutputPath() { return "output." + (typeof extension !== "undefined" ? extension : "nc"); }

// ---------------------------------------------------------------------------
// Math helpers
// ---------------------------------------------------------------------------
function toRad(d) { return d * Math.PI / 180; }
function toDeg(r) { return r * 180 / Math.PI; }
function clamp(lo, v, hi) { return Math.max(lo, Math.min(hi, v)); }
function conditional(c, v) { return c ? v : ""; }
// Values are converted to the job's unit.
function spatial(v, u) { return (u === IN && unit === MM) ? v * 25.4 : ((u === MM && unit === IN) ? v / 25.4 : v); }
function toPreciseUnit(v, u) { return spatial(v, u); }
function angular(v, u) { return v; }

function Vector(x, y, z) {
  if (x && typeof x === "object") { z = x.z; y = x.y; x = x.x; }
  this.x = x || 0; this.y = y || 0; this.z = z || 0;
}
Vector.prototype = {
  get length() { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); },
  getLength: function () { return this.length; },
  isZero: function () { return this.length < 1e-9; },
  add: function (v) { return new Vector(this.x + v.x, this.y + v.y, this.z + v.z); },
  subtract: function (v) { return new Vector(this.x - v.x, this.y - v.y, this.z - v.z); },
  multiply: function (s) { return new Vector(this.x * s, this.y * s, this.z * s); },
  negated: function () { return new Vector(-this.x, -this.y, -this.z); },
  normalized: function () { var l = this.length; return l > 0 ? this.multiply(1 / l) : new Vector(); },
  getX: function () { return this.x; }, getY: function () { return this.y; }, getZ: function () { return this.z; }
};
Vector.sum = function (a, b) { return a.add(b); };
Vector.diff = function (a, b) { return a.subtract(b); };
Vector.dot = function (a, b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
Vector.cross = function (a, b) { return new Vector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); };
function isSameDirection(a, b) {
  var la = a.length, lb = b.length;
  if (la < 1e-9 || lb < 1e-9) { return false; }
  return Vector.dot(a, b) / (la * lb) > 1 - 1e-9;
}
function isZeroVector(v) { return v.length < 1e-9; }

function Matrix() {
  this.right = new Vector(1, 0, 0); this.up = new Vector(0, 1, 0); this.forward = new Vector(0, 0, 1);
}
Matrix.prototype.isIdentity = function () { return true; };

function Range(min, max) { this.min = min; this.max = max; }
Range.prototype = {
  getMinimum: function () { return this.min; },
  getMaximum: function () { return this.max; },
  expandToRange: function (r) { this.min = Math.min(this.min, r.min); this.max = Math.max(this.max, r.max); return this; }
};

// ---------------------------------------------------------------------------
// Formats and output variables
// ---------------------------------------------------------------------------
function createFormat(spec) {
  spec = spec || {};
  var decimals = spec.decimals === undefined ? 3 : spec.decimals;
  var scale = spec.scale === undefined ? 1 : spec.scale;
  var f = {
    prefix: spec.prefix || "", suffix: spec.suffix || "",
    decimals: decimals, scale: scale,
    forceDecimal: !!spec.forceDecimal, minimum: spec.minimum, maximum: spec.maximum,
    trim: spec.trim === undefined ? true : spec.trim
  };
  f.number = function (value) {
    var v = value * f.scale;
    if (f.maximum !== undefined) { v = Math.min(v, f.maximum); }
    if (f.minimum !== undefined) { v = Math.max(v, f.minimum); }
    var factor = Math.pow(10, f.decimals);
    var r = Math.round(Math.abs(v) * factor + 1e-9) / factor;     // round half away from zero
    var neg = v < 0 && r !== 0;
    var s = r.toFixed(f.decimals);
    if (f.decimals > 0 && f.trim) { s = s.replace(/0+$/, ""); }
    if (s.charAt(s.length - 1) === "." && !f.forceDecimal) { s = s.substring(0, s.length - 1); }
    if (s.indexOf(".") < 0 && f.forceDecimal && f.decimals > 0) { s += "."; }
    return (neg ? "-" : "") + s;
  };
  f.format = function (value) { return f.prefix + f.number(value) + f.suffix; };
  f.areDifferent = function (a, b) {
    if (a === undefined || b === undefined || isNaN(a) || isNaN(b)) { return true; }
    return f.number(a) !== f.number(b);
  };
  f.getResultingValue = function (value) { return parseFloat(f.number(value)) / f.scale; };
  f.isSignificant = function (value) { return parseFloat(f.number(value)) !== 0; };
  return f;
}

function createVariable(spec, format) {
  spec = spec || {};
  var fmt = format || createFormat({decimals: 0});
  var v = {
    prefix: spec.prefix || "", suffix: spec.suffix || "", force: !!spec.force,
    onchange: spec.onchange, disabled: false, lastText: undefined,
    current: spec.current, hasCurrent: spec.current !== undefined
  };
  if (spec.current !== undefined) { v.lastText = fmt.number(spec.current); }
  v.format = function (value) {
    if (v.disabled || value === undefined || value === null || isNaN(value)) { return ""; }
    var text = fmt.number(value);
    var changed = v.lastText !== text;
    v.current = value; v.hasCurrent = true;
    if (!changed && !v.force) { return ""; }
    v.lastText = text;
    if (v.onchange) { v.onchange(); }
    return v.prefix + fmt.prefix + text + fmt.suffix + v.suffix;
  };
  v.reset = function () { v.lastText = undefined; };
  v.disable = function () { v.disabled = true; };
  v.enable = function () { v.disabled = false; };
  v.isEnabled = function () { return !v.disabled; };
  v.getCurrent = function () { return v.current; };
  v.setCurrent = function (value) { v.current = value; v.lastText = fmt.number(value); };
  v.getPrefix = function () { return v.prefix; };
  return v;
}
function createOutputVariable(spec, format) { return createVariable(spec, format); }
function createIncrementalVariable(spec, format) { return createVariable(spec, format); }
function createReferenceVariable(spec, format) { return createVariable(spec, format); }

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------
function getProperty(name) {
  if (__job.properties && Object.prototype.hasOwnProperty.call(__job.properties, name)) {
    return __job.properties[name];
  }
  if (typeof properties !== "undefined" && properties[name]) { return properties[name].value; }
  return undefined;
}
function setProperty(name, value) { __job.properties = __job.properties || {}; __job.properties[name] = value; }

// ---------------------------------------------------------------------------
// Model: tools, sections, machine configuration
// ---------------------------------------------------------------------------
function __makeTool(t) {
  var tool = {
    number: t.number || 1, diameter: t.diameter || 0,
    type: t.type === undefined ? TOOL_FLAT_END_MILL : t.type,
    description: t.description || "", vendor: t.vendor || "", productId: t.productId || "",
    comment: t.comment || "", clockwise: t.clockwise !== false,
    coolant: t.coolant === undefined ? COOLANT_OFF : t.coolant,
    cornerRadius: t.cornerRadius || 0, tipDiameter: t.tipDiameter,  // undefined => omitted from the tool-list comment fluteLength: t.fluteLength || 0,
    shoulderLength: t.shoulderLength || 0, bodyLength: t.bodyLength || 0, holderLength: t.holderLength || 0,
    threadPitch: t.threadPitch || 0, taperAngle: t.taperAngle || 0, shaftDiameter: t.shaftDiameter || 0,
    manualToolChange: !!t.manualToolChange,
    shaft: { hasSections: function () { return false; }, getNumberOfSections: function () { return 0; } }
  };
  tool.lengthOffset = t.lengthOffset === undefined ? tool.number : t.lengthOffset;
  return tool;
}

function __makeSection(s, index) {
  var tool = __makeTool(s.tool || {});
  var moves = s.moves || [];
  var minZ = Infinity, maxZ = -Infinity, first = null;
  for (var i = 0; i < moves.length; ++i) {
    var m = moves[i];
    if (m.z === undefined) { continue; }
    if (!first) { first = new Vector(m.x, m.y, m.z); }
    minZ = Math.min(minZ, m.z); maxZ = Math.max(maxZ, m.z);
  }
  if (!first) { first = new Vector(0, 0, 0); minZ = maxZ = 0; }
  var offset = s.workOffset === undefined ? 1 : s.workOffset;
  var params = {};
  if (s.comment) { params["operation-comment"] = s.comment; }
  if (__job.stock) {
    params["operation:stockZHigh"] = __job.stock.zHigh;
    params["operation:stockZLow"] = __job.stock.zLow;
  }
  var sec = {
    id: index, moves: moves, tool: tool, spindleSpeed: s.spindleSpeed || 0,
    type: TYPE_MILLING, jetMode: JET_MODE_THROUGH,
    workOffset: offset, wcs: "G" + (53 + Math.max(1, offset)),
    workPlane: new Matrix(), modelOrigin: new Vector(0, 0, 0),
    getId: function () { return index; },
    getTool: function () { return tool; },
    getInitialPosition: function () { return first; },
    getGlobalZRange: function () { return new Range(minZ, maxZ); },
    getGlobalInitialToolAxis: function () { return new Vector(0, 0, 1); },
    getGlobalFinalToolAxis: function () { return new Vector(0, 0, 1); },
    getInitialToolAxisABC: function () { return new Vector(0, 0, 0); },
    getFinalToolAxisABC: function () { return new Vector(0, 0, 0); },
    isMultiAxis: function () { return false; },
    isOptimizedForMachine: function () { return false; },
    getOptimizedTCPMode: function () { return OPTIMIZE_NONE; },
    getForceToolChange: function () { return !!s.forceToolChange; },
    getBoundingBox: function () { return null; },
    getPartAttachPoint: function () { return new Vector(0, 0, 0); },
    getModelPlane: function () { return new Matrix(); },
    optimizeMachineAnglesByMachine: function () {},
    hasParameter: function (n) { return params.hasOwnProperty(n); },
    getParameter: function (n, d) { return params.hasOwnProperty(n) ? params[n] : d; }
  };
  return sec;
}

var __sections = [];
var __currentSectionIndex = -1;
function getNumberOfSections() { return __sections.length; }
function getSection(i) { return __sections[i]; }
function getPreviousSection() { return __sections[Math.max(0, __currentSectionIndex - 1)]; }
function getNextSection() { return __sections[Math.min(__sections.length - 1, __currentSectionIndex + 1)]; }
function isFirstSection() { return __currentSectionIndex <= 0; }
function isLastSection() { return __currentSectionIndex >= __sections.length - 1; }
function getCurrentSectionId() { return __currentSectionIndex; }
function is3D() { return true; }
// Global parameter access reads from the section being processed.
function hasParameter(name) { return currentSection ? currentSection.hasParameter(name) : false; }
function getParameter(name, defaultValue) { return currentSection ? currentSection.getParameter(name, defaultValue) : defaultValue; }
function getGlobalParameter(name, defaultValue) { return defaultValue; }
function hasGlobalParameter(name) { return false; }

function getToolTable() {
  var seen = {}, tools = [];
  for (var i = 0; i < __sections.length; ++i) {
    var t = __sections[i].getTool();
    if (!seen[t.number]) { seen[t.number] = true; tools.push(t); }
  }
  return { getNumberOfTools: function () { return tools.length; }, getTool: function (i) { return tools[i]; } };
}
function getToolTypeName(type) {
  var names = ["unspecified", "drill", "flat end mill", "ball end mill", "bull nose end mill",
               "chamfer mill", "engraving", "face mill", "probe", "laser cutter"];
  return names[type] || "unspecified";
}

var machineConfiguration = {
  isReceived: function () { return false; },
  getVendor: function () { return (__job.machine && __job.machine.vendor) || ""; },
  getModel: function () { return (__job.machine && __job.machine.model) || ""; },
  getDescription: function () { return (__job.machine && __job.machine.description) || ""; },
  isMultiAxisConfiguration: function () { return false; },
  isMachineCoordinate: function (i) { return false; },
  isHeadConfiguration: function () { return false; },
  isABCSupported: function () { return true; },
  getSpindleAxis: function () { return new Vector(0, 0, 1); },
  getDirection: function () { return new Vector(0, 0, 1); },
  getABCByPreference: function () { return new Vector(0, 0, 0); },
  getOrientation: function () { return new Matrix(); },
  getRemainingOrientation: function () { return new Matrix(); },
  setVirtualTooltip: function () {}, enableMachineRewinds: function () {},
  performRewinds: function () { return false; }
};
function setMachineConfiguration(c) { machineConfiguration = c; }
function optimizeMachineAngles2() {}
function cancelTransformation() {}
function setRotation() {}
function setCurrentABC() {}
function getCurrentDirection() { return new Vector(0, 0, 0); }
function getFramePosition(p) { return p; }          // identity work-plane transform
var state = {twpIsActive: false};
function machineSimulation() {}

// ---------------------------------------------------------------------------
// Engine state that the post reads as globals
// ---------------------------------------------------------------------------
var programName = __job.programName || "";
var programComment = __job.programComment || "";
var currentSection, tool, spindleSpeed = 0, radiusCompensation = 0, power = false, movement;
var __pos = new Vector(0, 0, 0);
var __circular = null;
var __nextMotion = false;

function getCurrentPosition() { return new Vector(__pos.x, __pos.y, __pos.z); }
function getNextRecord() { return { isMotion: function () { return __nextMotion; } }; }
function onImpliedCommand() {}
function onUnsupportedCommand(c) { error("Unsupported command: " + c); }
function onUnsupportedCoolant(c) { error("Unsupported coolant: " + c); }
function getCommandStringId(c) { return String(c); }

// Arc queries (XY-plane arcs only; that is all the host supplies)
function isFullCircle() { return !!(__circular && __circular.full); }
function isHelical() { return !!(__circular && __circular.helical); }
function getCircularPlane() { return PLANE_XY; }

/** Replace the arc currently being output with line segments within `tol`. */
function linearize(tol) {
  var c = __circular;
  if (!c) { return; }
  var r = Math.hypot(c.start.x - c.cx, c.start.y - c.cy);
  var a0 = Math.atan2(c.start.y - c.cy, c.start.x - c.cx);
  var a1 = Math.atan2(c.end.y - c.cy, c.end.x - c.cx);
  var sweep = c.full ? 2 * Math.PI : (c.cw ? a0 - a1 : a1 - a0);
  while (!c.full && sweep <= 0) { sweep += 2 * Math.PI; }
  var step = (r > tol) ? 2 * Math.acos(1 - tol / r) : Math.PI / 4;
  var n = Math.max(2, Math.ceil(sweep / Math.max(step, 1e-3)));
  var savedCircular = __circular;
  __circular = null;
  for (var i = 1; i <= n; ++i) {
    var t = i / n, a = c.cw ? a0 - sweep * t : a0 + sweep * t;
    var px = (i === n) ? c.end.x : c.cx + r * Math.cos(a);
    var py = (i === n) ? c.end.y : c.cy + r * Math.sin(a);
    var pz = c.start.z + (c.end.z - c.start.z) * t;
    onLinear(px, py, pz, c.feed);
    __pos = new Vector(px, py, pz);
  }
  __circular = savedCircular;
}

// ---------------------------------------------------------------------------
// Driver: plays the host's job through the post's callbacks, like Fusion's engine
// ---------------------------------------------------------------------------
var __maxSweep = null;

function __arc(m) {
  var start = getCurrentPosition();
  var end = new Vector(m.x, m.y, m.z);
  var cz = (m.cz === undefined) ? start.z : m.cz;
  var chord = Math.hypot(end.x - start.x, end.y - start.y);
  var full = chord < 1e-6;
  var helical = Math.abs(end.z - start.z) > 1e-6;
  var radius = Math.hypot(start.x - m.cx, start.y - m.cy);

  // Honour the post's circular limits the way the real engine does.
  var minR = (typeof minimumCircularRadius !== "undefined") ? minimumCircularRadius : 0;
  var maxS = (typeof maximumCircularSweep !== "undefined") ? maximumCircularSweep : Math.PI * 2;
  var tol = (typeof tolerance !== "undefined") ? tolerance : 0.002;

  var a0 = Math.atan2(start.y - m.cy, start.x - m.cx);
  var a1 = Math.atan2(end.y - m.cy, end.x - m.cx);
  var sweep = full ? 2 * Math.PI : (m.cw ? a0 - a1 : a1 - a0);
  while (!full && sweep <= 0) { sweep += 2 * Math.PI; }

  __circular = {full: full, helical: helical, start: start, end: end, cx: m.cx, cy: m.cy, cw: m.cw, feed: m.f};

  if (radius < minR) {                      // too small for an arc
    linearize(tol); __circular = null; __pos = end; return;
  }
  if (!full && sweep > maxS + 1e-9) {       // split long arcs into equal pieces
    var pieces = Math.ceil(sweep / maxS - 1e-9);
    var from = start;
    for (var i = 1; i <= pieces; ++i) {
      var t = i / pieces, a = m.cw ? a0 - sweep * t : a0 + sweep * t;
      var to = (i === pieces) ? end
        : new Vector(m.cx + radius * Math.cos(a), m.cy + radius * Math.sin(a), start.z + (end.z - start.z) * t);
      __circular = {full: false, helical: helical, start: from, end: to, cx: m.cx, cy: m.cy, cw: m.cw, feed: m.f};
      onCircular(m.cw, m.cx, m.cy, cz, to.x, to.y, to.z, m.f);
      __pos = to; from = to;
    }
    __circular = null; return;
  }
  onCircular(m.cw, m.cx, m.cy, cz, end.x, end.y, end.z, m.f);
  __circular = null;
  __pos = end;
}

function __isMotion(m) { return m && (m.t === "rapid" || m.t === "linear" || m.t === "arc"); }

function __run() {
  for (var i = 0; i < __job.sections.length; ++i) { __sections.push(__makeSection(__job.sections[i], i)); }
  if (__sections.length === 0) { error("Job contains no sections."); return; }

  __currentSectionIndex = 0;
  currentSection = __sections[0]; tool = currentSection.getTool();
  __pos = new Vector(currentSection.getInitialPosition());   // see README: first-section start position

  onOpen(currentSection);

  for (var s = 0; s < __sections.length; ++s) {
    __currentSectionIndex = s;
    currentSection = __sections[s]; tool = currentSection.getTool();
    spindleSpeed = currentSection.spindleSpeed;

    onSection();

    var moves = currentSection.moves;
    for (var k = 0; k < moves.length; ++k) {
      var m = moves[k];
      __nextMotion = __isMotion(moves[k + 1]);
      switch (m.t) {
      case "rapid":
        onRapid(m.x, m.y, m.z); __pos = new Vector(m.x, m.y, m.z); break;
      case "linear":
        onLinear(m.x, m.y, m.z, m.f); __pos = new Vector(m.x, m.y, m.z); break;
      case "arc":
        __arc(m); break;
      case "dwell":
        onDwell(m.seconds); break;
      case "comment":
        onComment(m.text); break;
      case "passthrough":
        onPassThrough(m.text); break;
      default:
        error("Unknown move type: " + m.t);
      }
    }
    onSectionEnd();
  }
  onClose();
}

function __collect() {
  var files = [{path: "", text: __mainOutput.join("\n")}];
  for (var i = 0; i < __redirects.length; ++i) {
    files.push({path: __redirects[i].path, text: __redirects[i].lines.join("\n")});
  }
  return JSON.stringify({files: files, diagnostics: __diagnostics});
}
