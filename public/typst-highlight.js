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
        const grammar = window.Prism && Prism.languages && Prism.languages.typst;
        if (grammar) {
            code.innerHTML = Prism.highlight(text, grammar, "typst")
                + (el.tagName === "TEXTAREA" && text.endsWith("\n") ? "\n" : "");
        } else {
            code.textContent = text;
        }
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
