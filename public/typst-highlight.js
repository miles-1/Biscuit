// Grading shorthand: every `(-N)` in a feedback box deducts from the question's max score.
// Canonical pattern, shared with the grading UI so the highlight and the arithmetic never diverge.
const FEEDBACK_DEDUCTION_SOURCE = "\\(-\\d+(?:\\.\\d+)?\\)";

function parseFeedbackDeductions(text) {
    const matches = String(text || "").matchAll(new RegExp(FEEDBACK_DEDUCTION_SOURCE, "g"));
    return [...matches].map((m) => -Number(m[0].slice(2, -1)));
}

function escapeHighlightText(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Deduction markers get their own highlight instead of Typst colouring, so they are lifted out of
// the text and the gaps between them are handed to Prism. Splitting rather than post-processing
// Prism's HTML matters because `(-2.5)` does not survive as one token: the grammar takes the `-` as
// an escape and leaves the rest as prose.
function renderTypstHighlightHtml(text, markDeductions) {
    const grammar = window.Prism && Prism.languages && Prism.languages.typst;
    const highlightGap = (chunk) => {
        if (!chunk) return "";
        return grammar ? Prism.highlight(chunk, grammar, "typst") : escapeHighlightText(chunk);
    };
    if (!markDeductions) return highlightGap(text);
    let html = "";
    let cursor = 0;
    for (const match of text.matchAll(new RegExp(FEEDBACK_DEDUCTION_SOURCE, "g"))) {
        html += highlightGap(text.slice(cursor, match.index));
        html += `<span class="feedback-deduction">${escapeHighlightText(match[0])}</span>`;
        cursor = match.index + match[0].length;
    }
    return html + highlightGap(text.slice(cursor));
}

function wrapTypstMarkupField(el) {
    if (!el || el.dataset.typstHighlight === "1") return;
    if (el.closest(".typst-highlight-wrap")) return;

    const wrap = document.createElement("div");
    wrap.className = "typst-highlight-wrap " + (el.tagName === "TEXTAREA" ? "is-textarea" : "is-input");
    const pre = document.createElement("pre");
    pre.className = "typst-highlight-pre";
    pre.setAttribute("aria-hidden", "true");
    const code = document.createElement("code");
    code.className = "language-typst";
    pre.appendChild(code);
    el.parentNode.insertBefore(wrap, el);
    wrap.appendChild(pre);
    wrap.appendChild(el);
    el.dataset.typstHighlight = "1";
    el.classList.add("typst-highlight-field");

    const sync = () => {
        const text = el.value || "";
        // Only score-by-input feedback boxes opt in to deduction highlighting.
        const markDeductions = el.dataset.feedbackDeductions === "1";
        code.innerHTML = renderTypstHighlightHtml(text, markDeductions)
            + (el.tagName === "TEXTAREA" && text.endsWith("\n") ? "\n" : "");
        pre.scrollTop = el.scrollTop;
        pre.scrollLeft = el.scrollLeft;
    };
    el.addEventListener("input", sync);
    el.addEventListener("scroll", () => {
        pre.scrollTop = el.scrollTop;
        pre.scrollLeft = el.scrollLeft;
    });
    sync();
}

function enhanceTypstMarkupFields(root) {
    const scope = root || document;
    scope.querySelectorAll([
        "#builder-title",
        "#builder-intro",
        ".builder-section-title-input",
        ".builder-option-input",
        "textarea.builder-textarea",
        "textarea.feedback-input",
    ].join(",")).forEach(wrapTypstMarkupField);
}
