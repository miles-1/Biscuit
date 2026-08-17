// Helpers shared by both grading steps: persisting work, the status-dropdown widget, and the
// master-question flattener.

// Migrate legacy score field names to points / max_points (question + rubric rows).
function migrateGradingDataScoreFields(data) {
    if (!data || typeof data !== "object") return;
    for (const [key, entry] of Object.entries(data)) {
        if (key === "feedback-templates" || !entry || !Array.isArray(entry.questions)) continue;
        for (const q of entry.questions) {
            if (Object.prototype.hasOwnProperty.call(q, "score")) {
                if (!Object.prototype.hasOwnProperty.call(q, "points")) q.points = q.score;
                delete q.score;
            }
            if (!Array.isArray(q.rubric)) continue;
            for (const row of q.rubric) {
                if (Object.prototype.hasOwnProperty.call(row, "selected_score")) {
                    if (!Object.prototype.hasOwnProperty.call(row, "points")) row.points = row.selected_score;
                    delete row.selected_score;
                }
                if (Object.prototype.hasOwnProperty.call(row, "total_possible_score")) {
                    if (!Object.prototype.hasOwnProperty.call(row, "max_points")) row.max_points = row.total_possible_score;
                    delete row.total_possible_score;
                }
            }
        }
    }
}

// Keep assignment-level totals in sync for feedback export
// (total_points / max_total_points on each assn entry).
function refreshAssnPointTotals() {
    for (const [key, entry] of Object.entries(gradingData)) {
        if (key === "feedback-templates" || !entry || !Array.isArray(entry.questions)) continue;
        // Migrate legacy assn-level max_points → max_total_points.
        if (Object.prototype.hasOwnProperty.call(entry, "max_points")
            && !Object.prototype.hasOwnProperty.call(entry, "max_total_points")) {
            entry.max_total_points = entry.max_points;
        }
        delete entry.max_points;
        let total = 0;
        let max = 0;
        let hasScored = false;
        let hasMax = false;
        for (const q of entry.questions) {
            // Questions without max_points are unscored / not part of the assignment total.
            if (typeof q.max_points !== "number" || !Number.isFinite(q.max_points)) continue;
            max += q.max_points;
            hasMax = true;
            if (typeof q.points === "number" && Number.isFinite(q.points)) {
                total += q.points;
                hasScored = true;
            }
        }
        if (hasScored) entry.total_points = total;
        else delete entry.total_points;
        if (hasMax) entry.max_total_points = max;
        else delete entry.max_total_points;
    }
}

// Returns {assnId, questionId, studentName} for the first unscored question that has
// max_points but is not graded, or null. Questions without max_points are skipped.
function findFirstUngradedQuestion() {
    const assnIds = Object.keys(gradingData)
        .filter(k => k !== "feedback-templates" && Array.isArray(gradingData[k]?.questions))
        .sort((a, b) => Number(a) - Number(b));
    for (const assnId of assnIds) {
        const entry = gradingData[assnId];
        for (const q of entry.questions) {
            if (typeof q.max_points !== "number" || !Number.isFinite(q.max_points)) continue;
            if (q?.is_graded !== true) {
                return {
                    assnId,
                    questionId: q?.id ?? "(unknown)",
                    studentName: entry.name || "(unassigned)",
                };
            }
        }
    }
    return null;
}

function commitCurrentGradingData() {
    refreshAssnPointTotals();
    return fetch('/api/save_grading_data', {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(gradingData)})
}

function getStatusIconSrc(isComplete) {
    return isComplete ? GREEN_CHECK_SVG : ORANGE_CIRCLE_SVG;
}

function renderStatusDropdown(containerId, items, selectedIndex, onSelect) {
    const container = document.getElementById(containerId);
    container.innerHTML = '';
    if (!items.length) return;

    const wrapper = document.createElement('div');
    wrapper.className = 'status-dropdown';

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'status-dropdown-btn';

    const selected = items[Math.max(0, Math.min(selectedIndex, items.length - 1))];
    btn.innerHTML = `
        <span style="display:flex;align-items:center;gap:8px;">
            <img class="status-icon" src="${getStatusIconSrc(selected.isComplete)}" alt="">
            <span>${selected.label}</span>
            <span style="margin-left:auto;">▾</span>
        </span>
    `;

    const menu = document.createElement('div');
    menu.className = 'status-dropdown-menu hidden';

    items.forEach((item, index) => {
        const row = document.createElement('div');
        row.className = 'status-dropdown-item';
        row.innerHTML = `
            <img class="status-icon" src="${getStatusIconSrc(item.isComplete)}" alt="">
            <span>${item.label}</span>
        `;
        row.onclick = () => {
            onSelect(index);
            menu.classList.add('hidden');
        };
        menu.appendChild(row);
    });

    btn.onclick = (e) => {
        e.stopPropagation();
        document.querySelectorAll('.status-dropdown-menu').forEach(m => {
            if (m !== menu) m.classList.add('hidden');
        });
        menu.classList.toggle('hidden');
    };

    wrapper.appendChild(btn);
    wrapper.appendChild(menu);
    container.appendChild(wrapper);
}

