// Main-menu navigation, the file-picker / existing-tmp modals, name-field helpers, and the
// generate-assignments and process-scans websocket runs.

const WORKFLOW_VIEWBOX = { w: 554.393597012, h: 642.750550576 };
// Slots were a bit high/left vs the diagram; nudge buttons into place.
const WORKFLOW_BTN_SHIFT = { x: 28, y: 28 };
const WORKFLOW_SLOTS = {
    1: { x: 0, y: 0, w: 315, h: 54 },
    2: { x: 0, y: 218.560058594, w: 315, h: 54 },
    3: { x: 0, y: 335.872070313, w: 315, h: 54 },
    4: { x: 0, y: 496.808105469, w: 315, h: 54 },
};

const WORKFLOW_STEP_TOOLTIPS = {
    'assignment-pdfs': 'Step [1] generates one pdf for every assignment version (plus the key).',
    'students-complete': 'Each student gets a unique version of the assignment. Notes:\n - Multiple copies of the same version should not be distributed to students.',
    'scan-file': 'Scan all student pages as a single `.tiff` file. Notes:\n - Preferrably, use a scan resolution at least 200 dpi.\n - This scan will be converted to a pure black-and-white photo (not greyscale) so no need to use a different color setting than that.\n - If the assignments have staples in the corner, you can physically cut the corner of the assignment to remove the staple. The remaining anchor boxes (black dots around perimeter) will be sufficient for recognition. If you do this, consider feeding pages into the scanner backwards to give scanner a full edge to work with.',
    'assnversions': 'Step [1] generates this file alongside the assignment versions `.pdf`s. This file contains information about where questions and answer bubbles are physically located in the assignments.',
    'assn': 'Step [2] generates this file, which contains scanned pages of student work, computer-detected answers, and all other information required for grading.',
    'feedback-pdfs': 'Step [3] generates these per-student feedback `.pdf`s exported after grading.\n - #drive If the class roster included an `Email` column when the assignment was created (see step [1]), Finish & Export can upload PDFs under `Biscuit/class_name` in Google Drive after a one-time Google account link.',
    'grades-csvs': 'Step [3] exports two scores spreadsheets: one detailed version with per-question information, and a second with student totals.\n - #canvas If the class roster included an `ID` column when the assignment was created (see step [1]), the second spreadsheet can be uploaded directly to Canvas for score submission.',
    'training-data': '_(Optional)_ #namereader A folder containing one folder per student containing cropped name-box images collected for name recognition training. Note this is only generated if your assignment was enabled to do this in step [1].',
    'namereader': '_(Optional)_ #namereader Step [4] generates this file, which contains a neural network trained to identify student names. This file is large and can take significant time to generate, but only needs to be generated once per class.\n - #usenamereader After its creation, the `.namereader` file can be used in step [2] for future student assignments to give an initial guess on written names.',
};

const WORKFLOW_BUTTON_TOOLTIPS = {
    1: 'Create or upload a master file (`.json`) that contains assignment information. From this, build randomized assignment `.pdf`s and supporting files.\n - #namereader When creating the assignment, you can include a question where students will hand-write their names multiple times to be used for identifying their names on future assignments.\nOptionally select a class so its roster (a `.csv` file) is bundled into the archive.\n - #canvas If the roster has an `ID` header, the final grades `.csv` export can be used to import those scores into Canvas.\n - #drive If the roster has an `Email` header, the feedback `.pdf`s can be exported to a per-student Google Drive folder (read-only) automatically shared with them.',
    2: 'Read scanned pages, locate bubbles/anchors, and build a `.assn` file that is used for grading.\n - #usenamereader If a `.namereader` file is provided, student names are guessed from the name line and stored as `name_guesses.json` in the `.assn` file. These should be manually verified.',
    3: 'Assign student names and enter/review grades for each question. Produce feedback files and score spreadsheets.',
    4: '#namereader Create a name-reading neural network that idenifies student names to speed up name assignment in future assignments.',
};

