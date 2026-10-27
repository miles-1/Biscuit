// Validate Data: browse a class's stored name images student by student, deleting or
// reassigning ones that were filed under the wrong student.

let nameValidateState = null;

const NAME_VALIDATE_KINDS = [
    { kind: 'table', label: 'Name-table crops' },
    { kind: 'assn', label: 'Name-line crops' },
];

const NAME_VALIDATE_SPLITS = {
    train: { label: 'train', title: 'Used for training in the last training run' },
    test: { label: 'test', title: 'Held back to test accuracy in the last training run' },
};

function nameValidateImageUrl(className, student, file) {
    const q = new URLSearchParams({ class_name: className, student, file });
    return `/api/class_name_image?${q.toString()}`;
}

async function openNameDataValidation() {
    const select = document.getElementById('nr-class-select');
    const className = select ? select.value.trim() : '';
    if (!className) return;
    nameValidateState = {
        className,
        hasNameReader: false,
        students: [],
        targets: [],
        index: 0,
        selected: null,
        reassigning: false,
        busy: false,
    };
    document.getElementById('nr-validate-title').textContent = `Validate Name Data: ${className}`;
    document.getElementById('nr-validate-close').onclick = closeNameDataValidation;
    document.getElementById('nr-validate-prev').onclick = () => stepNameValidateStudent(-1);
    document.getElementById('nr-validate-next').onclick = () => stepNameValidateStudent(1);
    document.getElementById('nr-validate-student').onchange = (e) => {
        showNameValidateStudent(Number(e.target.value));
        e.target.blur();
    };
    document.getElementById('nr-validate-body').innerHTML = '<p>Loading…</p>';
    document.getElementById('nr-validate-modal').classList.remove('hidden');
    await reloadNameValidation();
}

function closeNameDataValidation() {
    document.getElementById('nr-validate-modal').classList.add('hidden');
    nameValidateState = null;
    if (typeof refreshNameReaderClassInfo === 'function') refreshNameReaderClassInfo();
}

// Re-read the store, staying on the current student while they still have images.
async function reloadNameValidation() {
    const state = nameValidateState;
    if (!state) return;
    const keepFolder = state.students[state.index]?.folder ?? null;
    try {
        const res = await fetch(`/api/class_name_images?class_name=${encodeURIComponent(state.className)}`);
        const data = await res.json();
        if (!res.ok || data.status !== 'success') throw new Error(data.message || 'Could not list name images.');
        if (nameValidateState !== state) return;
        state.students = Array.isArray(data.students) ? data.students : [];
        state.targets = Array.isArray(data.targets) ? data.targets : [];
        state.hasNameReader = !!data.has_namereader;
    } catch (e) {
        showMessageModal({ title: 'Validate Data', message: e.message || String(e) });
        return;
    }
    const kept = state.students.findIndex((s) => s.folder === keepFolder);
    state.index = kept >= 0 ? kept : Math.min(state.index, Math.max(0, state.students.length - 1));
    state.selected = null;
    state.reassigning = false;
    renderNameValidation();
}

function showNameValidateStudent(index) {
    const state = nameValidateState;
    if (!state || index < 0 || index >= state.students.length) return;
    state.index = index;
    state.selected = null;
    state.reassigning = false;
    renderNameValidation();
}

function stepNameValidateStudent(step) {
    if (!nameValidateState) return;
    showNameValidateStudent(nameValidateState.index + step);
}

function renderNameValidation() {
    const state = nameValidateState;
    if (!state) return;
    const select = document.getElementById('nr-validate-student');
    const position = document.getElementById('nr-validate-position');
    const body = document.getElementById('nr-validate-body');
    const n = state.students.length;

    select.innerHTML = '';
    state.students.forEach((s, i) => {
        const opt = document.createElement('option');
        opt.value = String(i);
        opt.textContent = `${s.name} (${s.images.length})`;
        select.appendChild(opt);
    });
    select.value = String(state.index);
    select.disabled = n === 0;
    document.getElementById('nr-validate-prev').disabled = state.index <= 0;
    document.getElementById('nr-validate-next').disabled = state.index >= n - 1;
    position.textContent = n ? `Student ${state.index + 1} of ${n}` : '';

    body.innerHTML = '';
    if (n === 0) {
        body.innerHTML = '<p>No name images are stored for this class.</p>';
        return;
    }
    const student = state.students[state.index];
    for (const { kind, label } of NAME_VALIDATE_KINDS) {
        const images = student.images.filter((img) => img.kind === kind);
        if (images.length === 0) continue;
        const group = document.createElement('div');
        group.className = 'nr-validate-group';
        const heading = document.createElement('h4');
        heading.textContent = `${label} (${images.length})`;
        group.appendChild(heading);
        const grid = document.createElement('div');
        grid.className = 'nr-validate-grid';
        images.forEach((img) => grid.appendChild(buildNameValidateTile(state, student, img)));
        group.appendChild(grid);
        body.appendChild(group);
    }
}

