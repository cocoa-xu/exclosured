// CommonJS wrapper for environments that don't support ESM
"use strict";
const { ExclosuredHook } = require("./index.mjs");
module.exports = { ExclosuredHook };
module.exports.default = ExclosuredHook;
