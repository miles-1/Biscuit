// Classes manager modal + Create Assignment class dropdown.

let classesCache = [];

function openHelpModal() {
    const modal = document.getElementById('help-modal');
    if (modal) modal.classList.remove('hidden');
}

function closeHelpModal() {
    const modal = document.getElementById('help-modal');
    if (modal) modal.classList.add('hidden');
}

function openClassesModal() {
    const modal = document.getElementById('classes-modal');
    if (!modal) return;
    modal.classList.remove('hidden');
    refreshClassesUi();
}

function closeClassesModal() {
    const modal = document.getElementById('classes-modal');
    if (modal) modal.classList.add('hidden');
    refreshClassSelect();
}

function downloadLog() {
    window.location.href = '/api/download_log';
}

function setClassesStatus(message, isError = false) {
    const el = document.getElementById('classes-modal-status');
    if (!el) return;
    el.textContent = message || '';
    el.classList.toggle('error', !!isError);
}

function formatLastEdited(isoLike) {
    if (!isoLike) return '—';
    const d = new Date(isoLike);
    if (Number.isNaN(d.getTime())) return String(isoLike);
    return d.toLocaleString();
}

async function fetchClasses() {
    const res = await fetch('/api/classes');
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.status !== 'success') {
        throw new Error(data.message || 'Failed to list classes.');
    }
    classesCache = Array.isArray(data.classes) ? data.classes : [];
    return classesCache;
}

function renderClassesTable(classes) {
    const tbody = document.getElementById('classes-table-body');
    if (!tbody) return;
    tbody.innerHTML = '';
    if (!classes.length) {
        const tr = document.createElement('tr');
        const td = document.createElement('td');
        td.colSpan = 6;
        td.textContent = 'No classes yet. Add one below.';
        td.style.color = 'var(--text-muted)';
        tr.appendChild(td);
        tbody.appendChild(tr);
        return;
    }
    for (const cls of classes) {
        const name = cls.class_name || '';
        const tr = document.createElement('tr');
        tr.className = 'classes-row';
        tr.title = 'Click to reveal in file manager';
        tr.addEventListener('click', () => revealClass(name));

        const cells = [
            name,
            String(cls.num_students ?? 0),
            cls.has_student_id ? 'Yes' : 'No',
            cls.has_student_email ? 'Yes' : 'No',
            formatLastEdited(cls.last_edited),
        ];
        for (const text of cells) {
            const td = document.createElement('td');
            td.textContent = text;
            tr.appendChild(td);
        }

        const actions = document.createElement('td');
        actions.className = 'classes-row-actions';
        const deleteBtn = document.createElement('button');
        deleteBtn.type = 'button';
        deleteBtn.textContent = 'Delete';
        deleteBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            deleteClassPrompt(name);
        });
        actions.appendChild(deleteBtn);
        tr.appendChild(actions);
        tbody.appendChild(tr);
    }
}

async function refreshClassesUi() {
    setClassesStatus('');
    try {
        const classes = await fetchClasses();
        renderClassesTable(classes);
        await refreshClassSelect();
    } catch (e) {
        renderClassesTable([]);
        setClassesStatus(e.message || String(e), true);
    }
}

async function refreshClassSelect() {
    const select = document.getElementById('gen-class-select');
    if (!select) return;
    const prev = select.value;
    try {
        if (!classesCache.length) await fetchClasses();
    } catch (e) {
        // Keep whatever options exist if list fails mid-session.
    }
    select.innerHTML = '';
    const none = document.createElement('option');
    none.value = '';
    none.textContent = '(none)';
    select.appendChild(none);
    for (const cls of classesCache) {
        const opt = document.createElement('option');
        opt.value = cls.class_name || '';
        opt.textContent = cls.class_name || '';
        select.appendChild(opt);
    }
    if ([...select.options].some((o) => o.value === prev)) {
        select.value = prev;
    } else {
        select.value = '';
    }
}

async function revealClass(className) {
    if (!className) return;
    try {
        const res = await fetch('/api/classes/reveal', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ class_name: className }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || data.status !== 'success') {
            setClassesStatus(data.message || 'Could not reveal class file.', true);
        }
    } catch (e) {
        setClassesStatus(e.message || String(e), true);
    }
}

async function deleteClassPrompt(className) {
    const ok = window.confirm(`Delete class “${className}”? This cannot be undone.`);
    if (!ok) return;
    setClassesStatus('');
    try {
        const res = await fetch('/api/classes/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ class_name: className }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || data.status !== 'success') {
            setClassesStatus(data.message || 'Delete failed.', true);
            return;
        }
        await refreshClassesUi();
    } catch (e) {
        setClassesStatus(e.message || String(e), true);
    }
}

