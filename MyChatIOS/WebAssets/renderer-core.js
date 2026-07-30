(function (global) {
  "use strict";

  var ARTIFACT_TAGS = [
    { kind: "vega", open: "<vega>", close: "</vega>" },
    { kind: "mermaid", open: "<mermaid>", close: "</mermaid>" },
    { kind: "function-plot", open: "<function-plot>", close: "</function-plot>" },
    { kind: "inline-artifact", open: "<inline-artifact>", close: "</inline-artifact>" },
    { kind: "artifact", open: "<artifact>", close: "</artifact>" },
  ];
  var CODE_PART_RE = /(```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`)/g;
  var FENCED_CODE_RE = /(```[\s\S]*?```|~~~[\s\S]*?~~~)/g;

  function trimTrailingArtifactPrelude(text) {
    var start = text.lastIndexOf("<");
    if (start === -1) return text;
    var tail = text.slice(start);
    for (var index = 0; index < ARTIFACT_TAGS.length; index += 1) {
      if (ARTIFACT_TAGS[index].open.indexOf(tail) === 0) {
        return text.slice(0, start).trimEnd();
      }
    }
    return text;
  }

  function nextArtifactTag(text, from) {
    var next = null;
    for (var index = 0; index < ARTIFACT_TAGS.length; index += 1) {
      var tag = ARTIFACT_TAGS[index];
      var start = text.indexOf(tag.open, from);
      if (start !== -1 && (!next || start < next.start)) next = { tag: tag, start: start };
    }
    return next;
  }

  function parseArtifactOutput(text) {
    var first = nextArtifactTag(text, 0);
    if (!first) return { display: trimTrailingArtifactPrelude(text), blocks: [] };

    var displayParts = [];
    var blocks = [];
    var cursor = 0;
    var next = first;
    while (next) {
      var before = text.slice(cursor, next.start).trim();
      if (before) displayParts.push(before);

      var bodyStart = next.start + next.tag.open.length;
      var end = text.indexOf(next.tag.close, bodyStart);
      if (end === -1) {
        blocks.push({
          kind: next.tag.kind,
          raw: text.slice(bodyStart),
          done: false,
        });
        cursor = text.length;
        break;
      }

      blocks.push({
        kind: next.tag.kind,
        raw: text.slice(bodyStart, end).trim(),
        done: true,
      });
      cursor = end + next.tag.close.length;
      next = nextArtifactTag(text, cursor);
    }

    if (cursor < text.length) {
      var trailing = trimTrailingArtifactPrelude(text.slice(cursor)).trim();
      if (trailing) displayParts.push(trailing);
    }
    return { display: displayParts.join("\n\n"), blocks: blocks };
  }

  function normalizeMathPart(text) {
    return text
      .replace(/\\\[([\s\S]*?)\\\]/g, function (_match, body) {
        return "$$" + body.trim().replace(/\r?\n\s*/g, " ") + "$$";
      })
      .replace(/\\\(([\s\S]*?)\\\)/g, function (_match, body) {
        return "$" + body.trim() + "$";
      })
      .replace(/\$\$([\s\S]*?)\$\$/g, function (_match, body) {
        return "$$" + body.trim().replace(/\r?\n\s*/g, " ") + "$$";
      });
  }

  function normalizeMathDelimiters(text) {
    if (!text) return text;
    return text
      .split(CODE_PART_RE)
      .map(function (part) {
        return part.indexOf("`") === 0 || part.indexOf("~~~") === 0
          ? part
          : normalizeMathPart(part);
      })
      .join("");
  }

  function repairTableLine(line) {
    if (!/\|[\t ]*:?-{3,}/.test(line) || line.indexOf("||") === -1) return line;
    return line.replace(/\|\|/g, "|\n|");
  }

  function repairCollapsedGfmTables(text) {
    if (!text || text.indexOf("|") === -1 || text.indexOf("||") === -1) return text;
    return text
      .split(FENCED_CODE_RE)
      .map(function (part) {
        if (part.indexOf("```") === 0 || part.indexOf("~~~") === 0) return part;
        return part.split("\n").map(repairTableLine).join("\n");
      })
      .join("");
  }

  function prepareMarkdown(text) {
    return repairCollapsedGfmTables(normalizeMathDelimiters(text));
  }

  global.MyChatRendererCore = Object.freeze({
    artifactTags: ARTIFACT_TAGS.slice(),
    normalizeMathDelimiters: normalizeMathDelimiters,
    repairCollapsedGfmTables: repairCollapsedGfmTables,
    prepareMarkdown: prepareMarkdown,
    parseArtifactOutput: parseArtifactOutput,
  });
})(globalThis);
