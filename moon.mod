// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "python123-ops/moontile"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/python123-ops/moontile"

license = "Apache-2.0"

keywords = [ "computer-vision", "object-detection", "tiling", "nms" ]

preferred_target = "wasm"

description = "Detector-independent sliced detection coordinates and suppression"

import {
  "moonbitlang/async@0.21.3",
}
