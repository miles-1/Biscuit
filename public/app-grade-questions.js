// Grade Assignments - Input Grades step: per-question/per-assn navigation, answer scoring, the
// bubble/rubric/manual-score UI, and saving the finished work back to the archive.

let persistedFeedbackTextareaHeight = null;

function studentFirstName(fullName) {
    if (fullName == null) return null;
    const s = String(fullName).trim();
    if (!s) return null;
    if (s.includes(',')) {
        const given = s.slice(s.indexOf(',') + 1).trim();
        return given.split(/\s+/)[0] || null;
    }
    return s.split(/\s+/)[0] || null;
}

function currentGradeAssnId() {
    const qid = questionIds[currentQIndex];
    const assns = questionsMap[qid]?.assns;
    if (!assns) return null;
    return Object.keys(assns)[currentAssnIndexForQ];
}

function applyFeedbackTemplateName(text, assnId = currentGradeAssnId()) {
    const name = studentFirstName(gradingData?.[assnId]?.name);
    if (!name) return text;
    return String(text).split('{{name}}').join(name);
}

async function finishNameAssn() {
    await commitCurrentGradingData();
    gradeStep1.classList.add('hidden');
    gradeStep2.classList.remove('hidden');
    buildQuestionMap();
    currentQIndex = 0;
    currentAssnIndexForQ = 0;
    renderGradeStep();
}

async function returnToNameAssn() {
    await commitCurrentGradingData();
    gradeStep2.classList.add('hidden');
    gradeStep1.classList.remove('hidden');
    renderAssignStep();
}

function buildQuestionMap() {
    // keys of questionsMap are question IDs; keys of questionsMap[q].assns are assn IDs
    questionsMap = {};
    for (let [qId, mQ] of Object.entries(masterQuestions)) {
        let assnVerQs = {};
        Object.entries(gradingData).forEach(([assnId, qData]) => {
            if (assnId === "feedback-templates" || !qData?.questions) return;
            let qs = qData.questions;
            let v_q = qs.find(q => q.id == qId)
            if (v_q) {assnVerQs[assnId] = v_q;}
        })
        if (Object.keys(assnVerQs).length > 0) {
            questionsMap[qId] = { masterQ: mQ, assns: assnVerQs };
        }
    }
    questionIds = Object.keys(questionsMap)
}

function updateGradeDropdowns() {
    // questions dropdown
    const qItems = Object.entries(questionsMap).map(([qId, qData]) => ({
        label: `Question ${qId}`,
        isComplete: Object.values(qData.assns).every(q => q?.is_graded === true)
    }));
    renderStatusDropdown('grade-q-dropdown', qItems, currentQIndex, jumpToQ);
    // assns dropdown
    const currentAssns = questionsMap[questionIds[currentQIndex]].assns;
    const assnItems = Object.entries(currentAssns).map(([assnId, q]) => ({
        label: `Assn ${assnId}`,
        isComplete: q?.is_graded === true
    }));
    renderStatusDropdown('grade-assn-dropdown', assnItems, currentAssnIndexForQ, jumpToGradeAssn);
    // buttons
    document.getElementById('btn-prev-q').disabled = (currentQIndex <= 0);
    document.getElementById('btn-next-q').disabled = (currentQIndex >= questionIds.length - 1);
    document.getElementById('btn-prev-assn-grade').disabled = (currentAssnIndexForQ <= 0);
    document.getElementById('btn-next-assn-grade').disabled = (currentAssnIndexForQ >= Object.keys(currentAssns).length - 1);
}

async function jumpToQ(idx) {
    await commitCurrentGradingData();
    currentQIndex = parseInt(idx);
    currentAssnIndexForQ = 0;
    renderGradeStep();
}
async function jumpToGradeAssn(idx) {
    await commitCurrentGradingData();
    currentAssnIndexForQ = parseInt(idx);
    renderGradeStep();
}
async function prevQ() {
    if (currentQIndex > 0) {
        await commitCurrentGradingData();
        currentQIndex--;
        currentAssnIndexForQ = 0;
        renderGradeStep();
    }
}
async function nextQ() {
    if (currentQIndex < questionIds.length - 1) {
        await commitCurrentGradingData();
        currentQIndex++;
        currentAssnIndexForQ = 0;
        renderGradeStep();
    }
}
async function prevGradeAssn() {
    if (currentAssnIndexForQ > 0) {
        await commitCurrentGradingData();
        currentAssnIndexForQ--;
        renderGradeStep();
    }
}
async function nextGradeAssn() {
    if (currentAssnIndexForQ < Object.keys(questionsMap[questionIds[currentQIndex]].assns).length - 1) {
        await commitCurrentGradingData();
        currentAssnIndexForQ++;
        renderGradeStep();
    }
}

// Effective answer for a multiple-choice item: a manual override (if present) replaces detection.
function multipleChoiceEffective(currentItem) {
    return currentItem.manual_answer !== undefined ? currentItem.manual_answer : currentItem.answer;
}

// Effective per-statement answers for a true/false item: non-null manual overrides replace
// detection; null entries fall back to whatever was detected for that statement.
function trueFalseEffective(currentItem) {
    const detected = currentItem.answer;
    const manual = Array.isArray(currentItem.manual_answer) ? currentItem.manual_answer : null;
    return detected.map((d, k) => (manual && manual[k] != null) ? manual[k] : d);
}

// Score a multiple-choice answer, or null when it cannot be graded yet (detection is "unknown"
// and the grader has not overridden it). "unanswered" is gradeable and simply scores zero.
// No key (null/undefined correctAnswer): any selected option gets full credit; unanswered scores zero.
function gradeMultipleChoice(effective, correctAnswer, pts) {
    if (effective === "unknown") return null;
    if (correctAnswer == null) return Number.isInteger(effective) ? pts : 0;
    if (Number.isInteger(effective)) return effective === correctAnswer ? pts : 0;
    return 0;
}

// Score a true/false answer, or null when any statement is still an unresolved "unknown".
// No key (null/undefined correctAnswer): full credit only when every statement is true or false.
function gradeTrueFalse(effective, correctAnswer, pts) {
    if (!Array.isArray(effective) || effective.length === 0) return null;
    if (effective.some(v => v === "unknown")) return null;
    if (correctAnswer == null) {
        return effective.every(v => v === true || v === false) ? pts : 0;
    }
    const trueSet = new Set(correctAnswer);
    let correct = 0;
    for (let i = 0; i < effective.length; i++) {
        const expectedTrue = trueSet.has(i);
        if (effective[i] === true && expectedTrue) correct++;
        else if (effective[i] === false && !expectedTrue) correct++;
    }
    return (correct / effective.length) * pts;
}

function makeBubble(isCorrect, detectionUnknown, isDetected, isSelected) {
    const circle = document.createElement('div');
    circle.classList.add('bubble-circle');
    if (isCorrect) circle.classList.add('correct');
    if (detectionUnknown) circle.classList.add('unknown');
    else if (isDetected) circle.classList.add('detected');
    const inset = document.createElement('div');
    inset.classList.add('bubble-inset');
    if (isSelected) inset.classList.add('selected');
    circle.appendChild(inset);
    return circle
}

function makeLegendBubble(...classNames) {
    const circle = document.createElement('div');
    circle.classList.add('bubble-circle', ...classNames);
    const inset = document.createElement('div');
    inset.classList.add('bubble-inset');
    circle.appendChild(inset);
    return circle;
}

function getOptionPermutation(item, numOptions) {
    const p = item?.option_permutation;
    if (Array.isArray(p) && p.length === numOptions) return p.map(Number);
    return Array.from({ length: numOptions }, (_, i) => i);
}