function buildNameValidateTile(state, student, img) {
    const isSelected = state.selected === img.file;
    const tile = document.createElement('div');
    tile.className = 'nr-validate-tile' + (isSelected ? ' is-selected' : '');

    const picture = document.createElement('img');
    picture.src = nameValidateImageUrl(state.className, student.folder, img.file);
    picture.alt = `${student.name}: ${img.file}`;
    picture.draggable = false;
    picture.onclick = (e) => onNameValidateImageClick(e, img.file);
    tile.appendChild(picture);

    if (state.hasNameReader) {
        const split = NAME_VALIDATE_SPLITS[img.split];
        const badge = document.createElement('span');
        badge.className = `nr-split-badge nr-split-${split ? img.split : 'new'}`;
        badge.textContent = split ? split.label : 'new';
        badge.title = split ? split.title : 'Added since the last training run';
        tile.appendChild(badge);
    }

    if (isSelected) tile.appendChild(buildNameValidateActions(state, student, img));
    return tile;
}

function buildNameValidateActions(state, student, img) {
    const actions = document.createElement('div');
    actions.className = 'nr-validate-actions';
    if (!state.reassigning) {
        const del = document.createElement('button');
        del.type = 'button';
        del.className = 'nr-validate-delete';
        del.textContent = 'Delete';
        del.onclick = () => deleteNameValidateImage(img.file);
        const reassign = document.createElement('button');
        reassign.type = 'button';
        reassign.textContent = 'Reassign';
        reassign.onclick = () => {
            state.reassigning = true;
            renderNameValidation();
        };
        actions.append(del, reassign);
        return actions;
    }
    const target = document.createElement('select');
    target.className = 'nr-validate-target';
    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = 'Reassign to…';
    target.appendChild(placeholder);
    state.targets
        .filter((t) => t.folder !== student.folder)
        .forEach((t) => {
            const opt = document.createElement('option');
            opt.value = t.folder;
            opt.textContent = t.name;
            target.appendChild(opt);
        });
    const move = document.createElement('button');
    move.type = 'button';
    move.textContent = 'Move';
    move.disabled = true;
    target.onchange = () => { move.disabled = !target.value; };
    move.onclick = () => reassignNameValidateImage(img.file, target.value);
    const cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.textContent = 'Cancel';
    cancel.onclick = () => {
        state.reassigning = false;
        renderNameValidation();
    };
    actions.append(target, move, cancel);
    requestAnimationFrame(() => target.focus());
    return actions;
}

function onNameValidateImageClick(e, file) {
    const state = nameValidateState;
    if (!state || state.busy) return;
    if (e.shiftKey) {
        deleteNameValidateImage(file);
        return;
    }
    state.selected = state.selected === file ? null : file;
    state.reassigning = false;
    renderNameValidation();
}

async function postNameValidateChange(url, payload) {
    const state = nameValidateState;
    if (!state || state.busy) return;
    state.busy = true;
    try {
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ class_name: state.className, ...payload }),
        });
        const data = await res.json();
        if (!res.ok || data.status !== 'success') throw new Error(data.message || 'The change was not saved.');
    } catch (e) {
        showMessageModal({ title: 'Validate Data', message: e.message || String(e) });
    } finally {
        state.busy = false;
    }
    await reloadNameValidation();
}

function deleteNameValidateImage(file) {
    const student = nameValidateState?.students[nameValidateState.index];
    if (!student) return;
    return postNameValidateChange('/api/class_name_image/delete', { student: student.folder, file });
}

function reassignNameValidateImage(file, toStudent) {
    const student = nameValidateState?.students[nameValidateState.index];
    if (!student || !toStudent) return;
    return postNameValidateChange('/api/class_name_image/reassign', {
        student: student.folder,
        file,
        to_student: toStudent,
    });
}

document.addEventListener('keydown', (e) => {
    const modal = document.getElementById('nr-validate-modal');
    if (!nameValidateState || !modal || modal.classList.contains('hidden')) return;
    const messageModal = document.getElementById('message-modal');
    if (messageModal && !messageModal.classList.contains('hidden')) return;
    const inSelect = document.activeElement && document.activeElement.tagName === 'SELECT';
    if (e.key === 'Escape') {
        e.preventDefault();
        if (nameValidateState.selected) {
            nameValidateState.selected = null;
            nameValidateState.reassigning = false;
            renderNameValidation();
        } else {
            closeNameDataValidation();
        }
    } else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && !inSelect) {
        e.preventDefault();
        stepNameValidateStudent(e.key === 'ArrowLeft' ? -1 : 1);
    }
});
