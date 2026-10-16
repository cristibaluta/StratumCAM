#!/usr/bin/env node
// Dev harness: runs Carvera.cps + SCPostKernel.js on a job JSON exactly like SCPostEngine.swift does,
// so you can iterate on the shim or compare against Fusion output without building the app.
//   node run-post.js Carvera.cps SCPostKernel.js example-job.json
const vm = require("vm"), fs = require("fs");
const [cpsPath, kernelPath, jobPath] = process.argv.slice(2);
if (!jobPath) { console.error("usage: node run-post.js <post.cps> <SCPostKernel.js> <job.json>"); process.exit(2); }
const ctx = vm.createContext({});
ctx.__job = JSON.parse(fs.readFileSync(jobPath, "utf8"));
vm.runInContext(fs.readFileSync(kernelPath, "utf8"), ctx, {filename: kernelPath});
vm.runInContext(fs.readFileSync(cpsPath, "utf8"), ctx, {filename: cpsPath});
vm.runInContext("__run()", ctx);
const out = JSON.parse(vm.runInContext("__collect()", ctx));
for (const f of out.files) { console.log(f.path ? `=== ${f.path}` : "=== MAIN"); console.log(f.text); }
if (out.diagnostics.length) { console.log("=== DIAGNOSTICS"); out.diagnostics.forEach(d => console.log(d.severity + ": " + d.message)); }