// Keep master_answer in master-option index space from the effective (manual-or-detected) answer.
function syncMasterAnswer(item, qType, numOptions) {
    const perm = getOptionPermutation(item, numOptions);
    // Persist non-identity permutations only (identity is implied when omitted).
    if (perm.every((v, i) => v === i)) delete item.option_permutation;
    else item.option_permutation = perm;

    if (qType === 'multiple_choice') {
        const eff = multipleChoiceEffective(item);
        if (eff === 'unanswered' || eff === 'unknown') item.master_answer = eff;
        else if (Number.isInteger(eff)) item.master_answer = perm[eff];
        else delete item.master_answer;
        return;
    }
    if (qType === 'true_false') {
        const eff = trueFalseEffective(item);
        const selected = Array(numOptions).fill('unanswered');
        for (let k = 0; k < numOptions; k++) selected[perm[k]] = eff[k];
        item.master_answer = selected;
    }
}

function formatChartTick(v) {
    if (!Number.isFinite(v)) return '';
    if (Math.abs(v - Math.round(v)) < 1e-9) return String(Math.round(v));
    return String(parseFloat(v.toFixed(2)));
}

function pickAxisTicks(minV, maxV, maxLabels = 5) {
    if (!(maxV > minV)) return [minV];
    const n = Math.max(2, Math.min(maxLabels, 5));
    const ticks = [];
    for (let i = 0; i < n; i++) {
        ticks.push(minV + (maxV - minV) * (i / (n - 1)));
    }
    return ticks;
}

// Pick a percent-axis ceiling and ≤5 tick labels (including 0 and max), with short integer-ish steps.
function nicePercentAxis(dataMax, maxTicks = 5) {
    const maxSteps = Math.max(1, maxTicks - 1);
    const raw = Math.max(0, Number(dataMax) || 0);
    if (!(raw > 0)) return { maxY: 5, ticks: [0, 5] };

    const target = Math.min(100, raw);
    const stepCandidates = [1, 2, 5, 10, 20, 25, 50, 100];
    let best = null;
    for (const step of stepCandidates) {
        const nSteps = Math.ceil(target / step);
        if (nSteps < 1 || nSteps > maxSteps) continue;
        const maxY = nSteps * step;
        if (maxY > 100) continue;
        if (
            !best
            || maxY < best.maxY
            || (maxY === best.maxY && step < best.step)
        ) {
            best = { maxY, step, nSteps };
        }
    }
    if (!best) {
        // High percents that need the full 0–100 range with ≤5 ticks.
        best = { maxY: 100, step: 25, nSteps: 4 };
    }
    const ticks = [];
    for (let i = 0; i <= best.nSteps; i++) ticks.push(i * best.step);
    ticks[ticks.length - 1] = best.maxY;
    return { maxY: best.maxY, ticks };
}

function computeHistogramSpec(scores, maxPoints) {
    const maxP = Number(maxPoints);
    if (!(maxP > 0) || !scores.length) return null;
    const unique = [...new Set(scores.map(Number).filter(Number.isFinite))].sort((a, b) => a - b);
    let targetWidth;
    if (unique.length < 2) {
        targetWidth = maxP < 3 ? maxP / 3 : 1;
    } else {
        let minDiff = Infinity;
        for (let i = 1; i < unique.length; i++) {
            const d = unique[i] - unique[i - 1];
            if (d > 0 && d < minDiff) minDiff = d;
        }
        targetWidth = Math.min(1, minDiff);
    }
    if (!(targetWidth > 0)) targetWidth = 1;
    // Split [0, maxP) into equal-width bins, then add a dedicated final bin for maxP
    // so a perfect score never merges with the previous interval (e.g. 0,1,2 on a 2-pt question).
    let nInterior = Math.ceil(maxP / targetWidth);
    nInterior = Math.max(1, Math.min(14, nInterior));
    const width = maxP / nInterior;
    const nBins = nInterior + 1;
    const edges = Array.from({ length: nInterior }, (_, i) => i * width);
    edges.push(maxP);
    const counts = Array(nBins).fill(0);
    for (const raw of scores) {
        const s = Number(raw);
        let idx;
        if (!(s < maxP)) idx = nBins - 1;
        else {
            idx = Math.floor(s / width);
            if (idx < 0) idx = 0;
            if (idx >= nInterior) idx = nInterior - 1;
        }
        counts[idx]++;
    }
    return { counts, nBins, nInterior, width, edges, maxPoints: maxP, graded: scores.length };
}

function collectGradedAssnItems(qId) {
    const entry = questionsMap[qId];
    if (!entry?.assns) return [];
    return Object.values(entry.assns).filter((q) => q?.is_graded === true);
}

function buildSvgEl(name, attrs = {}) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', name);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, String(v));
    return el;
}

function attachChartTooltip(svg, tipTextFn) {
    let tip = document.getElementById('response-chart-tooltip');
    if (!tip) {
        tip = document.createElement('div');
        tip.id = 'response-chart-tooltip';
        tip.className = 'response-chart-tooltip hidden';
        document.body.appendChild(tip);
    }
    const show = (e, text) => {
        tip.textContent = text;
        tip.classList.remove('hidden');
        tip.style.left = `${e.clientX + 12}px`;
        tip.style.top = `${e.clientY + 12}px`;
    };
    const hide = () => tip.classList.add('hidden');
    svg.querySelectorAll('[data-tip]').forEach((node) => {
        node.addEventListener('pointerenter', (e) => show(e, tipTextFn(node)));
        node.addEventListener('pointermove', (e) => show(e, tipTextFn(node)));
        node.addEventListener('pointerleave', hide);
    });
}

function renderBarChartSvg({ values, labels, correctSet, tipKind, tipLabels }) {
    const W = 175, H = 100;
    const padL = 28, padR = 6, padT = 8, padB = 18;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;
    const svg = buildSvgEl('svg', { class: 'response-chart', viewBox: `0 0 ${W} ${H}`, width: W, height: H });
    const n = values.length;
    if (!n) return svg;
    const dataMax = Math.max(0, ...values.map(Number).filter(Number.isFinite));
    const { maxY, ticks: yTicks } = nicePercentAxis(dataMax, 5);

    // axes
    svg.appendChild(buildSvgEl('line', { x1: padL, y1: padT, x2: padL, y2: padT + plotH, stroke: 'currentColor', 'stroke-width': 1 }));
    svg.appendChild(buildSvgEl('line', { x1: padL, y1: padT + plotH, x2: padL + plotW, y2: padT + plotH, stroke: 'currentColor', 'stroke-width': 1 }));

    for (const yt of yTicks) {
        const y = padT + plotH * (1 - yt / maxY);
        svg.appendChild(buildSvgEl('line', {
            x1: padL, y1: y, x2: padL + plotW, y2: y,
            stroke: 'currentColor', 'stroke-width': 0.5, opacity: 0.25,
        }));
        const t = buildSvgEl('text', {
            x: padL - 3, y: y + 3, 'text-anchor': 'end', 'font-size': 8, fill: 'currentColor',
        });
        t.textContent = `${formatChartTick(yt)}%`;
        svg.appendChild(t);
    }

    const gap = 2;
    const barW = Math.max(2, (plotW - gap * (n + 1)) / n);
    values.forEach((v, i) => {
        const h = plotH * (Number(v) / maxY);
        const x = padL + gap + i * (barW + gap);
        const y = padT + plotH - h;
        const isCorrect = correctSet && correctSet.has(i);
        const rect = buildSvgEl('rect', {
            x, y, width: barW, height: Math.max(0, h),
            class: isCorrect ? 'response-bar correct' : 'response-bar',
            'data-tip': '1',
            'data-i': i,
            'data-v': v,
            'data-tip-label': tipLabels?.[i] ?? labels[i] ?? '',
        });
        svg.appendChild(rect);
        const lx = x + barW / 2;
        const lab = buildSvgEl('text', {
            x: lx, y: H - 4, 'text-anchor': 'middle', 'font-size': 8, fill: 'currentColor',
        });
        lab.textContent = String(labels[i] ?? '');
        svg.appendChild(lab);
    });

    attachChartTooltip(svg, (node) => {
        const i = Number(node.getAttribute('data-i'));
        const v = Number(node.getAttribute('data-v'));
        const tipLabel = node.getAttribute('data-tip-label') || '';
        if (tipKind === 'mc') {
            return `Master Option Number: ${i + 1}\nPercent Response: ${formatChartTick(v)}%`;
        }
        if (tipKind === 'tf') {
            return `Master Statement Number: ${i + 1}\nPercent Response: ${formatChartTick(v)}%`;
        }
        return `Score: ${tipLabel}\nPercent: ${formatChartTick(v)}%`;
    });
    return svg;
}