const WORKFLOW_TAG_REPLACEMENTS = {
    '#usenamereader': '<span class="tt-tag tt-tag-usenamereader" title="Use name reader">*</span>',
    '#canvas': '<span class="tt-tag tt-tag-canvas" title="Canvas">*</span>',
    '#drive': '<span class="tt-tag tt-tag-drive" title="Google Drive">*</span>',
    '#namereader': '<span class="tt-tag tt-tag-namereader" title="Name reader">*</span>',
};

function escapeHtml(text) {
    return String(text)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

// Lightweight markup for workflow tooltips:
// `code`, _italics_, lines starting with " - " as bullets, plain newlines as <br>,
// and #canvas/#drive/#namereader/#usenamereader markers.
function formatWorkflowTooltipHtml(raw) {
    let text = escapeHtml(raw);
    // Longer tags first so #usenamereader is not partially matched as #namereader.
    text = text.replace(
        /#usenamereader|#canvas|#drive|#namereader/g,
        (tag) => WORKFLOW_TAG_REPLACEMENTS[tag] || tag
    );

    // Protect `code` spans so italics / list parsing cannot alter their contents.
    const codeParts = [];
    text = text.replace(/`([^`]+)`/g, (_, code) => {
        const idx = codeParts.length;
        codeParts.push(`<code>${code}</code>`);
        return `\0CODE${idx}\0`;
    });

    text = text.replace(/_([^_\n]+)_/g, '<em>$1</em>');

    const lines = text.split('\n');
    const parts = [];
    let listItems = [];
    const flushList = () => {
        if (!listItems.length) return;
        parts.push(`<ul>${listItems.map((item) => `<li>${item}</li>`).join('')}</ul>`);
        listItems = [];
    };
    for (const line of lines) {
        const bullet = line.match(/^\s*-\s+(.*)$/);
        if (bullet) {
            listItems.push(bullet[1]);
            continue;
        }
        flushList();
        // Keep empty lines so plain `\n` / `\n\n` become visual breaks via join('<br>').
        parts.push(line);
    }
    flushList();

    return parts.join('<br>').replace(/\0CODE(\d+)\0/g, (_, i) => codeParts[Number(i)]);
}

function pct(n, total) {
    return `${(n / total) * 100}%`;
}

function getWorkflowTooltipEl() {
    let tip = document.getElementById('workflow-tooltip');
    if (tip) return tip;
    tip = document.createElement('div');
    tip.id = 'workflow-tooltip';
    tip.className = 'workflow-tooltip hidden';
    tip.setAttribute('role', 'tooltip');
    document.body.appendChild(tip);
    return tip;
}

function showWorkflowTooltip(text, clientX, clientY) {
    const tip = getWorkflowTooltipEl();
    tip.innerHTML = formatWorkflowTooltipHtml(text);
    tip.classList.remove('hidden');
    const pad = 14;
    const rect = tip.getBoundingClientRect();
    let left = clientX + pad;
    let top = clientY + pad;
    if (left + rect.width > window.innerWidth - 8) left = clientX - rect.width - pad;
    if (top + rect.height > window.innerHeight - 8) top = clientY - rect.height - pad;
    tip.style.left = `${Math.max(8, left)}px`;
    tip.style.top = `${Math.max(8, top)}px`;
}

function hideWorkflowTooltip() {
    const tip = document.getElementById('workflow-tooltip');
    if (tip) tip.classList.add('hidden');
}

function bindWorkflowStepTooltips(svg) {
    svg.querySelectorAll('.step-with-tt[id]').forEach((el) => {
        const text = WORKFLOW_STEP_TOOLTIPS[el.id] || `Filler tooltip for “${el.id}”.`;
        el.addEventListener('pointerenter', (e) => showWorkflowTooltip(text, e.clientX, e.clientY));
        el.addEventListener('pointermove', (e) => showWorkflowTooltip(text, e.clientX, e.clientY));
        el.addEventListener('pointerleave', hideWorkflowTooltip);
    });
}

function bindWorkflowButtonTooltips() {
    document.querySelectorAll('.menu-btn[data-slot]').forEach((btn) => {
        if (btn.dataset.ttBound === 'true') return;
        btn.dataset.ttBound = 'true';
        const text = WORKFLOW_BUTTON_TOOLTIPS[btn.dataset.slot] || 'Filler button tooltip.';
        const onMove = (e) => {
            if (!document.getElementById('menu-stage')?.classList.contains('workflow-mode')) {
                hideWorkflowTooltip();
                return;
            }
            showWorkflowTooltip(text, e.clientX, e.clientY);
        };
        btn.addEventListener('pointerenter', onMove);
        btn.addEventListener('pointermove', onMove);
        btn.addEventListener('pointerleave', hideWorkflowTooltip);
    });
}

function applyWorkflowButtonLayout(enabled) {
    const stage = document.getElementById('menu-stage');
    const host = document.getElementById('workflow-host');
    if (!stage || !host) return;
    stage.classList.toggle('workflow-mode', enabled);
    host.classList.toggle('hidden', !enabled);
    host.setAttribute('aria-hidden', enabled ? 'false' : 'true');
    if (!enabled) hideWorkflowTooltip();
    document.querySelectorAll('.menu-btn[data-slot]').forEach((btn) => {
        const slot = WORKFLOW_SLOTS[btn.dataset.slot];
        if (!slot) return;
        if (enabled) {
            btn.style.left = pct(slot.x + WORKFLOW_BTN_SHIFT.x, WORKFLOW_VIEWBOX.w);
            btn.style.top = pct(slot.y + WORKFLOW_BTN_SHIFT.y, WORKFLOW_VIEWBOX.h);
            btn.style.width = pct(slot.w, WORKFLOW_VIEWBOX.w);
            btn.style.height = pct(slot.h, WORKFLOW_VIEWBOX.h);
        } else {
            btn.style.left = '';
            btn.style.top = '';
            btn.style.width = '';
            btn.style.height = '';
        }
    });
}

async function ensureWorkflowSvgLoaded() {
    const host = document.getElementById('workflow-host');
    if (!host || host.dataset.loaded === 'true') return;
    const res = await fetch('workflow.svg');
    if (!res.ok) throw new Error(`Could not load workflow.svg (${res.status})`);
    host.innerHTML = await res.text();
    const svg = host.querySelector('svg');
    if (svg) {
        svg.removeAttribute('width');
        svg.removeAttribute('height');
        svg.classList.add('workflow-svg');
        svg.setAttribute('role', 'img');
        svg.setAttribute('aria-label', 'Biscuit workflow diagram');
        bindWorkflowStepTooltips(svg);
    }
    host.dataset.loaded = 'true';
}

function initWorkflowToggle() {
    const checkbox = document.getElementById('show-workflow');
    if (!checkbox) return;
    bindWorkflowButtonTooltips();
    // Pre-fetch workflow.svg in the background so toggle is instantaneous
    ensureWorkflowSvgLoaded().catch(() => {});

    checkbox.addEventListener('change', () => {
        applyWorkflowButtonLayout(checkbox.checked);
        if (checkbox.checked) {
            ensureWorkflowSvgLoaded().catch((err) => {
                console.error(err);
                checkbox.checked = false;
                applyWorkflowButtonLayout(false);
                showMessageModal({
                    title: 'Error',
                    message: `Could not load workflow diagram: ${err.message || err}`,
                });
            });
        }
    });
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initWorkflowToggle);
} else {
    initWorkflowToggle();
}

// General functions

function showSection(id) {
    if (id !== 'generate-sec' && activeGenerateSocket && activeGenerateSocket.readyState <= WebSocket.OPEN) {
        activeGenerateSocket.close(1000, "Leaving generate section");
    }
    if (id !== 'process-sec' && id !== 'verify-sec' && activeProcessSocket && activeProcessSocket.readyState <= WebSocket.OPEN) {
        activeProcessSocket.close(1000, "Leaving process section");
    }
    if (id !== 'namereader-sec' && activeTrainSocket && activeTrainSocket.readyState <= WebSocket.OPEN) {
        activeTrainSocket.close(1000, "Leaving name recognition section");
    }
    mainMenu.classList.add('hidden');
    generateSection.classList.add('hidden');
    if (builderSection) builderSection.classList.add('hidden');
    processSection.classList.add('hidden');
    gradeSection.classList.add('hidden');
    gradingUI.classList.add('hidden');
    const verifySection = document.getElementById('verify-sec');
    if (verifySection) verifySection.classList.add('hidden');
    const namereaderSection = document.getElementById('namereader-sec');
    if (namereaderSection) namereaderSection.classList.add('hidden');
    
    if (id) {
        document.getElementById(id).classList.remove('hidden');
    }
    if (id === 'generate-sec' && typeof refreshClassSelect === 'function') {
        refreshClassSelect().catch(() => {});
    }
}

window.addEventListener('beforeunload', () => {
    if (activeGenerateSocket && activeGenerateSocket.readyState <= WebSocket.OPEN) {
        activeGenerateSocket.close(1000, "Page unloading");
    }
    if (activeProcessSocket && activeProcessSocket.readyState <= WebSocket.OPEN) {
        activeProcessSocket.close(1000, "Page unloading");
    }
});

function setStartGradingLoading(isLoading) {
    if (!startGradingBtn || !startGradingSpinner || !startGradingLabel) return;
    startGradingBtn.disabled = isLoading;
    startGradingSpinner.classList.toggle('hidden', !isLoading);
    startGradingLabel.textContent = isLoading ? "Starting..." : "Start Grading";
}

function pickExistingTmpOption(messageText) {
    return new Promise(resolve => {
        existingTmpMessage.textContent = messageText || "Data from a previous session was found for this .assn file.\nChoose one option:";
        existingTmpModal.classList.remove('hidden');
        const cleanup = () => {
            existingTmpModal.classList.add('hidden');
            existingTmpLoadBtn.onclick = null;
            existingTmpReplaceBtn.onclick = null;
            existingTmpCancelBtn.onclick = null;
        };
        existingTmpLoadBtn.onclick = () => { cleanup(); resolve('load_existing'); };
        existingTmpReplaceBtn.onclick = () => { cleanup(); resolve('replace_existing'); };
        existingTmpCancelBtn.onclick = () => { cleanup(); resolve('cancel'); };
    });
}

function pickFile(inputId, acceptExts) {
    currentPickerInput = inputId;
    currentPickerAcceptExts = Array.isArray(acceptExts)
        ? acceptExts.map((ext) => String(ext).toLowerCase())
        : null;
    currentPickerFolderMode = false;
    const useFolderBtn = document.getElementById('file-picker-use-folder');
    if (useFolderBtn) useFolderBtn.classList.add('hidden');
    filePicker.classList.remove('hidden');
    loadFilePickerDir(".");
}

function pickFolder(inputId) {
    currentPickerInput = inputId;
    currentPickerAcceptExts = null;
    currentPickerFolderMode = true;
    const useFolderBtn = document.getElementById('file-picker-use-folder');
    if (useFolderBtn) useFolderBtn.classList.remove('hidden');
    filePicker.classList.remove('hidden');
    loadFilePickerDir(".");
}

function useCurrentPickerFolder() {
    const dir = document.getElementById('file-picker-dir').textContent;
    document.getElementById(currentPickerInput).value = dir;
    if (currentPickerInput === 'nr-handwriting-path') {
        syncNameReaderNameFromPath();
    }
    closeFilePicker();
}

function closeFilePicker() {
    filePicker.classList.add('hidden');
    currentPickerAcceptExts = null;
    currentPickerFolderMode = false;
    const useFolderBtn = document.getElementById('file-picker-use-folder');
    if (useFolderBtn) useFolderBtn.classList.add('hidden');
}

function fileMatchesPickerAccept(fileName) {
    if (!currentPickerAcceptExts || !currentPickerAcceptExts.length) return true;
    const lower = String(fileName || '').toLowerCase();
    return currentPickerAcceptExts.some((ext) => lower.endsWith(ext));
}

async function loadFilePickerDir(dir) {
    try {
        const res = await fetch(`/api/list_files?dir=${encodeURIComponent(dir)}`);
        const data = await res.json();
        if (data.status === "success") {
            document.getElementById('file-picker-dir').textContent = data.current_dir;
            const list = document.getElementById('file-picker-list');
            list.innerHTML = '';
            for (let entry of data.entries) {
                const div = document.createElement('div');
                div.className = 'file-picker-entry';
                if (entry.is_dir) {
                    div.innerHTML = `📁 <strong>${entry.name}</strong>`;
                    div.onclick = () => loadFilePickerDir(entry.path);
                } else if (!fileMatchesPickerAccept(entry.name)) {
                    div.classList.add('disabled');
                    div.innerHTML = `📄 ${entry.name}`;
                    div.title = currentPickerAcceptExts.length === 1
                        ? `Select a ${currentPickerAcceptExts[0]} file`
                        : `Select a file ending in ${currentPickerAcceptExts.join(' or ')}`;
                } else {
                    div.innerHTML = `📄 ${entry.name}`;
                    div.onclick = () => {
                        if (currentPickerInput === 'builder-load-temp') {
                            loadMasterJSONFromPath(entry.path);
                            closeFilePicker();
                            return;
                        }
                        document.getElementById(currentPickerInput).value = entry.path;
                        if (currentPickerInput === 'gen-master-path') {
                            syncGenerateNameFromPath();
                            validateMasterPath();
                        } else if (currentPickerInput === 'proc-assnversions-path') {
                            syncProcessNameFromPath();
                            bustScanImageCache();
                        } else if (currentPickerInput === 'proc-tiff-path' || currentPickerInput === 'grade-assn-path') {
                            bustScanImageCache();
                        }
                        closeFilePicker();
                    };
                }
                list.appendChild(div);
            }
        }
    } catch(e) {console.error("Failed to list files:", e);}
}

function splitPath(path) {
    const normalized = (path || "").trim();
    const slash = normalized.lastIndexOf('/');
    if (slash < 0) return { dir: ".", file: normalized };
    if (slash === 0) return { dir: "/", file: normalized.slice(1) };
    return { dir: normalized.slice(0, slash), file: normalized.slice(slash + 1) };
}

function stripExtension(fileName, extension) {
    if (!fileName) return "";
    if (fileName.toLowerCase().endsWith(extension.toLowerCase())) {
        return fileName.slice(0, fileName.length - extension.length);
    }
    const dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.slice(0, dot) : fileName;
}

function classStemFromTrainingDir(folderPath) {
    const name = splitPath(folderPath).file || "";
    const suffix = "_name_training_data";
    if (name.toLowerCase().endsWith(suffix) && name.length > suffix.length) {
        return name.slice(0, name.length - suffix.length);
    }
    return name;
}

function selectAllOnFirstClick(el) {
    if (!el) return;
    let pendingSelect = false;
    el.addEventListener('mousedown', function (e) {
        if (document.activeElement === this) return;
        if (!String(this.value || '').trim()) return;
        pendingSelect = true;
        e.preventDefault();
        this.focus();
        this.select();
    });
    el.addEventListener('mouseup', function (e) {
        if (!pendingSelect) return;
        e.preventDefault();
        this.select();
        pendingSelect = false;
    });
}

async function fileExistsInDir(dir, fileName) {
    try {
        const res = await fetch(`/api/list_files?dir=${encodeURIComponent(dir)}`);
        const data = await res.json();
        if (data.status !== "success") return false;
        return data.entries.some(e => !e.is_dir && e.name === fileName);
    } catch {
        return false;
    }
}

function setNameFieldState(inputEl, warningEl, exists, extText) {
    if (!inputEl.value.trim()) {
        inputEl.style.outline = "2px solid #f59e0b";
        warningEl.style.color = "#b45309";
        warningEl.textContent = `Please enter a file name (without ${extText}).`;
        return;
    }
    if (exists) {
        inputEl.style.outline = "2px solid #f59e0b";
        warningEl.style.color = "#b45309";
        warningEl.textContent = "Warning: file already exists and will be overwritten.";
    } else {
        inputEl.style.outline = "2px solid #16a34a";
        warningEl.style.color = "#15803d";
        warningEl.textContent = "This will create a new file.";
    }
}

function syncGenerateNameFromPath() {
    const masterPath = document.getElementById('gen-master-path').value;
    const parts = splitPath(masterPath);
    document.getElementById('gen-new-name').value = stripExtension(parts.file, ".json");
    updateGenerateNameStatus();
}

function syncProcessNameFromPath() {
    const assnVersionsPath = document.getElementById('proc-assnversions-path').value;
    const parts = splitPath(assnVersionsPath);
    document.getElementById('proc-new-name').value = stripExtension(parts.file, ".assnversions");
    updateProcessNameStatus();
}

async function updateGenerateNameStatus() {
    const masterPath = document.getElementById('gen-master-path').value;
    const newNameInput = document.getElementById('gen-new-name');
    const warning = document.getElementById('gen-name-warning');
    const parts = splitPath(masterPath);
    const targetName = `${newNameInput.value.trim()}.assnversions`;
    const exists = await fileExistsInDir(parts.dir || ".", targetName);
    setNameFieldState(newNameInput, warning, exists, ".assnversions");
}

async function updateProcessNameStatus() {
    const assnVersionsPath = document.getElementById('proc-assnversions-path').value;
    const newNameInput = document.getElementById('proc-new-name');
    const warning = document.getElementById('proc-name-warning');
    const parts = splitPath(assnVersionsPath);
    const targetName = `${newNameInput.value.trim()}.assn`;
    const exists = await fileExistsInDir(parts.dir || ".", targetName);
    setNameFieldState(newNameInput, warning, exists, ".assn");
}

function syncNameReaderNameFromPath() {
    const folder = document.getElementById('nr-handwriting-path').value;
    document.getElementById('nr-output-name').value = classStemFromTrainingDir(folder);
    updateNameReaderNameStatus();
}

async function updateNameReaderNameStatus() {
    const folder = document.getElementById('nr-handwriting-path').value;
    const newNameInput = document.getElementById('nr-output-name');
    const warning = document.getElementById('nr-name-warning');
    const parts = splitPath(folder);
    const targetName = `${newNameInput.value.trim()}.namereader`;
    const exists = await fileExistsInDir(parts.dir || ".", targetName);
    setNameFieldState(newNameInput, warning, exists, ".namereader");
}

// Create Assignment

function generateAssnFiles() {
    const masterPath = document.getElementById('gen-master-path').value;
    const newFileName = document.getElementById('gen-new-name').value.trim();
    const classSelect = document.getElementById('gen-class-select');
    const className = classSelect ? classSelect.value.trim() : '';
    const out = document.getElementById('gen-output');
    out.textContent = "Running...\n";
    
    if (activeGenerateSocket && activeGenerateSocket.readyState <= WebSocket.OPEN) {
        activeGenerateSocket.close(1000, "Starting new generate run");
    }
    const ws = new WebSocket(`ws://${location.host}/api/ws_generate`);
    activeGenerateSocket = ws;
    const payload = { master_file: masterPath, new_file_name: newFileName };
    if (className) payload.class_name = className;
    ws.onopen = () => ws.send(JSON.stringify(payload));
    ws.onmessage = (event) => {
        out.textContent += event.data;
        out.scrollTop = out.scrollHeight;
        if (String(event.data).trim() === "Done") {
            ws.close(1000, "Run complete");
        }
    };
    ws.onerror = (error) => { out.textContent += "\nWebSocket Error: " + error; };
    ws.onclose = () => {
        if (activeGenerateSocket === ws) activeGenerateSocket = null;
    };
}

