import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDirectory, "..")
const assetRoot = path.join(repoRoot, "MyChatIOS", "WebAssets")

await import(path.join(assetRoot, "renderer-core.js"))
const core = globalThis.MyChatRendererCore
assert.ok(core, "renderer core did not load")

assert.equal(
  core.normalizeMathDelimiters("正文 \\(x + 1\\)，代码 `\\(raw\\)`，块 \\[y^2\\]"),
  "正文 $x + 1$，代码 `\\(raw\\)`，块 $$y^2$$",
)
assert.equal(
  core.normalizeMathDelimiters("$$\n\\int_0^1 x^2\\,dx\n$$"),
  "$$\\int_0^1 x^2\\,dx$$",
)
assert.equal(
  core.repairCollapsedGfmTables("| A | B || --- | --- || 1 | 2 |"),
  "| A | B |\n| --- | --- |\n| 1 | 2 |",
)
assert.equal(
  core.repairCollapsedGfmTables("```\n| A || --- |\n```"),
  "```\n| A || --- |\n```",
)

const parsed = core.parseArtifactOutput(
  "说明<inline-artifact><svg></svg></inline-artifact>结尾<mermaid>graph TD;A-->B",
)
assert.equal(parsed.display, "说明\n\n结尾")
assert.deepEqual(
  parsed.blocks.map(({ kind, done }) => ({ kind, done })),
  [
    { kind: "inline-artifact", done: true },
    { kind: "mermaid", done: false },
  ],
)
assert.equal(core.parseArtifactOutput("还在输出 <arti").display, "还在输出")

const html = fs.readFileSync(path.join(assetRoot, "renderer.html"), "utf8")
for (const feature of [
  "renderer-core.js",
  "renderMathInElement",
  "sanitizeSvg",
  "mermaid.min.js",
  "vega-embed.min.js",
  "function-plot.js",
  "artifactFrameDocument",
  "state.frameRenderedRaw",
  "webkit.messageHandlers.copy",
  'renderer:"svg",ast:true',
  "validatedFunctionPlotSpec",
  "state.host.clientWidth<=0",
]) {
  assert.ok(html.includes(feature), `renderer is missing ${feature}`)
}

const inlineScripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)]
for (const [, source] of inlineScripts) {
  new Function(source)
}

for (const requiredAsset of [
  "marked.umd.js",
  "renderer-core.js",
  "katex/katex.min.js",
  "katex/auto-render.min.js",
  "mermaid.min.js",
  "vega.min.js",
  "vega-lite.min.js",
  "vega-embed.min.js",
  "function-plot.js",
]) {
  assert.ok(fs.existsSync(path.join(assetRoot, requiredAsset)), `missing ${requiredAsset}`)
}

console.log("Streaming rich-renderer contracts passed")