function renderMcTfResponseChart(qId, qType, numOptions, masterCorrect) {
    const graded = collectGradedAssnItems(qId);
    const counts = Array(numOptions).fill(0);
    for (const item of graded) {
        syncMasterAnswer(item, qType, numOptions);
        if (qType === 'multiple_choice') {
            const sm = item.master_answer;
            if (Number.isInteger(sm) && sm >= 0 && sm < numOptions) counts[sm] += 1;
        } else {
            const sm = item.master_answer;
            if (!Array.isArray(sm)) continue;
            for (let m = 0; m < numOptions; m++) {
                if (sm[m] === true) counts[m] += 1;
            }
        }
    }
    const n = graded.length || 1;
    const values = counts.map((c) => (100 * c) / n);
    const labels = Array.from({ length: numOptions }, (_, i) => String(i + 1));
    const correctSet = new Set();
    if (Array.isArray(masterCorrect)) masterCorrect.forEach((i) => correctSet.add(Number(i)));
    else if (Number.isInteger(masterCorrect)) correctSet.add(masterCorrect);
    return renderBarChartSvg({
        values,
        labels,
        correctSet: masterCorrect == null ? null : correctSet,
        tipKind: qType === 'multiple_choice' ? 'mc' : 'tf',
    });
}

function renderScoreHistogramChart(qId, maxPoints) {
    const scores = collectGradedAssnItems(qId)
        .map((q) => q.points)
        .filter((p) => typeof p === 'number' && Number.isFinite(p));
    const spec = computeHistogramSpec(scores, maxPoints);
    if (!spec) return null;
    const n = spec.graded || 1;
    const values = spec.counts.map((c) => (100 * c) / n);
    const tipLabels = values.map((_, i) => {
        const lo = spec.edges[i];
        if (i === spec.nBins - 1) return formatChartTick(lo);
        return `${formatChartTick(lo)}–${formatChartTick(spec.edges[i + 1])}`;
    });
    // Label each bar by its lower edge (last bar = max score).
    const labels = spec.edges.map((lo) => formatChartTick(lo));
    // At most 5 x-axis labels; blank the rest.
    if (spec.nBins > 5) {
        const keep = new Set(pickAxisTicks(0, spec.nBins - 1, 5).map((v) => Math.round(v)));
        for (let i = 0; i < labels.length; i++) {
            if (!keep.has(i)) labels[i] = '';
        }
    }
    return renderBarChartSvg({
        values,
        labels,
        tipLabels,
        correctSet: null,
        tipKind: 'hist',
    });
}

function mountResponseChart(hostEl, chartSvg) {
    if (!hostEl) return;
    hostEl.innerHTML = '';
    if (chartSvg) hostEl.appendChild(chartSvg);
}

function refreshScoreHistogram(optContainer, qId, maxPoints) {
    if (!(Number(maxPoints) > 0) || !optContainer) return;
    let row = optContainer.querySelector('.grade-stats-row.score-hist-row');
    if (!row) {
        row = document.createElement('div');
        row.className = 'grade-stats-row score-hist-row';
        const host = document.createElement('div');
        host.className = 'response-chart-host score-hist';
        row.appendChild(host);
        optContainer.insertBefore(row, optContainer.firstChild);
    }
    const host = row.querySelector('.response-chart-host');
    mountResponseChart(host, renderScoreHistogramChart(qId, maxPoints));
}

function renderBubbleLegend(bubbleContainer) {
    const legend = document.createElement('div');
    legend.classList.add('bubble-legend');
    const items = [
        { label: 'Correct', classes: ['correct'] },
        { label: 'Incorrect', classes: [] },
        { label: 'Detected', classes: ['detected'] },
        { label: 'Unknown', classes: ['unknown'] },
    ];
    for (const { label, classes } of items) {
        const item = document.createElement('div');
        item.classList.add('bubble-legend-item');
        item.appendChild(makeLegendBubble(...classes));
        item.appendChild(document.createTextNode(label));
        legend.appendChild(item);
    }
    bubbleContainer.appendChild(legend);
}

// Apply a grader click on one true/false statement. Clicking the value a statement already shows
// marks that statement unanswered; otherwise it overrides to the clicked value. The stored
// manual_answer holds null wherever the effective value matches detection, and the whole
// override is removed once nothing differs from detection.
function setTrueFalseStatement(currentItem, k, value) {
    const detected = currentItem.answer;
    const effective = trueFalseEffective(currentItem);
    effective[k] = (effective[k] === value) ? "unanswered" : value;
    const manual = effective.map((v, i) => (v === detected[i] ? null : v));
    if (manual.every(v => v === null)) {
        delete currentItem.manual_answer;
    } else {
        currentItem.manual_answer = manual;
    }
}

// Set a multiple-choice override. Re-clicking the current selection marks unanswered; selecting
// the detected value clears the override so only detection is stored.
function setMultipleChoiceAnswer(currentItem, k) {
    const detected = currentItem.answer;
    const effective = multipleChoiceEffective(currentItem);
    if (effective === k) {
        if (detected === "unanswered") {
            delete currentItem.manual_answer;
        } else {
            currentItem.manual_answer = "unanswered";
        }
    } else if (detected === k) {
        delete currentItem.manual_answer;
    } else {
        currentItem.manual_answer = k;
    }
}