// Process Scans Function

function processScans() {
    const tiffPath = document.getElementById('proc-tiff-path').value;
    const assnPath = document.getElementById('proc-assnversions-path').value;
    const newFileName = document.getElementById('proc-new-name').value.trim();
    const out = document.getElementById('proc-output');
    out.textContent = "Running...\n";
    
    if (activeProcessSocket && activeProcessSocket.readyState <= WebSocket.OPEN) {
        activeProcessSocket.close(1000, "Starting new process run");
    }
    const ws = new WebSocket(`ws://${location.host}/api/ws_process`);
    activeProcessSocket = ws;
    ws.onopen = () => ws.send(JSON.stringify({
        tiff_file: tiffPath,
        assn_file: assnPath,
        new_file_name: newFileName,
        namereader_file: document.getElementById('proc-namereader-path').value.trim()
    }));
    ws.onmessage = (event) => {
        out.textContent += event.data;
        out.scrollTop = out.scrollHeight;
        if (String(event.data).trim() === "Done") {
            const succeeded = !/\nError:/.test(out.textContent) && !out.textContent.startsWith("Error:");
            if (succeeded) {
                bustScanImageCache();
                openVerifyPrompt();
            }
            ws.close(1000, "Run complete");
        }
    };
    ws.onerror = (error) => { out.textContent += "\nWebSocket Error: " + error; };
    ws.onclose = () => {
        if (activeProcessSocket === ws) activeProcessSocket = null;
    };
}

