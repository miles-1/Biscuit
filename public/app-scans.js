// Annotated-scan image handling: when an assn is shown, every page is fetched as its own image and
// stacked vertically in the grading pane (CSS gaps act as the page separators). Pages are requested
// in order of proximity to the page the grader needs to see, so the relevant page appears first.

// The target page element and in-page offset backing the currently shown question line. Kept so the
// line can be re-placed when the image rescales (e.g. on window resize), since its `top` is in px.
let gradeQLineTarget = null;

// Recompute the grade question line's vertical position from the (possibly resized) target image.
function repositionGradeQLine() {
    if (!gradeQLineTarget) return;
    const { item, img, qHeight } = gradeQLineTarget;
    if (!item.isConnected || !img.naturalHeight) return;
    const scale = img.clientHeight / img.naturalHeight;
    gradeQLine.style.top = `${item.offsetTop + qHeight * scale - Q_LINE_OFFSET_PX}px`;
}

window.addEventListener('resize', repositionGradeQLine);

// Build the order in which pages are requested/rendered, fanning outward from the target page:
// target, target+1, target-1, target+2, target-2, ... clamped to [1, numPages]. For the assign
// step (target page 1) this collapses to natural order (1, 2, 3, ...).
function proximityPageOrder(targetPage, numPages) {
    const order = [];
    const seen = new Set();
    const add = (p) => {
        if (p >= 1 && p <= numPages && !seen.has(p)) { seen.add(p); order.push(p); }
    };
    add(targetPage);
    for (let d = 1; d < numPages; d++) {
        add(targetPage + d);
        add(targetPage - d);
    }
    return order;
}

// Display an assn's scan. `targetPage` (1-indexed) and `qHeight` (pixel offset within that page, in
// the page's original resolution) position the question line and initial scroll; for the assign
// step these are 1 and 0 and no question line is drawn.
async function setAssnScan(assnId, targetPage, qHeight, isAssignName) {
    const loadingEl = isAssignName ? assignLoading : gradeLoading;
    const pageWrap = isAssignName ? assignPageWrap : gradePageWrap;
    const leftPane = isAssignName ? assignLeftPane : gradeLeftPane;
    const qLine = isAssignName ? null : gradeQLine;
    const myToken = ++scanRenderToken;

    loadingEl.classList.remove('hidden');
    pageWrap.classList.add('hidden');
    if (qLine) qLine.classList.add('hidden');
    if (!isAssignName) gradeQLineTarget = null;
    // Drop any pages from a previous render (the persistent q-line element stays in the wrap).
    pageWrap.querySelectorAll('.page-item').forEach(el => el.remove());

    const revealWrap = () => {
        loadingEl.classList.add('hidden');
        pageWrap.classList.remove('hidden');
    };

    let numPages;
    try {
        const res = await fetch(`/api/annotated_page_count/${assnId}`);
        if (!res.ok) {
            const msg = await res.text();
            throw new Error(msg || `Failed to load scan for assn ${assnId} (${res.status})`);
        }
        numPages = (await res.json()).num_pages || 0;
    } catch (e) {
        if (myToken === scanRenderToken) revealWrap();
        throw e;
    }
    if (myToken !== scanRenderToken) return; // a newer render superseded this one
    if (numPages === 0) { revealWrap(); return; }

    // Create one element per page in natural top-to-bottom order so the stack reads correctly.
    const pageImgs = {};
    for (let p = 1; p <= numPages; p++) {
        const item = document.createElement('div');
        item.classList.add('page-item');
        item.dataset.page = String(p);
        const img = document.createElement('img');
        img.classList.add('annotated-page');
        item.appendChild(img);
        pageWrap.appendChild(item);
        pageImgs[p] = { item, img };
    }

    const positionTarget = () => {
        if (myToken !== scanRenderToken) return;
        const target = pageImgs[targetPage];
        if (!target || !target.img.naturalHeight) return;
        const scale = target.img.clientHeight / target.img.naturalHeight;
        const yInWrap = target.item.offsetTop + qHeight * scale;
        if (qLine) {
            gradeQLineTarget = { item: target.item, img: target.img, qHeight };
            qLine.style.top = `${yInWrap - Q_LINE_OFFSET_PX}px`;
            qLine.classList.remove('hidden');
        }
        leftPane.scrollTop = Math.max(0, yInWrap - 100);
    };

    // A page's height is unknown until its image loads, and only pages stacked ABOVE the target
    // shift the target's offset. So reveal as soon as the target is up (fast first paint), but defer
    // the line placement + scroll until every page above the target has loaded; otherwise those
    // still-collapsed pages would push the target down afterward, leaving the line one page too high.
    const settled = new Set();
    let aboveRemaining = targetPage - 1;
    let targetReady = false;
    const placeWhenStable = () => {
        if (targetReady && aboveRemaining <= 0) positionTarget();
    };
    const settle = (p) => {
        if (myToken !== scanRenderToken || settled.has(p)) return;
        settled.add(p);
        if (p === targetPage) {
            targetReady = true;
            revealWrap();
        } else if (p < targetPage) {
            aboveRemaining--;
        }
        placeWhenStable();
    };

    // Kick off the requests in proximity order so the target page is fetched first.
    for (const p of proximityPageOrder(targetPage, numPages)) {
        const { img } = pageImgs[p];
        img.onload = () => settle(p);
        // Treat an error as "settled" too, so a missing page above the target can't stall placement.
        img.onerror = () => settle(p);
        img.src = annotatedPagePngUrl(assnId, p);
        // A page served from the browser's HTTP cache may already be complete; onload won't refire.
        if (img.complete && img.naturalHeight > 0) settle(p);
    }
}