function renderBubbles(optContainer, qType, currentItem, pts, numOptions) {
    const correctAnswer = currentItem?.correct_answer;
    const showKey = correctAnswer !== undefined && correctAnswer !== null;
    const points = (pts == null || pts === "") ? 0 : Number(pts);
    const detected = currentItem.answer;
    const effective = qType === 'multiple_choice'
        ? multipleChoiceEffective(currentItem)
        : trueFalseEffective(currentItem);
    const resolvedScore = qType === 'multiple_choice'
        ? gradeMultipleChoice(effective, correctAnswer, points)
        : gradeTrueFalse(effective, correctAnswer, points);
    if (resolvedScore !== null) {
        currentItem.points = resolvedScore;
        currentItem.is_graded = true;
    } else {
        delete currentItem.points;
        delete currentItem.is_graded;
    }
    syncMasterAnswer(currentItem, qType, numOptions);
    updateGradeDropdowns();

    let scoreEl = optContainer.querySelector('.score-container');
    const oldBubbleContainer = optContainer.querySelector('.bubble-container');
    if (oldBubbleContainer) oldBubbleContainer.remove();
    const bubbleContainer = document.createElement('div');
    bubbleContainer.classList.add('bubble-container');

    const statsRow = document.createElement('div');
    statsRow.classList.add('grade-stats-row');
    const chartHost = document.createElement('div');
    chartHost.classList.add('response-chart-host');
    const qId = questionIds[currentQIndex];
    const masterQ = questionsMap[qId]?.masterQ;
    // Participation (no points) still gets a chart; bars stay grey when there is no key.
    const masterCorrect = points > 0 ? (masterQ?.correct_answer ?? null) : null;
    mountResponseChart(chartHost, renderMcTfResponseChart(qId, qType, numOptions, masterCorrect));
    statsRow.appendChild(chartHost);
    const legendWrap = document.createElement('div');
    renderBubbleLegend(legendWrap);
    statsRow.appendChild(legendWrap);
    bubbleContainer.appendChild(statsRow);

    const perm = getOptionPermutation(currentItem, numOptions);
    if (qType === 'multiple_choice') {
        for (let k = 0; k < numOptions; k++) {
            const row = document.createElement('div');
            row.classList.add('bubble-row');
            const circle = makeBubble(showKey && correctAnswer === k, detected === "unknown", detected === k, effective === k);
            circle.onclick = () => {
                setMultipleChoiceAnswer(currentItem, k);
                renderBubbles(optContainer, qType, currentItem, pts, numOptions);
            };
            row.appendChild(circle);
            row.appendChild(document.createTextNode(`Master Option ${perm[k] + 1}`));
            bubbleContainer.appendChild(row);
        }
    } else if (qType === 'true_false') {
        const hr = document.createElement('div');
        hr.style.display = 'flex'; hr.style.gap = '20px';
        hr.innerHTML = `<span style="width:20px;text-align:center;">T</span><span style="width:20px;text-align:center;">F</span>`;
        bubbleContainer.appendChild(hr);
        for (let k = 0; k < numOptions; k++) {
            const detectionUnknown = detected[k] === "unknown";
            const row = document.createElement('div');
            row.classList.add('bubble-row');
            const tCircle = makeBubble(showKey && correctAnswer.includes(k), detectionUnknown, detected[k] === true, effective[k] === true);
            const fCircle = makeBubble(showKey && !correctAnswer.includes(k), detectionUnknown, detected[k] === false, effective[k] === false);
            tCircle.onclick = () => {
                setTrueFalseStatement(currentItem, k, true);
                renderBubbles(optContainer, qType, currentItem, pts, numOptions);
            };
            fCircle.onclick = () => {
                setTrueFalseStatement(currentItem, k, false);
                renderBubbles(optContainer, qType, currentItem, pts, numOptions);
            };
            row.appendChild(tCircle);
            row.appendChild(fCircle);
            row.appendChild(document.createTextNode(`Master Statement ${perm[k] + 1}`));
            bubbleContainer.appendChild(row);
        }
    }
    optContainer.insertBefore(bubbleContainer, scoreEl);
    if (scoreEl) {
        scoreEl.replaceWith(buildCurrentScoreRow({
            points,
            scoreValue: resolvedScore === null ? null : (Number.isInteger(resolvedScore) ? String(resolvedScore) : resolvedScore.toFixed(2)),
        }));
    } else {
        optContainer.appendChild(buildCurrentScoreRow({
            points,
            scoreValue: resolvedScore === null ? null : (Number.isInteger(resolvedScore) ? String(resolvedScore) : resolvedScore.toFixed(2)),
        }));
    }
}

function scoresEqual(a, b) {
    if (a == null || b == null) return false;
    return Number(a) === Number(b);
}

// Normalize a master-json rubric row into chip options for the grading UI.
// Supports legacy `{points, desc}` and newer `{desc, max, "0": "...", "<max>": "..."}` forms.
function parseRubricRow(entry, idx) {
    const desc = entry.desc || "";
    if (entry.max !== undefined) {
        const maxPoints = Number(entry.max);
        const options = Object.keys(entry)
            .filter(k => k !== "desc" && k !== "max")
            .map(k => ({ value: Number(k), label: String(entry[k]) }))
            .filter(o => Number.isFinite(o.value))
            .sort((a, b) => a.value - b.value);
        return { idx, desc, options, maxPoints, hasChipLabels: true };
    }
    const ptsArr = Array.isArray(entry.points) ? entry.points : [entry.points];
    const values = [0, ...ptsArr.map(Number).filter(v => v !== 0)];
    const unique = [...new Set(values)].sort((a, b) => a - b);
    const maxPoints = unique.length ? Math.max(...unique) : 0;
    return {
        idx,
        desc,
        options: unique.map(value => ({ value, label: null })),
        maxPoints,
        hasChipLabels: false,
    };
}

function buildCurrentScoreRow({ points, scoreValue = null, scoreInput = null, invalid = false, assignAllFullPoints = false }) {
    const wrap = document.createElement('div');
    wrap.classList.add('score-container');
    const label = document.createElement('span');
    label.classList.add('score-label');
    label.textContent = 'Score:';
    wrap.appendChild(label);
    if (scoreInput) {
        scoreInput.classList.add('score-input');
        scoreInput.classList.toggle('score-input-invalid', invalid);
        wrap.appendChild(scoreInput);
    } else {
        const value = document.createElement('span');
        value.classList.add('score-value');
        value.textContent = scoreValue == null ? '--' : String(scoreValue);
        wrap.appendChild(value);
    }
    const ptsInfo = document.createElement('span');
    ptsInfo.classList.add('score-points');
    ptsInfo.textContent = ` / ${points} points`;
    wrap.appendChild(ptsInfo);
    if (assignAllFullPoints) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.classList.add('score-full-points-btn');
        btn.textContent = 'Assign all students full points';
        btn.onclick = () => {
            const qid = questionIds[currentQIndex];
            const { assns } = questionsMap[qid] || {};
            const full = Number(points);
            if (!assns || !Number.isFinite(full)) return;
            Object.values(assns).forEach((item) => {
                item.points = full;
                item.is_graded = true;
                item.max_points = full;
            });
            if (scoreInput) {
                scoreInput.value = String(full);
                scoreInput.dispatchEvent(new Event('input', { bubbles: true }));
            }
            updateGradeDropdowns();
        };
        wrap.appendChild(btn);
    }
    if (invalid) {
        const msg = document.createElement('span');
        msg.classList.add('score-invalid-msg');
        msg.textContent = 'Score appears invalid';
        wrap.appendChild(msg);
    }
    return wrap;
}

function isScoreAboveMax(score, points) {
    return Number.isFinite(score) && score > points;
}

// Format a correct answer (string or list) for display in the grading panel.
function formatCorrectAnswerDisplay(answer) {
    if (answer == null) return null;
    if (Array.isArray(answer)) {
        if (answer.length === 0) return null;
        return answer.map((a, i) => `${i + 1}. ${a}`).join('\n');
    }
    const text = String(answer);
    return text.length ? text : null;
}

// For fill_blank / essay: prefer computed var_answer (from random params) over the static
// master correct_answer (which may still contain unevaluated Typst expressions).
function correctAnswerForDisplay(qType, currentItem) {
    if (qType !== 'fill_blank' && qType !== 'essay') return null;
    if (currentItem.var_answer !== undefined) return currentItem.var_answer;
    if (currentItem.correct_answer !== undefined) return currentItem.correct_answer;
    return null;
}