// Native OS file dialog (not the in-app path browser). Browser security hides the full path,
// so we keep the File object and upload its text when adding the class.
let pendingNewClassCsvFile = null;

function pickNewClassCsvNative() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.csv,text/csv';
    input.style.display = 'none';
    input.addEventListener('change', () => {
        const file = input.files && input.files[0] ? input.files[0] : null;
        pendingNewClassCsvFile = file;
        const pathEl = document.getElementById('new-class-csv-path');
        if (pathEl) pathEl.value = file ? file.name : '';
        input.remove();
    });
    document.body.appendChild(input);
    input.click();
}

function clearPendingNewClassCsv() {
    pendingNewClassCsvFile = null;
    const pathEl = document.getElementById('new-class-csv-path');
    if (pathEl) pathEl.value = '';
}

async function addNewClass() {
    const nameInput = document.getElementById('new-class-name');
    const className = (nameInput?.value || '').trim();
    if (!className) {
        setClassesStatus('Enter a class name.', true);
        return;
    }
    if (!pendingNewClassCsvFile) {
        setClassesStatus('Select a roster CSV file.', true);
        return;
    }
    setClassesStatus('Adding class…');
    try {
        const csvText = await pendingNewClassCsvFile.text();
        const res = await fetch('/api/classes', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ class_name: className, csv_text: csvText }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || data.status !== 'success') {
            setClassesStatus(data.message || 'Could not add class.', true);
            return;
        }
        if (nameInput) nameInput.value = '';
        clearPendingNewClassCsv();
        await refreshClassesUi();
        const select = document.getElementById('gen-class-select');
        if (select && data.class?.class_name) {
            select.value = data.class.class_name;
        } else if (select) {
            select.value = className;
        }
        setClassesStatus(`Added class “${className}”.`);
    } catch (e) {
        setClassesStatus(e.message || String(e), true);
    }
}

function createNewMasterStub() {
    openMasterBuilder();
}

function visibleWorkspaceId() {
    if (gradingUI && !gradingUI.classList.contains('hidden')) return 'grading-ui';
    const verify = document.getElementById('verify-sec');
    if (verify && !verify.classList.contains('hidden')) return 'verify-sec';
    if (builderSection && !builderSection.classList.contains('hidden')) return 'builder-sec';
    if (generateSection && !generateSection.classList.contains('hidden')) return 'generate-sec';
    if (processSection && !processSection.classList.contains('hidden')) return 'process-sec';
    if (gradeSection && !gradeSection.classList.contains('hidden')) return 'grade-sec';
    const namereader = document.getElementById('namereader-sec');
    if (namereader && !namereader.classList.contains('hidden')) return 'namereader-sec';
    if (mainMenu && !mainMenu.classList.contains('hidden')) return 'main-menu';
    return null;
}

async function goHome() {
    const current = visibleWorkspaceId();
    if (current === 'main-menu') return;

    if (current === 'grading-ui') {
        try {
            const commitRes = await commitCurrentGradingData();
            let commitData = {};
            try { commitData = await commitRes.json(); } catch (e) { /* ignore */ }
            if (!commitRes.ok || commitData.status !== 'success') {
                showMessageModal({
                    title: 'Error',
                    message: commitData.message || 'Failed to save grading data before leaving.',
                });
                return;
            }
            const res = await fetch('/api/close_grading_session', { method: 'POST' });
            let data = {};
            try { data = await res.json(); } catch (e) { /* ignore */ }
            if (!res.ok || data.status !== 'success') {
                showMessageModal({
                    title: 'Error',
                    message: data.message || 'Failed to close grading session.',
                });
                return;
            }
        } catch (e) {
            showMessageModal({
                title: 'Error',
                message: e.message || String(e),
            });
            return;
        }
        showSection('main-menu');
        return;
    }

    if (current === 'verify-sec') {
        await clearArchiveContext();
        showSection('main-menu');
        return;
    }

    showSection('main-menu');
}

function initClassesAndHelpModals() {
    const helpClose = document.getElementById('help-modal-close');
    const helpOk = document.getElementById('help-modal-ok');
    if (helpClose) helpClose.onclick = closeHelpModal;
    if (helpOk) helpOk.onclick = closeHelpModal;

    const classesClose = document.getElementById('classes-modal-close');
    const classesDone = document.getElementById('classes-modal-done');
    if (classesClose) classesClose.onclick = closeClassesModal;
    if (classesDone) classesDone.onclick = closeClassesModal;

    refreshClassSelect().catch(() => {});
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initClassesAndHelpModals);
} else {
    initClassesAndHelpModals();
}
