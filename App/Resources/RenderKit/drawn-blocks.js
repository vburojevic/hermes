// Draws a reply's Mermaid diagrams, display math and SVG pictures as PNGs (docs/chat.md §3b).
//
// The app evaluates this file, then Mermaid or MathJax the first time a block needs one, in a
// hidden web view whose page may load nothing (its CSP has no sources but `data:` images). Every
// drawing ends as SVG markup that is decoded as an <img>, so no script inside it runs and nothing
// it points to loads, then painted onto a canvas at the screen's scale.
"use strict";

window.MathJax = {
  loader: { load: [] },
  startup: { typeset: false },
  options: { enableMenu: false, enableAssistiveMml: false },
  // `require` and `autoload` would fetch extensions; the full build has every one already.
  tex: {
    packages: { "[-]": ["require", "autoload", "html"] },
    formatError: (jax, error) => { throw error; },
  },
  // Each formula carries its own glyph paths, so its SVG stands alone as an image.
  svg: { fontCache: "none" },
};

(() => {
  const SVG = "http://www.w3.org/2000/svg";
  let mermaidConfig = "";
  let renders = 0;

  function mermaidReady(theme) {
    const config = JSON.stringify(theme);
    if (config === mermaidConfig) return;
    mermaidConfig = config;
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      darkMode: theme.dark,
      fontFamily: "-apple-system, system-ui, sans-serif",
      fontSize: theme.font,
      htmlLabels: false,
      flowchart: { htmlLabels: false, useMaxWidth: false },
      themeVariables: {
        darkMode: theme.dark,
        background: theme.canvas,
        fontFamily: "-apple-system, system-ui, sans-serif",
        fontSize: theme.font + "px",
        primaryColor: theme.fill,
        primaryTextColor: theme.text,
        primaryBorderColor: theme.line,
        secondaryColor: theme.fill2,
        secondaryTextColor: theme.text,
        secondaryBorderColor: theme.line,
        tertiaryColor: theme.fill3,
        tertiaryTextColor: theme.text,
        tertiaryBorderColor: theme.line,
        lineColor: theme.secondary,
        textColor: theme.text,
        titleColor: theme.text,
        mainBkg: theme.fill,
        nodeBorder: theme.line,
        clusterBkg: theme.fill3,
        clusterBorder: theme.line,
        edgeLabelBackground: theme.canvas,
        noteBkgColor: theme.fill2,
        noteTextColor: theme.text,
        noteBorderColor: theme.line,
        actorBkg: theme.fill,
        actorBorder: theme.line,
        actorTextColor: theme.text,
        signalColor: theme.secondary,
        signalTextColor: theme.text,
        labelTextColor: theme.text,
      },
    });
  }

  // Mermaid lays its diagram out in the page; whatever it leaves behind is removed.
  async function mermaidSVG(source, theme) {
    mermaidReady(theme);
    const id = "drawn" + (++renders);
    try {
      const { svg } = await window.mermaid.render(id, source);
      return svg;
    } finally {
      for (const node of document.querySelectorAll(`#${id}, #d${id}, #i${id}`)) node.remove();
    }
  }

  async function mathSVG(source, theme) {
    await window.MathJax.startup.promise;
    const node = await window.MathJax.tex2svgPromise(source, {
      display: true, em: theme.font, ex: theme.font / 2, containerWidth: 100000,
    });
    const svg = node.querySelector("svg");
    if (!svg) throw new Error("no svg");
    // Its units are ex: in pixels at the size it was laid out for.
    for (const side of ["width", "height"]) {
      const value = svg.getAttribute(side) || "";
      if (value.endsWith("ex")) svg.setAttribute(side, String(parseFloat(value) * theme.font / 2));
    }
    svg.removeAttribute("style");
    svg.setAttribute("color", theme.text);
    svg.setAttribute("style", "color:" + theme.text);
    return new XMLSerializer().serializeToString(svg);
  }

  // The markup as a standalone SVG document with its size in pixels, parsed but never put in the
  // page: nothing in it runs or loads.
  function sized(markup) {
    let text = markup;
    if (!/<svg[^>]*\sxmlns\s*=/.test(text)) text = text.replace(/<svg\b/i, `<svg xmlns="${SVG}"`);
    if (/xlink:/.test(text) && !/xmlns:xlink\s*=/.test(text)) {
      text = text.replace(/<svg\b/i, '<svg xmlns:xlink="http://www.w3.org/1999/xlink"');
    }
    const doc = new DOMParser().parseFromString(text, "image/svg+xml");
    const svg = doc.documentElement;
    if (!svg || svg.namespaceURI !== SVG || svg.localName !== "svg" || doc.querySelector("parsererror")) {
      throw new Error("not an svg");
    }
    const box = (svg.getAttribute("viewBox") || "").trim().split(/[\s,]+/).map(Number);
    const hasBox = box.length === 4 && box.every(Number.isFinite) && box[2] > 0 && box[3] > 0;
    const length = (name) => {
      const match = /^\s*([0-9.]+)\s*(px)?\s*$/.exec(svg.getAttribute(name) || "");
      return match ? parseFloat(match[1]) : NaN;
    };
    let width = length("width"), height = length("height");
    if (!(width > 0) && !(height > 0)) {
      [width, height] = hasBox ? [box[2], box[3]] : [300, 150];
    } else if (!(width > 0)) {
      width = hasBox ? height * box[2] / box[3] : height;
    } else if (!(height > 0)) {
      height = hasBox ? width * box[3] / box[2] : width;
    }
    svg.setAttribute("width", String(width));
    svg.setAttribute("height", String(height));
    if (!hasBox && length("width") > 0) svg.setAttribute("viewBox", `0 0 ${length("width")} ${length("height") || height}`);
    // Mermaid sizes itself to its container; as an image it is its own size.
    svg.style.removeProperty("max-width");
    return { xml: new XMLSerializer().serializeToString(svg), width, height };
  }

  async function paint(svg, job) {
    const image = new Image();
    image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg.xml);
    await image.decode();
    let scale = job.scale;
    scale = Math.min(scale, job.maxSide / svg.width, job.maxSide / svg.height,
      Math.sqrt(job.maxPixels / (svg.width * svg.height)));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(svg.width * scale));
    canvas.height = Math.max(1, Math.round(svg.height * scale));
    const context = canvas.getContext("2d");
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const url = canvas.toDataURL("image/png");
    canvas.width = 0;
    canvas.height = 0;
    return { png: url.slice(url.indexOf(",") + 1), width: svg.width, height: svg.height };
  }

  // One block: { kind, source, scale, maxSide, maxPixels, theme }.
  window.hermesDraw = async function (job) {
    let markup;
    switch (job.kind) {
      case "mermaid": markup = await mermaidSVG(job.source, job.theme); break;
      case "math": markup = await mathSVG(job.source, job.theme); break;
      case "svg": markup = job.source; break;
      default: throw new Error("unknown kind");
    }
    const svg = sized(markup);
    if (!(svg.width > 0 && svg.height > 0) || svg.width * svg.height > 64e6) throw new Error("bad size");
    return paint(svg, job);
  };
})();