async function renderGradeStep() {
    updateGradeDropdowns();
    const { masterQ, assns } = questionsMap[questionIds[currentQIndex]];
    const currentAssnIdForQ = Object.keys(assns)[currentAssnIndexForQ]
    let currentItem = assns[currentAssnIdForQ];
    const qType = masterQ.type;
    const pts = masterQ?.points ?? null;
    // Keep question max_points aligned with the master (needed for feedback export).
    if (pts != null) currentItem.max_points = Number(pts);
    else delete currentItem.max_points;

    const infoEl = document.getElementById('question-info');
    infoEl.innerHTML = '';
    const isParticipation = (qType === 'multiple_choice' || qType === 'true_false')
        && (currentItem.correct_answer == null)
        && (masterQ.correct_answer == null);
    if (isParticipation) {
        const note = document.createElement('div');
        note.classList.add('participation-note');
        note.textContent = 'Participation question: any answer receives full credit; unanswered scores 0.';
        infoEl.appendChild(note);
    }
    const displayAnswer = formatCorrectAnswerDisplay(correctAnswerForDisplay(qType, currentItem));
    if (displayAnswer !== null) {
        const block = document.createElement('div');
        block.classList.add('correct-answer-block');
        const label = document.createElement('b');
        label.textContent = 'Correct Answer:';
        const text = document.createElement('pre');
        text.classList.add('correct-answer-text');
        text.textContent = displayAnswer;
        block.appendChild(label);
        block.appendChild(text);
        infoEl.appendChild(block);
    }
    setAssnScan(currentAssnIdForQ, currentItem.page, currentItem.q_height, false).catch(err => {
        console.error(err);
        showMessageModal({
            title: 'Error',
            message: `Could not load annotated scan for assn ${currentAssnIdForQ}: ${err.message || err}`,
        });
    });
    
    const optContainer = document.getElementById('grading-options');
    optContainer.innerHTML = '';
    
    if (qType === 'multiple_choice' || qType === 'true_false') {
        if (pts != null) currentItem.max_points = Number(pts);
        renderBubbles(optContainer, qType, currentItem, pts, masterQ.options.length);
    } else {
        if (masterQ.rubric) {
            const rubricRows = masterQ.rubric.map((entry, idx) => parseRubricRow(entry, idx));
            const rubricChipGap = 6;

            if (!("rubric" in currentItem)) {
                currentItem.rubric = rubricRows.map((row) => ({
                    desc: row.desc,
                    points: null,
                    max_points: row.maxPoints
                }));
            } else {
                // Refresh max_points/desc from master in case the rubric definition changed.
                rubricRows.forEach((row, i) => {
                    if (!currentItem.rubric[i]) return;
                    currentItem.rubric[i].max_points = row.maxPoints;
                    currentItem.rubric[i].desc = row.desc;
                });
            }

            const scoreSlot = document.createElement('div');

            const recomputeRubric = () => {
                if (currentItem.rubric.some(r => r?.points === null)) {
                    delete currentItem.is_graded;
                    delete currentItem.points;
                    scoreSlot.replaceChildren(buildCurrentScoreRow({ points: pts, scoreValue: null }));
                    updateGradeDropdowns();
                    refreshScoreHistogram(optContainer, questionIds[currentQIndex], pts);
                    return;
                }
                const total = currentItem.rubric.reduce((acc, r) => acc + (Number(r?.points) || 0), 0);
                currentItem.points = total;
                currentItem.is_graded = true;
                scoreSlot.replaceChildren(buildCurrentScoreRow({
                    points: pts,
                    scoreValue: Number.isInteger(total) ? String(total) : total.toFixed(2),
                }));
                updateGradeDropdowns();
                refreshScoreHistogram(optContainer, questionIds[currentQIndex], pts);
            };

            const rubricList = document.createElement('div');
            rubricList.classList.add('rubric-list');

            rubricRows.forEach((row, i) => {
                const desc = document.createElement('div');
                desc.classList.add('rubric-desc');
                desc.textContent = row.desc;

                const optionsWrap = document.createElement('div');
                optionsWrap.classList.add('rubric-options');
                optionsWrap.style.gap = `${rubricChipGap}px`;

                row.options.forEach(opt => {
                    const chip = document.createElement('div');
                    chip.classList.add('rubric-chip');
                    if (row.hasChipLabels) {
                        const scoreEl = document.createElement('div');
                        scoreEl.classList.add('rubric-chip-score');
                        scoreEl.textContent = String(opt.value);
                        const labelEl = document.createElement('div');
                        labelEl.classList.add('rubric-chip-label');
                        labelEl.textContent = opt.label;
                        chip.appendChild(scoreEl);
                        chip.appendChild(labelEl);
                    } else {
                        chip.textContent = String(opt.value);
                    }
                    if (scoresEqual(currentItem.rubric[i]?.points, opt.value)) {
                        chip.classList.add('selected');
                    }
                    chip.onclick = () => {
                        const isSelected = scoresEqual(currentItem.rubric[i].points, opt.value);
                        Array.from(optionsWrap.children).forEach(el => el.classList.remove('selected'));
                        if (isSelected) {
                            currentItem.rubric[i].points = null;
                        } else {
                            currentItem.rubric[i].points = opt.value;
                            chip.classList.add('selected');
                        }
                        recomputeRubric();
                    };
                    optionsWrap.appendChild(chip);
                });

                rubricList.appendChild(desc);
                rubricList.appendChild(optionsWrap);
            });

            optContainer.appendChild(rubricList);
            optContainer.appendChild(scoreSlot);
            recomputeRubric();
        } else {
            if (masterQ.points === undefined) {
                currentItem.points = currentItem.points !== undefined ? currentItem.points : 0;
                currentItem.is_graded = true;
                const label = document.createElement('div');
                label.textContent = "No points assigned for this question.";
                updateGradeDropdowns();
                optContainer.appendChild(label);
            } else {
                const scoreInput = document.createElement('input');
                scoreInput.type = 'number';
                scoreInput.id = 'score-input';
                scoreInput.min = '0';
                scoreInput.placeholder = '0';
                scoreInput.value = currentItem.points ?? "";
                if (pts != null) scoreInput.dataset.maxPoints = String(pts);
                // Block minus / negative entry; keep the field non-negative.
                scoreInput.addEventListener('keydown', (e) => {
                    if (e.key === '-' || e.key === 'Minus' || e.code === 'Minus' || e.code === 'NumpadSubtract') {
                        e.preventDefault();
                    }
                });
                scoreInput.addEventListener('beforeinput', (e) => {
                    if (e.data && e.data.includes('-')) e.preventDefault();
                });
                const invalidMsg = document.createElement('span');
                invalidMsg.classList.add('score-invalid-msg');
                invalidMsg.textContent = 'Score appears invalid';

                const syncManualScore = () => {
                    // Strip any minus that slipped through (paste, spinner, etc.).
                    if (scoreInput.value.includes('-')) {
                        scoreInput.value = scoreInput.value.replace(/-/g, '');
                    }
                    const raw = scoreInput.value;
                    const v = raw === "" ? undefined : parseFloat(raw);
                    let invalid = false;
                    if (v === undefined || Number.isNaN(v)) {
                        delete currentItem.points;
                        delete currentItem.is_graded;
                    } else {
                        currentItem.points = v;
                        currentItem.is_graded = true;
                        invalid = isScoreAboveMax(v, pts);
                    }
                    scoreInput.classList.toggle('score-input-invalid', invalid);
                    invalidMsg.classList.toggle('hidden', !invalid);
                    updateGradeDropdowns();
                    refreshScoreHistogram(optContainer, questionIds[currentQIndex], pts);
                };

                scoreInput.oninput = syncManualScore;
                const scoreRow = buildCurrentScoreRow({
                    points: pts,
                    scoreInput,
                    invalid: false,
                    assignAllFullPoints: qType === 'essay' || qType === 'fill_blank',
                });
                scoreRow.appendChild(invalidMsg);
                optContainer.appendChild(scoreRow);
                syncManualScore();
            }
        }
        if (pts != null && Number(pts) > 0) {
            refreshScoreHistogram(optContainer, questionIds[currentQIndex], pts);
        }
    }

    const divider = document.createElement('hr');
    divider.classList.add('grade-divider');
    optContainer.appendChild(divider);

    const qId = questionIds[currentQIndex];
    const feedbackWrap = document.createElement('div');
    feedbackWrap.classList.add("feedback-container")
    const feedbackLabel = document.createElement('div');
    feedbackLabel.textContent = "Feedback";
    feedbackLabel.classList.add("feedback-label");
    const feedbackInput = document.createElement('textarea');
    feedbackInput.id = `feedback-input-${currentQIndex}-${currentAssnIndexForQ}`;
    feedbackInput.classList.add("feedback-input");
    feedbackInput.value = currentItem.feedback || "";
    if (persistedFeedbackTextareaHeight) {
        feedbackInput.style.height = `${persistedFeedbackTextareaHeight}px`;
    }
    feedbackInput.oninput = (e) => {currentItem.feedback = e.target.value;};
    const persistFeedbackHeight = () => {
        const h = feedbackInput.getBoundingClientRect().height;
        if (h > 0) persistedFeedbackTextareaHeight = h;
    };
    feedbackInput.addEventListener('mouseup', persistFeedbackHeight);
    if (typeof ResizeObserver !== 'undefined') {
        new ResizeObserver(persistFeedbackHeight).observe(feedbackInput);
    }
    feedbackWrap.appendChild(feedbackLabel);
    feedbackWrap.appendChild(feedbackInput);
    if (typeof enhanceTypstMarkupFields === 'function') enhanceTypstMarkupFields(feedbackWrap);

    const saveTemplateBtn = document.createElement('button');
    saveTemplateBtn.type = 'button';
    saveTemplateBtn.classList.add('feedback-template-save');
    saveTemplateBtn.textContent = '+ add above feedback as template';
    saveTemplateBtn.onclick = () => {
        const text = feedbackInput.value;
        if (text === "") return;
        const templates = ensureFeedbackTemplates();
        if (!Array.isArray(templates[qId])) templates[qId] = [];
        if (!templates[qId].includes(text)) {
            templates[qId].push(text);
            renderFeedbackTemplateList(templateList, qId, feedbackInput, currentItem);
        }
    };

    const templateList = document.createElement('div');
    templateList.classList.add('feedback-template-list');
    renderFeedbackTemplateList(templateList, qId, feedbackInput, currentItem);

    feedbackWrap.appendChild(saveTemplateBtn);
    feedbackWrap.appendChild(templateList);
    optContainer.appendChild(feedbackWrap);

    // Empty manual score → focus it; otherwise stay in nav mode (sentinel).
    requestAnimationFrame(() => {
        const scoreInput = optContainer.querySelector('input.score-input');
        if (scoreInput && String(scoreInput.value).trim() === '') {
            scoreInput.focus({ preventScroll: true });
        } else {
            focusNavSentinel('grade-focus-sentinel');
        }
    });
}

