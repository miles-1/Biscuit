// Grade Assignments - Assign Names step: starting a grading session, navigating assns, and the
// student-name autocomplete. Arrow-key navigation lives in app-grade-shared.js.

async function startGrading() {
    setStartGradingLoading(true);
    const assnPath = document.getElementById('grade-assn-path').value;
    async function uploadGradeContext({ useExistingTmp = false, replaceExistingTmp = false } = {}) {
        const setupRes = await fetch('/api/upload_grade_context', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({
                assn_file: assnPath,
                use_existing_tmp: useExistingTmp,
                replace_existing_tmp: replaceExistingTmp
            })
        });
        return setupRes.json();
    }
    try {
        let setupData = await uploadGradeContext();
        if (setupData.status === "confirm_existing_tmp") {
            const choice = await pickExistingTmpOption(setupData.message);
            if (choice === "cancel") {
                return;
            }
            if (choice === "load_existing") {
                setupData = await uploadGradeContext({ useExistingTmp: true });
            } else if (choice === "replace_existing") {
                setupData = await uploadGradeContext({ replaceExistingTmp: true });
            }
        }
        if (setupData.status !== "success") {
            showMessageModal({
                title: 'Error',
                message: setupData.message || "Failed to initialize grading context.",
            });
            return;
        }
        gradingData = setupData.grading_data || {};
        migrateGradingDataScoreFields(gradingData);
        bustScanImageCache();
        if (!gradingData["feedback-templates"] || typeof gradingData["feedback-templates"] !== "object") {
            gradingData["feedback-templates"] = {};
        }
        // Assn entries are numeric keys; skip top-level metadata like feedback-templates.
        assnIds = Object.keys(gradingData)
            .filter(k => k !== "feedback-templates" && gradingData[k]?.questions)
            .map(Number)
            .sort((a, b) => a - b);
        const [studentsRes, masterRes] = await Promise.all([
            fetch('/api/get_students'),
            fetch('/api/get_master_json'),
        ]);
        const [studentsPayload, masterPayload] = await Promise.all([
            studentsRes.json(),
            masterRes.json(),
        ]);
        studentsList = studentsPayload.students || [];
        masterQuestions = flattenQuestions(masterPayload.master?.questions || []);
        showSection('grading-ui');
        gradeStep1.classList.remove('hidden');
        gradeStep2.classList.add('hidden');
        currentAssnIndex = 0;
        renderAssignStep();
    } finally {
        setStartGradingLoading(false);
    }
}

function updateAssignDropdown() {
    const items = assnIds.map(t => ({
        label: `Assn ${t}`,
        isComplete: "name" in gradingData[t]
    }));
    renderStatusDropdown('assign-assn-dropdown', items, currentAssnIndex, jumpToAssignAssn);
    document.getElementById('btn-prev-assn-assign').disabled = (currentAssnIndex <= 0);
    document.getElementById('btn-next-assn-assign').disabled = (currentAssnIndex >= assnIds.length - 1);
}

function clearAssignNameWarning() {
    const warning = document.getElementById('assign-name-warning');
    if (warning) {
        warning.textContent = '';
        warning.style.color = '';
    }
    if (input) input.style.outline = '';
}

function showAssignNameWarning() {
    const warning = document.getElementById('assign-name-warning');
    if (warning) {
        warning.style.color = '#b45309';
        warning.textContent = 'Warning: a name is being used that does not appear in the student csv.';
    }
    if (input) input.style.outline = '2px solid #f59e0b';
}

function nameIsInStudentList(name) {
    const norm = name.toLowerCase();
    return studentsList.some((s) => String(s).toLowerCase() === norm);
}

function renderAssignStep() {
    if (assnIds.length === 0) return;
    const assnId = assnIds[currentAssnIndex];
    setAssnScan(assnId, 1, 0, true).catch(err => {
        console.error(err);
        showMessageModal({
            title: 'Error',
            message: `Could not load annotated scan for assn ${assnId}: ${err.message || err}`,
        });
    });
    document.getElementById('assign-assn-id').textContent = assnId;
    const nameInput = document.getElementById('student-name-input');
    nameInput.value = gradingData[assnId]?.name || "";
    clearAssignNameWarning();
    updateAssignDropdown();
    if (!String(nameInput.value || '').trim()) {
        nameInput.focus({ preventScroll: true });
    } else {
        focusNavSentinel('assign-focus-sentinel');
    }
}