function flattenQuestions(questions, qPath = "") {
    let result = {};
    for (let i = 0; i < questions.length; i++) {
        const q = questions[i];
        const newPath = qPath === "" ? String(i) : `${qPath}.${i}`;
        if (q.questions) {
            Object.assign(result, flattenQuestions(q.questions, newPath))
        } else {
            result["q" + newPath] = q;
        }
    }
    return result;
}

function isFormFieldFocused() {
    const el = document.activeElement;
    if (!el) return false;
    const tag = el.tagName;
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable;
}

function isSectionVisible(el) {
    return !!(el && !el.classList.contains('hidden'));
}

function focusNavSentinel(sentinelId) {
    const el = document.getElementById(sentinelId);
    if (el) el.focus({ preventScroll: true });
}

function fillScoreInputMaxPoints() {
    const scoreInput = document.getElementById('score-input');
    if (!scoreInput) return;
    const maxRaw = scoreInput.dataset.maxPoints;
    if (maxRaw === undefined || maxRaw === '') return;
    scoreInput.value = String(maxRaw);
    scoreInput.dispatchEvent(new Event('input', { bubbles: true }));
    scoreInput.focus({ preventScroll: true });
}

// Fields for the trapped Tab cycle in the active workspace, or null if none.
function getActiveTabCycleFields() {
    const verifySec = document.getElementById('verify-sec');
    if (isSectionVisible(verifySec)) {
        return [
            document.getElementById('verify-assn-id'),
            document.getElementById('verify-page-num'),
            document.getElementById('verify-focus-sentinel'),
        ].filter(Boolean);
    }
    if (isSectionVisible(gradingUI) && isSectionVisible(gradeStep1)) {
        return [
            document.getElementById('student-name-input'),
            document.getElementById('assign-focus-sentinel'),
        ].filter(Boolean);
    }
    if (isSectionVisible(gradingUI) && isSectionVisible(gradeStep2)) {
        const fields = [];
        const score = document.getElementById('score-input')
            || document.querySelector('#grading-options input.score-input');
        const feedback = document.querySelector('#grading-options textarea.feedback-input');
        if (score) fields.push(score);
        if (feedback) fields.push(feedback);
        const sentinel = document.getElementById('grade-focus-sentinel');
        if (sentinel) fields.push(sentinel);
        return fields;
    }
    return null;
}

// Shared arrow-key navigation for verify + both grading steps.
document.addEventListener('keydown', function(e) {
    if (isFormFieldFocused()) {
        // Full credit shortcut when a manual score field is present.
        if ((e.key === 'f' || e.key === 'F')
            && isSectionVisible(gradingUI)
            && isSectionVisible(gradeStep2)
            && document.activeElement
            && document.activeElement.id === 'score-input') {
            e.preventDefault();
            fillScoreInputMaxPoints();
        }
        return;
    }
    if ((e.key === 'f' || e.key === 'F')
        && isSectionVisible(gradingUI)
        && isSectionVisible(gradeStep2)
        && document.getElementById('score-input')) {
        e.preventDefault();
        fillScoreInputMaxPoints();
        return;
    }
    const verifySec = document.getElementById('verify-sec');
    if (isSectionVisible(verifySec)) {
        if (e.key === 'ArrowLeft') { e.preventDefault(); prevVerifyPage(); }
        else if (e.key === 'ArrowRight') { e.preventDefault(); nextVerifyPage(); }
        return;
    }
    if (isSectionVisible(gradingUI) && isSectionVisible(gradeStep1)) {
        if (e.key === 'ArrowLeft') prevAssn();
        else if (e.key === 'ArrowRight') nextAssn();
        return;
    }
    if (isSectionVisible(gradingUI) && isSectionVisible(gradeStep2)) {
        if (e.key === 'ArrowLeft') prevGradeAssn();
        else if (e.key === 'ArrowRight') nextGradeAssn();
        else if (e.key === 'ArrowUp') prevQ();
        else if (e.key === 'ArrowDown') nextQ();
    }
});

// Trap Tab inside the short verify / grade-question field cycles.
document.addEventListener('keydown', function(e) {
    if (e.key !== 'Tab') return;
    const fields = getActiveTabCycleFields();
    if (!fields || fields.length === 0) return;
    e.preventDefault();
    const active = document.activeElement;
    let idx = fields.indexOf(active);
    if (idx < 0) idx = e.shiftKey ? 0 : -1;
    const next = e.shiftKey
        ? (idx - 1 + fields.length) % fields.length
        : (idx + 1) % fields.length;
    fields[next].focus({ preventScroll: true });
}, true);