function ensureFeedbackTemplates() {
    if (!gradingData["feedback-templates"] || typeof gradingData["feedback-templates"] !== "object" || Array.isArray(gradingData["feedback-templates"])) {
        gradingData["feedback-templates"] = {};
    }
    return gradingData["feedback-templates"];
}

function renderFeedbackTemplateList(listEl, qId, feedbackInput, currentItem) {
    listEl.innerHTML = '';
    const templates = ensureFeedbackTemplates()[qId];
    if (!Array.isArray(templates) || templates.length === 0) return;
    templates.forEach((text, index) => {
        const item = document.createElement('div');
        item.classList.add('feedback-template-item');

        const body = document.createElement('div');
        body.classList.add('feedback-template-text');
        body.textContent = text;

        const removeBtn = document.createElement('button');
        removeBtn.type = 'button';
        removeBtn.classList.add('feedback-template-remove');
        removeBtn.setAttribute('aria-label', 'Delete template');
        removeBtn.textContent = '×';
        removeBtn.onclick = (e) => {
            e.stopPropagation();
            const list = ensureFeedbackTemplates()[qId];
            if (!Array.isArray(list)) return;
            list.splice(index, 1);
            if (list.length === 0) delete ensureFeedbackTemplates()[qId];
            renderFeedbackTemplateList(listEl, qId, feedbackInput, currentItem);
        };

        item.onclick = () => {
            const applied = applyFeedbackTemplateName(text);
            feedbackInput.value = applied;
            currentItem.feedback = applied;
            feedbackInput.dispatchEvent(new Event('input', { bubbles: true }));
        };
        item.appendChild(body);
        item.appendChild(removeBtn);
        listEl.appendChild(item);
    });
}

let exportModalState = {
    detailedCsvPath: null,
    scoresCsvPath: null,
    feedbackDir: null,
    nameTrainingDir: null,
    driveCanUpload: false,
    driveNeedsAuthorization: false,
    driveMissing: [],
};

function closeExportModal() {
    document.getElementById('export-modal').classList.add('hidden');
}

function openExportModal() {
    document.getElementById('export-modal').classList.remove('hidden');
}

function setExportModalContent({ title, bodyHtml, actionsHtml = "", showClose = true }) {
    document.getElementById('export-modal-title').textContent = title;
    document.getElementById('export-modal-body').innerHTML = bodyHtml;
    document.getElementById('export-modal-actions').innerHTML = actionsHtml;
    const closeBtn = document.getElementById('export-modal-close');
    closeBtn.classList.toggle('hidden', !showClose);
    closeBtn.onclick = closeExportModal;
    openExportModal();
}

function showUngradedErrorModal(info) {
    const qId = String(info.questionId ?? "");
    const assnId = String(info.assnId ?? "");
    const qIdx = questionIds.indexOf(qId);
    if (qIdx >= 0) {
        currentQIndex = qIdx;
        const assnKeys = Object.keys(questionsMap[qId]?.assns || {});
        const aIdx = assnKeys.indexOf(assnId);
        currentAssnIndexForQ = aIdx >= 0 ? aIdx : 0;
        renderGradeStep();
    }
    setExportModalContent({
        title: "Cannot Finish & Export",
        bodyHtml: `
            <p>All questions must be graded before exporting.</p>
            <p>First ungraded question:</p>
            <ul>
                <li><strong>Question:</strong> ${info.questionId}</li>
                <li><strong>Assn ID:</strong> ${info.assnId}</li>
            </ul>
            <p>Grade that question, then run Finish &amp; Export again.</p>
        `,
        actionsHtml: "",
        showClose: true,
    });
}

function showExportResultModal() {
    const lines = [];
    if (exportModalState.detailedCsvPath) {
        lines.push(`Detailed scores CSV:\n${exportModalState.detailedCsvPath}`);
    }
    if (exportModalState.scoresCsvPath) {
        lines.push(`Scores CSV:\n${exportModalState.scoresCsvPath}`);
    }
    if (exportModalState.feedbackDir) {
        lines.push(`Scan feedback exported to:\n${exportModalState.feedbackDir}`);
    }
    if (exportModalState.nameTrainingDir) {
        lines.push(`Name training data exported to:\n${exportModalState.nameTrainingDir}`);
    }
    const bodyParts = [
        `<div class="path-block">${lines.join("\n\n")}</div>`,
        `<p>Upload feedback PDFs to Google Drive?</p>`,
    ];
    const canUpload = !!exportModalState.driveCanUpload && !!exportModalState.feedbackDir;
    const missing = Array.isArray(exportModalState.driveMissing) ? exportModalState.driveMissing.slice() : [];
    if (!exportModalState.feedbackDir) {
        missing.push("No feedback PDF export directory is available.");
    }
    const notes = [];
    if (canUpload && exportModalState.driveNeedsAuthorization) {
        notes.push("A browser window will open so you can link Google Drive (one-time). The app saves the token afterward.");
    }
    const missingHtml = (!canUpload && missing.length)
        ? `<p class="export-drive-missing">${missing.map((m) => escapeHtml(m)).join("<br>")}</p>`
        : "";
    const notesHtml = (canUpload && notes.length)
        ? `<p class="export-drive-missing">${notes.map((m) => escapeHtml(m)).join("<br>")}</p>`
        : "";
    const actionsHtml = `
        <button type="button" id="export-drive-yes"${canUpload ? "" : " disabled"}>Yes</button>
        <button type="button" id="export-drive-no">No</button>
        ${missingHtml}
        ${notesHtml}
    `;
    setExportModalContent({
        title: "Export Complete",
        bodyHtml: bodyParts.join(""),
        actionsHtml,
        showClose: true,
    });
    document.getElementById('export-drive-no').onclick = closeExportModal;
    const yesBtn = document.getElementById('export-drive-yes');
    if (canUpload) {
        yesBtn.onclick = runDriveUpload;
    }
}

