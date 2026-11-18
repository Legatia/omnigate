// The documentation's only script: search over an index built with the
// site (/assets/search.json, fetched when the box is first used), and a copy
// button on code blocks. Nothing is sent anywhere; without it the pages are
// the same pages.
(function () {
  "use strict";
  var form = document.querySelector(".search"), box = document.getElementById("q"), list = document.getElementById("hits");
  var index = null, loading = null, shown = [], at = -1;

  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function load() {
    if (!loading) loading = fetch("/assets/search.json").then(function (r) { return r.json(); }).then(function (rows) {
      index = rows.map(function (r) { return { u: r.u, p: r.p, h: r.h, t: r.t, low: (r.p + " " + r.h + " " + r.t).toLowerCase(), head: r.h.toLowerCase(), page: r.p.toLowerCase() }; });
    }).catch(function () { loading = null; });
    return loading;
  }
  function find(query) {
    var terms = query.toLowerCase().split(/\s+/).filter(Boolean), out = [];
    if (!terms.length || !index) return out;
    index.forEach(function (row) {
      var score = 0;
      for (var i = 0; i < terms.length; i++) {
        var t = terms[i], n = row.low.indexOf(t), times = 0;
        if (n < 0) return;
        // A term in the heading counts most, then in the page's name, then how often the text has it.
        while (n >= 0 && times < 6) { times++; n = row.low.indexOf(t, n + t.length); }
        score += times + (row.head.indexOf(t) >= 0 ? 12 : 0) + (row.page.indexOf(t) >= 0 ? 3 : 0);
      }
      out.push({ row: row, score: score });
    });
    out.sort(function (a, b) { return b.score - a.score; });
    return out.slice(0, 12).map(function (x) { return x.row; });
  }
  // The text around the first term found, with the terms marked.
  function snippet(row, terms) {
    var low = row.t.toLowerCase(), first = -1;
    terms.forEach(function (t) { var n = low.indexOf(t); if (n >= 0 && (first < 0 || n < first)) first = n; });
    var from = Math.max(0, first - 50), text = (from > 0 ? "…" : "") + row.t.slice(from, from + 150) + (from + 150 < row.t.length ? "…" : "");
    var span = el("span", "text"), rest = text;
    while (rest) {
      var lowRest = rest.toLowerCase(), hit = -1, len = 0;
      terms.forEach(function (t) { var n = lowRest.indexOf(t); if (n >= 0 && (hit < 0 || n < hit)) { hit = n; len = t.length; } });
      if (hit < 0) { span.appendChild(document.createTextNode(rest)); break; }
      span.appendChild(document.createTextNode(rest.slice(0, hit)));
      span.appendChild(el("mark", null, rest.slice(hit, hit + len)));
      rest = rest.slice(hit + len);
    }
    return span;
  }
  function draw() {
    var query = box.value.trim(), terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    while (list.firstChild) list.removeChild(list.firstChild);
    shown = []; at = -1;
    if (!query) { list.hidden = true; return; }
    if (!index) { list.appendChild(el("li", "none", "Loading…")); list.hidden = false; return; }
    var rows = find(query);
    if (!rows.length) list.appendChild(el("li", "none", "Nothing found for “" + query + "”."));
    rows.forEach(function (row) {
      var li = el("li"), a = el("a");
      a.href = row.u;
      a.appendChild(el("span", "where", row.p));
      a.appendChild(el("span", "what", row.h || row.p));
      if (row.t) a.appendChild(snippet(row, terms));
      li.appendChild(a); list.appendChild(li); shown.push(a);
    });
    list.hidden = false;
  }
  function select(n) {
    if (!shown.length) return;
    at = (n + shown.length) % shown.length;
    shown.forEach(function (a, i) { a.setAttribute("aria-selected", i === at ? "true" : "false"); });
    shown[at].scrollIntoView({ block: "nearest" });
  }
  if (form && box && list && window.fetch) {
    form.hidden = false;
    form.addEventListener("submit", function (ev) { ev.preventDefault(); var a = shown[at < 0 ? 0 : at]; if (a) location.href = a.href; });
    box.addEventListener("focus", function () { load().then(draw); });
    box.addEventListener("input", function () { load().then(draw); draw(); });
    box.addEventListener("keydown", function (ev) {
      if (ev.key === "ArrowDown") { ev.preventDefault(); select(at + 1); }
      else if (ev.key === "ArrowUp") { ev.preventDefault(); select(at - 1); }
      else if (ev.key === "Escape") { list.hidden = true; box.blur(); }
    });
    document.addEventListener("click", function (ev) { if (!form.contains(ev.target)) list.hidden = true; });
    document.addEventListener("keydown", function (ev) {
      var tag = (ev.target.tagName || "").toLowerCase();
      if (ev.key === "/" && !ev.ctrlKey && !ev.metaKey && !ev.altKey && tag !== "input" && tag !== "textarea") { ev.preventDefault(); box.focus(); }
    });
  }

  if (navigator.clipboard) {
    Array.prototype.forEach.call(document.querySelectorAll(".prose pre"), function (pre) {
      var wrap = el("div", "code"), button = el("button", "copy", "Copy");
      button.type = "button";
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre); wrap.appendChild(button);
      button.addEventListener("click", function () {
        navigator.clipboard.writeText(pre.textContent.replace(/\n$/, "")).then(function () {
          button.textContent = "Copied";
          setTimeout(function () { button.textContent = "Copy"; }, 1400);
        });
      });
    });
  }
})();