let activeTrainSocket = null;
let nrCanSave = false;
let nrStopping = false;
const NR_SAVE_TOP1 = 0.9;

function setNameReaderTrainingUi(isTraining, isStopping) {
    nrStopping = !!isStopping;
    const trainBtn = document.getElementById('nr-train-btn');
    const stopBtn = document.getElementById('nr-stop-btn');
    if (trainBtn) trainBtn.disabled = !!isTraining;
    if (!stopBtn) return;
    stopBtn.disabled = !isTraining || nrStopping;
    if (nrStopping) {
        stopBtn.textContent = nrCanSave ? 'Saving…' : 'Cancelling…';
    } else if (isTraining && nrCanSave) {
        stopBtn.textContent = 'Stop & Save';
    } else {
        stopBtn.textContent = 'Cancel Training';
    }
}

function latestKnownTop1(text) {
    const matches = String(text).match(/(?:first_guess_correct)=([0-9.]+)/g);
    if (!matches || matches.length === 0) return null;
    const value = parseFloat(matches[matches.length - 1].split('=')[1]);
    return Number.isFinite(value) ? value : null;
}

function stopNameReaderTraining() {
    if (!activeTrainSocket || activeTrainSocket.readyState !== WebSocket.OPEN) return;
    setNameReaderTrainingUi(true, true);
    const save = nrCanSave;
    activeTrainSocket.send(JSON.stringify(save ? { stop: true } : { cancel: true }));
    const out = document.getElementById('nr-output');
    if (out) {
        out.textContent += save
            ? "Stop requested; finishing this epoch and saving…\n"
            : "Cancel requested; stopping without saving…\n";
        out.scrollTop = out.scrollHeight;
    }
}