async function runDriveUpload() {
    if (!exportModalState.feedbackDir) {
        setExportModalContent({
            title: "Upload Failed",
            bodyHtml: `<p>No feedback export directory is available to upload.</p>`,
            actionsHtml: "",
            showClose: true,
        });
        return;
    }

    let authAbort = null;
    try {
        if (exportModalState.driveNeedsAuthorization) {
            authAbort = new AbortController();
            setExportModalContent({
                title: "Link Google Drive…",
                bodyHtml: `<p>A browser window should open. Sign in and click Allow, then return here.</p>
                    <p>If you close the browser or change your mind, click Cancel.</p>`,
                actionsHtml: `<button type="button" id="export-drive-auth-cancel">Cancel</button>`,
                showClose: false,
            });
            document.getElementById('export-drive-auth-cancel').onclick = () => {
                authAbort.abort();
            };
            let authRes;
            try {
                authRes = await fetch('/api/authorize_google_drive', {
                    method: 'POST',
                    signal: authAbort.signal,
                });
            } catch (e) {
                if (e && e.name === 'AbortError') {
                    showExportResultModal();
                    return;
                }
                throw e;
            }
            let authData = {};
            try { authData = await authRes.json(); } catch (e) { /* fall through */ }
            if (!authRes.ok || authData.status !== "success") {
                setExportModalContent({
                    title: "Authorization Failed",
                    bodyHtml: `<p>${authData.message || "Could not link Google Drive."}</p>`,
                    actionsHtml: `<button type="button" id="export-drive-auth-back">Back</button>`,
                    showClose: true,
                });
                document.getElementById('export-drive-auth-back').onclick = showExportResultModal;
                return;
            }
            exportModalState.driveNeedsAuthorization = false;
        }

        setExportModalContent({
            title: "Checking Google Drive…",
            bodyHtml: `<p>Looking for existing files with the same assignment name…</p>`,
            actionsHtml: "",
            showClose: false,
        });

        const previewRes = await fetch('/api/drive_upload_preview', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ feedback_dir: exportModalState.feedbackDir }),
        });
        let previewData = {};
        try { previewData = await previewRes.json(); } catch (e) { /* fall through */ }
        if (!previewRes.ok || previewData.status !== "success") {
            setExportModalContent({
                title: "Upload Failed",
                bodyHtml: `<p>${previewData.message || "Could not preview Google Drive upload."}</p>`,
                actionsHtml: `<button type="button" id="export-drive-auth-back">Back</button>`,
                showClose: true,
            });
            document.getElementById('export-drive-auth-back').onclick = showExportResultModal;
            return;
        }

        const preview = previewData.preview || {};
        const conflicts = Array.isArray(preview.conflicts) ? preview.conflicts : [];
        if (conflicts.length > 0) {
            const conflictLines = conflicts.slice(0, 12).map((c) =>
                `- ${c.file} → ${c.drive_filename || preview.target_filename || ""}`
            );
            if (conflicts.length > 12) {
                conflictLines.push(`…and ${conflicts.length - 12} more`);
            }
            setExportModalContent({
                title: "Existing Files Found",
                bodyHtml: `
                    <p><strong>${conflicts.length}</strong> student folder(s) already have
                    <code>${escapeHtml(preview.target_filename || "this assignment")}</code>.</p>
                    <div class="upload-summary">${conflictLines.map(escapeHtml).join("\n")}</div>
                    <p>How should duplicates be handled?</p>
                `,
                actionsHtml: `
                    <button type="button" id="export-drive-replace">Replace</button>
                    <button type="button" id="export-drive-skip">Skip existing</button>
                    <button type="button" id="export-drive-add-new">Keep both (add new)</button>
                    <button type="button" id="export-drive-dup-cancel">Cancel</button>
                `,
                showClose: true,
            });
            document.getElementById('export-drive-replace').onclick = () => startDriveUploadWithPolicy('replace');
            document.getElementById('export-drive-skip').onclick = () => startDriveUploadWithPolicy('skip');
            document.getElementById('export-drive-add-new').onclick = () => startDriveUploadWithPolicy('add_new');
            document.getElementById('export-drive-dup-cancel').onclick = showExportResultModal;
            return;
        }

        startDriveUploadWithPolicy('add_new');
    } catch (e) {
        if (e && e.name === 'AbortError') {
            showExportResultModal();
            return;
        }
        setExportModalContent({
            title: "Upload Failed",
            bodyHtml: `<p>Failed to upload feedback to Google Drive.</p>`,
            actionsHtml: "",
            showClose: true,
        });
    }
}

function startDriveUploadWithPolicy(duplicatePolicy) {
    setExportModalContent({
        title: "Uploading to Google Drive…",
        bodyHtml: `<pre class="upload-summary" id="export-drive-log" style="min-height: 12em;"></pre>`,
        actionsHtml: `<button type="button" id="export-drive-upload-cancel">Cancel</button>`,
        showClose: false,
    });
    const logEl = document.getElementById('export-drive-log');
    let summaryPayload = null;
    const ws = new WebSocket(`ws://${location.host}/api/ws_upload_drive`);
    const appendLog = (text) => {
        if (!logEl) return;
        logEl.textContent += text;
        logEl.scrollTop = logEl.scrollHeight;
    };
    document.getElementById('export-drive-upload-cancel').onclick = () => {
        try { ws.close(1000, "Cancelled"); } catch (e) { /* ignore */ }
        showExportResultModal();
    };
    ws.onopen = () => {
        ws.send(JSON.stringify({
            feedback_dir: exportModalState.feedbackDir,
            duplicate_policy: duplicatePolicy,
        }));
    };
    ws.onmessage = (event) => {
        const raw = String(event.data);
        let sawDone = false;
        for (const line of raw.split("\n")) {
            if (!line) continue;
            if (line.startsWith("SUMMARY:")) {
                try {
                    summaryPayload = JSON.parse(line.slice("SUMMARY:".length));
                } catch (e) {
                    appendLog(line + "\n");
                }
                continue;
            }
            if (line.trim() === "Done") {
                sawDone = true;
                continue;
            }
            appendLog(line + "\n");
        }
        if (sawDone) {
            try { ws.close(1000, "Run complete"); } catch (e) { /* ignore */ }
            if (summaryPayload && summaryPayload.status === "success") {
                refreshDetailedCsvAfterDriveUpload().finally(() => {
                    showDriveUploadSummary(summaryPayload);
                });
            } else {
                setExportModalContent({
                    title: "Upload Failed",
                    bodyHtml: `<p>Google Drive upload did not complete successfully.</p>
                        <pre class="upload-summary">${escapeHtml(logEl ? logEl.textContent : "")}</pre>`,
                    actionsHtml: "",
                    showClose: true,
                });
            }
        }
    };
    ws.onerror = () => {
        appendLog("\nWebSocket Error\n");
    };
    ws.onclose = () => {
        // Summary handling is done when Done is received.
    };
}

async function refreshDetailedCsvAfterDriveUpload() {
    try {
        const csvRes = await fetch('/api/export_csv', { method: 'POST' });
        let csvData = {};
        try { csvData = await csvRes.json(); } catch (e) { /* ignore */ }
        if (csvRes.ok && csvData.status === "success") {
            exportModalState.detailedCsvPath = csvData.detailed_csv_path || exportModalState.detailedCsvPath;
            exportModalState.scoresCsvPath = csvData.scores_csv_path || exportModalState.scoresCsvPath;
        }
    } catch (e) { /* keep the CSV written before upload */ }
}