function jumpToAssignAssn(index) { currentAssnIndex = parseInt(index); renderAssignStep(); }
function prevAssn() { if (currentAssnIndex > 0) { currentAssnIndex--; renderAssignStep(); } }
function nextAssn() { if (currentAssnIndex < assnIds.length - 1) { currentAssnIndex++; renderAssignStep(); } }

async function assignCurrentName() {
    const name = document.getElementById('student-name-input').value.trim();
    if (!name) return;
    for (let t of assnIds) {
        if (gradingData[t]?.name === name) delete gradingData[t].name;
    }
    const assnId = assnIds[currentAssnIndex];
    gradingData[assnId].name = name;
    updateAssignDropdown();

    // No student csv → assign and advance. With csv, unknown names still assign but warn and stay.
    if (studentsList.length > 0 && !nameIsInStudentList(name)) {
        showAssignNameWarning();
        input.blur();
        focusNavSentinel('assign-focus-sentinel');
        return;
    }

    clearAssignNameWarning();
    nextAssn();
}

function renderStudentSuggestions(val = "") {
    const list = document.getElementById('autocomplete-list');
    list.innerHTML = '';
    if (!studentsList.length) {
        currentSuggestions = [];
        highlightedSuggestionIndex = -1;
        return;
    }
    const usedNames = Object.values(gradingData).filter(d => d?.name).map(d => d.name);
    const normVal = (val || "").toLowerCase();
    const matches = studentsList.filter(s => !normVal || s.toLowerCase().includes(normVal));
    matches.sort((a, b) => {
        const aUsed = usedNames.includes(a);
        const bUsed = usedNames.includes(b);
        if (aUsed && !bUsed) return 1;
        if (!aUsed && bUsed) return -1;
        return a.localeCompare(b, undefined, { sensitivity: 'base' });
    });
    currentSuggestions = matches;
    highlightedSuggestionIndex = matches.length ? 0 : -1;

    for (let i = 0; i < matches.length; i++) {
        const m = matches[i];
        const div = document.createElement('div');
        div.innerHTML = m;
        if (i === highlightedSuggestionIndex) {
            div.classList.add('active');
        }
        if (usedNames.includes(m)) {
            div.style.color = 'gray';
            div.style.textDecoration = 'line-through';
            const prevAssn = Object.keys(gradingData).find(k => gradingData[k]?.name === m);
            div.innerHTML += ` (Assigned to Assn ${prevAssn})`;
        }
        div.onclick = function() {
            input.value = m;
            list.innerHTML = '';
            assignCurrentName();
        };
        list.appendChild(div);
    }
}

function refreshSuggestionHighlight() {
    const list = document.getElementById('autocomplete-list');
    const rows = list.querySelectorAll('div');
    rows.forEach((row, idx) => row.classList.toggle('active', idx === highlightedSuggestionIndex));
}

input.addEventListener('input', function() {
    clearAssignNameWarning();
    renderStudentSuggestions(this.value);
});
input.addEventListener('focus', function() {
    clearAssignNameWarning();
    renderStudentSuggestions(this.value);
});
selectAllOnFirstClick(input);
input.addEventListener('keydown', function(e) {
    if (e.key === 'ArrowDown') {
        if (!currentSuggestions.length) return;
        e.preventDefault();
        highlightedSuggestionIndex = (highlightedSuggestionIndex + 1) % currentSuggestions.length;
        input.value = currentSuggestions[highlightedSuggestionIndex];
        refreshSuggestionHighlight();
    } else if (e.key === 'ArrowUp') {
        if (!currentSuggestions.length) return;
        e.preventDefault();
        highlightedSuggestionIndex = (highlightedSuggestionIndex - 1 + currentSuggestions.length) % currentSuggestions.length;
        input.value = currentSuggestions[highlightedSuggestionIndex];
        refreshSuggestionHighlight();
    } else if (e.key === 'Enter') {
        e.preventDefault();
        if (currentSuggestions.length && highlightedSuggestionIndex >= 0) {
            input.value = currentSuggestions[highlightedSuggestionIndex];
        }
        assignCurrentName();
        document.getElementById('autocomplete-list').innerHTML = '';
        currentSuggestions = [];
        highlightedSuggestionIndex = -1;
    }
});
document.addEventListener('click', function (e) {
    if (e.target !== input) {
        document.getElementById('autocomplete-list').innerHTML = '';
        currentSuggestions = [];
        highlightedSuggestionIndex = -1;
    }
    if (!e.target.closest('.status-dropdown')) {
        document.querySelectorAll('.status-dropdown-menu').forEach(m => m.classList.add('hidden'));
    }
});