function trainNameReader() {
    const handwritingDir = document.getElementById('nr-handwriting-path').value.trim();
    const newFileName = document.getElementById('nr-output-name').value.trim();
    const out = document.getElementById('nr-output');
    out.textContent = "Running...\n";
    nrCanSave = false;
    setNameReaderTrainingUi(true, false);
    const ws = new WebSocket(`ws://${location.host}/api/ws_train_namereader`);
    activeTrainSocket = ws;
    ws.onopen = () => ws.send(JSON.stringify({
        handwriting_dir: handwritingDir,
        new_file_name: newFileName,
    }));
    ws.onmessage = (event) => {
        out.textContent += event.data;
        out.scrollTop = out.scrollHeight;
        const top1 = latestKnownTop1(out.textContent);
        if (top1 !== null && top1 >= NR_SAVE_TOP1 && !nrCanSave) {
            nrCanSave = true;
            setNameReaderTrainingUi(true, nrStopping);
        }
        if (String(event.data).trim() === "Done") {
            ws.close(1000, "Run complete");
        }
    };
    ws.onerror = (error) => { out.textContent += "\nWebSocket Error: " + error; };
    ws.onclose = () => {
        if (activeTrainSocket === ws) activeTrainSocket = null;
        nrCanSave = false;
        setNameReaderTrainingUi(false, false);
    };
}