function showDriveUploadSummary(data) {
    const summary = data.summary || {};
    const uploaded = Array.isArray(summary.uploaded) ? summary.uploaded : [];
    const skippedNoEmail = Array.isArray(summary.skipped_no_email) ? summary.skipped_no_email : [];
    const skippedDup = Array.isArray(summary.skipped_duplicate) ? summary.skipped_duplicate : [];
    const failed = Array.isArray(summary.failed) ? summary.failed : [];
    const total = summary.total_pdfs ?? (uploaded.length + skippedNoEmail.length + skippedDup.length + failed.length);
    const lines = [];
    if (data.class_name || data.assn_type || data.assn_name) {
        lines.push(
            `Class: ${data.class_name || summary.class_name || "(unknown)"}`,
            `Type: ${data.assn_type || "(unknown)"}`,
            `Name: ${data.assn_name || "(unknown)"}`,
            "",
        );
    }
    lines.push(`Uploaded ${uploaded.length} of ${total} PDF(s).`);
    if (uploaded.length) {
        lines.push("", "Succeeded:");
        for (const item of uploaded) {
            lines.push(`- ${item.file} → ${item.email || item.name || ""}`);
        }
    }
    if (skippedNoEmail.length) {
        lines.push("", "Skipped - No Email:");
        for (const item of skippedNoEmail) {
            lines.push(`- ${item.file}${item.name ? ` (${item.name})` : ""}`);
        }
    }
    if (skippedDup.length) {
        lines.push("", "Skipped - Already Exists:");
        for (const item of skippedDup) {
            lines.push(`- ${item.file}${item.name ? ` (${item.name})` : ""}`);
        }
    }
    if (failed.length) {
        lines.push("", "Failed:");
        for (const item of failed) {
            lines.push(`- ${item.file}: ${item.error || "unknown error"}`);
        }
    }
    setExportModalContent({
        title: "Google Drive Upload Summary",
        bodyHtml: `<div class="upload-summary">${lines.join("\n")}</div>`,
        actionsHtml: "",
        showClose: true,
    });
}

function setFinishExportLoading(isLoading) {
    const btn = document.getElementById('finish-export-btn');
    const spinner = document.getElementById('finish-export-spinner');
    const label = document.getElementById('finish-export-label');
    if (!btn || !spinner || !label) return;
    btn.disabled = isLoading;
    spinner.classList.toggle('hidden', !isLoading);
    label.textContent = isLoading ? "Exporting..." : "Finish & Export";
}

async function finishGrading() {
    const ungraded = findFirstUngradedQuestion();
    if (ungraded) {
        showUngradedErrorModal(ungraded);
        return;
    }

    setFinishExportLoading(true);
    try {
        await commitCurrentGradingData();

        exportModalState = {
            detailedCsvPath: null,
            scoresCsvPath: null,
            feedbackDir: null,
            nameTrainingDir: null,
            driveCanUpload: false,
            driveNeedsAuthorization: false,
            driveMissing: [],
        };
        const errors = [];

        try {
            const csvRes = await fetch('/api/export_csv', { method: 'POST' });
            let csvData = {};
            try { csvData = await csvRes.json(); } catch (e) { /* fall through */ }
            if (csvRes.ok && csvData.status === "success") {
                exportModalState.detailedCsvPath = csvData.detailed_csv_path || null;
                exportModalState.scoresCsvPath = csvData.scores_csv_path || null;
            } else {
                errors.push(csvData.message || "Failed to export CSV.");
            }
        } catch (e) {
            errors.push("Failed to export CSV.");
        }

        try {
            const fbRes = await fetch('/api/export_feedback', { method: 'POST' });
            let fbData = {};
            try { fbData = await fbRes.json(); } catch (e) { /* fall through */ }
            if (fbRes.ok && fbData.status === "success") {
                exportModalState.feedbackDir = fbData.output_dir;
            } else {
                errors.push(fbData.message || "Failed to export feedback PDFs.");
            }
        } catch (e) {
            errors.push("Failed to export feedback PDFs.");
        }

        try {
            const ntRes = await fetch('/api/export_name_training_data', { method: 'POST' });
            let ntData = {};
            try { ntData = await ntRes.json(); } catch (e) { /* fall through */ }
            if (ntRes.ok && ntData.status === "success") {
                exportModalState.nameTrainingDir = ntData.output_dir || null;
            } else {
                errors.push(ntData.message || "Failed to export name training data.");
            }
        } catch (e) {
            errors.push("Failed to export name training data.");
        }

        if (errors.length && !exportModalState.detailedCsvPath && !exportModalState.scoresCsvPath && !exportModalState.feedbackDir && !exportModalState.nameTrainingDir) {
            setExportModalContent({
                title: "Export Failed",
                bodyHtml: `<p>${errors.join("</p><p>")}</p>`,
                actionsHtml: "",
                showClose: true,
            });
            return;
        }

        try {
            const credRes = await fetch('/api/drive_credentials_status');
            let credData = {};
            try { credData = await credRes.json(); } catch (e) { /* fall through */ }
            if (credRes.ok && credData.status === "success") {
                exportModalState.driveCanUpload = !!credData.can_upload;
                exportModalState.driveNeedsAuthorization = !!credData.needs_authorization;
                exportModalState.driveMissing = Array.isArray(credData.missing) ? credData.missing : [];
            } else {
                exportModalState.driveCanUpload = false;
                exportModalState.driveNeedsAuthorization = false;
                exportModalState.driveMissing = ["Could not check Google Drive upload requirements."];
            }
        } catch (e) {
            exportModalState.driveCanUpload = false;
            exportModalState.driveNeedsAuthorization = false;
            exportModalState.driveMissing = ["Could not check Google Drive upload requirements."];
        }

        showExportResultModal();
        if (errors.length) {
            const body = document.getElementById('export-modal-body');
            const note = document.createElement('p');
            note.textContent = errors.join(" ");
            body.prepend(note);
        }
    } finally {
        setFinishExportLoading(false);
    }
}

// Toggle the loading state on both Save Work buttons (one per grading step). Only one is visible at
// a time, so updating both is harmless and keeps whichever is on screen in sync.
function setSaveWorkLoading(isLoading) {
    for (const suffix of ['assign', 'grade']) {
        const btn = document.getElementById(`save-work-btn-${suffix}`);
        const spinner = document.getElementById(`save-work-spinner-${suffix}`);
        const label = document.getElementById(`save-work-label-${suffix}`);
        if (!btn || !spinner || !label) continue;
        btn.disabled = isLoading;
        spinner.classList.toggle('hidden', !isLoading);
        label.textContent = isLoading ? "Saving..." : "Save Work";
    }
}

// Persist the current grading data into the unpacked archive (temp dir), then recompress that dir
// back over the .assn file so the saved work is durable on disk immediately.
async function saveWork() {
    setSaveWorkLoading(true);
    let message = "Work saved to .assn file.";
    try {
        const commitRes = await commitCurrentGradingData();
        let commitData = {};
        try { commitData = await commitRes.json(); } catch (e) { /* fall through to error message */ }
        if (!commitRes.ok || commitData.status !== "success") {
            message = commitData.message || "Failed to save work.";
        } else {
            const res = await fetch('/api/save_archive', { method: 'POST' });
            let data = {};
            try { data = await res.json(); } catch (e) { /* fall through to error message */ }
            message = (res.ok && data.status === "success")
                ? "Work saved to .assn file."
                : (data.message || "Failed to save work to .assn file.");
        }
    } catch (e) {
        message = "Failed to save work.";
    } finally {
        setSaveWorkLoading(false);
    }
    showMessageModal({
        title: message.toLowerCase().includes('fail') ? 'Error' : 'Saved',
        message,
    });
}