selectAllOnFirstClick(document.getElementById('gen-new-name'));
selectAllOnFirstClick(document.getElementById('proc-new-name'));
selectAllOnFirstClick(document.getElementById('nr-output-name'));

let masterValidationDebounceTimer = null;
let masterValidationSeq = 0;

function syncMasterBuilderButton(mode) {
    const btn = document.getElementById('gen-master-builder-btn');
    if (!btn) return;
    btn.textContent = mode === 'edit' ? 'Edit' : 'Create New';
}

function validateMasterPathDebounced() {
    const input = document.getElementById('gen-master-path');
    const spinner = document.getElementById('gen-master-spinner');
    const check = document.getElementById('gen-master-check');
    const cross = document.getElementById('gen-master-cross');
    const msg = document.getElementById('gen-master-validation-msg');
    if (input) input.classList.remove('is-valid', 'is-invalid');
    if (spinner) spinner.classList.add('hidden');
    if (check) check.classList.add('hidden');
    if (cross) cross.classList.add('hidden');
    if (msg) {
        msg.textContent = '';
        msg.className = 'master-validation-msg';
    }
    syncMasterBuilderButton('create');
    clearTimeout(masterValidationDebounceTimer);
    masterValidationDebounceTimer = setTimeout(() => {
        validateMasterPath();
    }, 300);
}

async function validateMasterPath() {
    const input = document.getElementById('gen-master-path');
    const spinner = document.getElementById('gen-master-spinner');
    const check = document.getElementById('gen-master-check');
    const cross = document.getElementById('gen-master-cross');
    const msg = document.getElementById('gen-master-validation-msg');

    if (!input || !spinner || !check || !cross || !msg) return;

    const path = input.value.trim();
    if (!path) {
        spinner.classList.add('hidden');
        check.classList.add('hidden');
        cross.classList.add('hidden');
        input.classList.remove('is-valid', 'is-invalid');
        msg.textContent = '';
        msg.className = 'master-validation-msg';
        syncMasterBuilderButton('create');
        return;
    }

    const currentSeq = ++masterValidationSeq;
    spinner.classList.remove('hidden');
    check.classList.add('hidden');
    cross.classList.add('hidden');
    input.classList.remove('is-valid', 'is-invalid');
    msg.textContent = '';
    msg.className = 'master-validation-msg';
    syncMasterBuilderButton('create');

    try {
        const res = await fetch('/api/validate_master_json', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: path }),
        });
        const data = await res.json();

        if (currentSeq !== masterValidationSeq) return;

        spinner.classList.add('hidden');
        if (res.ok && data.status === 'success') {
            check.classList.remove('hidden');
            cross.classList.add('hidden');
            input.classList.add('is-valid');
            input.classList.remove('is-invalid');
            msg.textContent = 'master .json validated';
            msg.className = 'master-validation-msg success';
            syncMasterBuilderButton('edit');
        } else {
            check.classList.add('hidden');
            cross.classList.remove('hidden');
            input.classList.add('is-invalid');
            input.classList.remove('is-valid');
            msg.textContent = data.message || 'Validation failed.';
            msg.className = 'master-validation-msg error';
            syncMasterBuilderButton('create');
        }
    } catch (e) {
        if (currentSeq !== masterValidationSeq) return;
        spinner.classList.add('hidden');
        check.classList.add('hidden');
        cross.classList.remove('hidden');
        input.classList.add('is-invalid');
        input.classList.remove('is-valid');
        msg.textContent = 'Failed to connect to server: ' + (e.message || String(e));
        msg.className = 'master-validation-msg error';
        syncMasterBuilderButton('create');
    }
}

async function openOrEditMasterBuilder() {
    const input = document.getElementById('gen-master-path');
    const path = (input?.value || '').trim();
    const validated = !!(input && input.classList.contains('is-valid'));
    if (!(path && validated)) {
        openMasterBuilder();
        return;
    }
    try {
        const res = await fetch('/api/load_master_json', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: path }),
        });
        const data = await res.json();
        if (!res.ok || data.status !== 'success') {
            showMessageModal({
                title: 'Failed to Load JSON',
                message: data.message || 'Could not load master JSON file.',
            });
            return;
        }
        openMasterBuilder(data.master, data.path);
    } catch (e) {
        showMessageModal({
            title: 'Error',
            message: 'Failed to load file: ' + (e.message || String(e)),
        });
    }
}

function pickFileToLoadBuilder() {
    pickFile('builder-load-temp', ['.json']);
}
