// Assignment Creator (Master JSON Builder & Live Typst Preview)

const DEFAULT_GLOBAL_VARS = '(\n  // global variables go here, e.g.,\n  // a: 1234\n)';
const RANDOM_VAR_NAME_RE = /^[A-Za-z_][A-Za-z0-9_-]*$/;

let builderState = {
    filePath: '',
    master: {
        assn_type: 'quiz',
        title: 'New Assignment',
        intro_content: '',
        shuffle_questions: false,
        shuffle_answers: false,
        shuffle_sections: false,
        version_count: 1,
        seed: 1234,
        random_vars: [],
        global_vars: DEFAULT_GLOBAL_VARS,
        single_doc_export: false,
        will_print_double_sided: true,
        use_sections: false,
        sections: [
            {
                section_title: 'Section 1',
                questions: []
            }
        ],
        questions: []
    },
    activeAddMenuKey: null,
    previewId: null,
    previewPages: [],
    previewLoading: false,
    previewError: null,
    previewZoom: 1.0,
    previewKind: 'none',
    previewIsKey: true,
    questionPreviewId: null,
    questionPreviewHash: null,
    questionPreviewError: null,
    questionPreviewUpdating: false,
};

let builderToggles = {
    intro: false,
    seed: false,
    globalVars: false,
};

let builderQuestionPreviewTimer = null;
let builderQuestionPreviewSeq = 0;
let builderLastQuestionPath = null;

function toggleTopSetting(key) {
    builderToggles[key] = !builderToggles[key];
    renderBuilderUI();
}

function createDefaultQuestion(type) {
    switch (type) {
        case 'multiple_choice':
            return {
                type: 'multiple_choice',
                points: 1,
                body: 'Which of the following is correct?',
                options: ['Option A', 'Option B', 'Option C', 'Option D'],
                correct_answer: 0,
            };
        case 'true_false':
            return {
                type: 'true_false',
                points: 1,
                body: 'Evaluate the following statements:',
                options: ['Statement 1', 'Statement 2'],
                correct_answer: [0],
            };
        case 'fill_blank':
            return {
                type: 'fill_blank',
                points: 1,
                body: 'The capital of France is #BLANK.',
                correct_answer: ['Paris'],
            };
        case 'essay':
            return {
                type: 'essay',
                points: 1,
                body: 'Explain your reasoning below.',
                num_lines: 3,
                correct_answer: '',
            };
        default:
            return {
                type: 'multiple_choice',
                points: 1,
                body: 'New question',
                options: ['Option A', 'Option B'],
                correct_answer: 0,
            };
    }
}

function createDefaultBank() {
    return {
        pick: 1,
        questions: []
    };
}

function createDefaultSection(title = 'New Section') {
    return {
        section_title: title,
        intro_content: '',
        questions: []
    };
}

function openMasterBuilder(initialData, initialPath) {
    if (initialData && typeof initialData === 'object') {
        loadMasterDataIntoState(initialData, initialPath || '');
    } else {
        resetBuilderState(initialPath || '');
    }
    showSection('builder-sec');
    renderBuilderUI();
    ensureBuilderPreviewListeners();
    renderPreviewPane();
}

function resetBuilderState(path = '') {
    builderToggles = {
        intro: false,
        seed: false,
        globalVars: false,
    };
    builderState = {
        filePath: path,
        master: {
            assn_type: 'quiz',
            title: 'New Assignment',
            intro_content: '',
            shuffle_questions: false,
            shuffle_answers: false,
            shuffle_sections: false,
            version_count: 1,
            seed: 1234,
            random_vars: [],
            global_vars: DEFAULT_GLOBAL_VARS,
            single_doc_export: false,
            will_print_double_sided: true,
            use_sections: false,
            sections: [
                {
                    section_title: 'Section 1',
                    questions: []
                }
            ],
            questions: []
        },
        activeAddMenuKey: null,
        previewId: null,
        previewPages: [],
        previewLoading: false,
        previewError: null,
        previewZoom: 1.0,
        previewKind: 'none',
        previewIsKey: builderState.previewIsKey !== false,
        questionPreviewId: null,
        questionPreviewHash: null,
        questionPreviewError: null,
        questionPreviewUpdating: false,
    };
    builderLastQuestionPath = null;
    markGlobalVarsPanelStale();
}

function loadMasterDataIntoState(data, path = '') {
    const questionsRaw = Array.isArray(data.questions) ? data.questions : [];
    const hasSections = questionsRaw.length > 0 && typeof questionsRaw[0] === 'object' && ('section_title' in questionsRaw[0]);

    const randomVars = normalizeRandomVarsFromData(data.random_vars);
    const globalVars = typeof data.global_vars === 'string' && data.global_vars.trim() ? data.global_vars : DEFAULT_GLOBAL_VARS;
    builderToggles = {
        intro: !!(data.intro_content && data.intro_content.trim()),
        seed: data.seed !== undefined && data.seed !== null && data.seed !== 1234,
        globalVars: randomVars.length > 0 || globalVars.trim() !== DEFAULT_GLOBAL_VARS,
    };

    builderState.filePath = path;
    builderState.previewId = null;
    builderState.previewPages = [];
    builderState.previewLoading = false;
    builderState.previewError = null;
    builderState.previewKind = 'none';
    builderState.questionPreviewId = null;
    builderState.questionPreviewHash = null;
    builderState.questionPreviewError = null;
    builderState.questionPreviewUpdating = false;
    builderState.activeAddMenuKey = null;
    builderLastQuestionPath = null;
    markGlobalVarsPanelStale();

    builderState.master = {
        assn_type: data.assn_type || 'quiz',
        title: data.title || 'Untitled Assignment',
        intro_content: data.intro_content || '',
        shuffle_questions: !!data.shuffle_questions,
        shuffle_answers: !!data.shuffle_answers,
        shuffle_sections: !!data.shuffle_sections,
        version_count: typeof data.version_count === 'number' ? data.version_count : 1,
        seed: typeof data.seed === 'number' ? data.seed : 1234,
        random_vars: randomVars,
        global_vars: globalVars,
        single_doc_export: !!data.single_doc_export,
        will_print_double_sided: data.will_print_double_sided !== undefined ? !!data.will_print_double_sided : true,
        use_sections: hasSections,
        sections: hasSections ? questionsRaw.map((sec) => applyShuffleOverrides({
            section_title: String(sec.section_title || ''),
            intro_content: sec.intro_content || '',
            showIntro: !!(sec.intro_content && String(sec.intro_content).trim()),
            questions: normalizeQuestionsFromData(sec.questions || []),
        }, sec)) : [createDefaultSection('Section 1')],
        questions: !hasSections ? normalizeQuestionsFromData(questionsRaw) : [],
    };
}
function buildMasterJsonPayload() {
    const m = builderState.master;
    const result = {
        assn_type: m.assn_type || 'quiz',
        title: (m.title || '').trim(),
    };

    if (m.intro_content && m.intro_content.trim()) {
        result.intro_content = m.intro_content.trim();
    }
    if (m.shuffle_questions) result.shuffle_questions = true;
    if (m.shuffle_answers) result.shuffle_answers = true;
    if (m.use_sections && m.shuffle_sections) result.shuffle_sections = true;
    if (typeof m.version_count === 'number' && m.version_count > 0) {
        result.version_count = m.version_count;
    }
    if (typeof m.seed === 'number' && m.seed > 0) {
        result.seed = m.seed;
    }
    const randomVars = serializeRandomVars(m.random_vars);
    if (randomVars.length > 0) result.random_vars = randomVars;
    const globalVars = (m.global_vars || '').trim();
    if (globalVars && globalVars !== DEFAULT_GLOBAL_VARS) result.global_vars = globalVars;
    result.single_doc_export = !!m.single_doc_export;
    result.will_print_double_sided = m.will_print_double_sided !== undefined ? !!m.will_print_double_sided : true;

    if (m.use_sections) {
        result.questions = (m.sections || []).map((sec) => {
            const section = {
                section_title: (sec.section_title || '').trim(),
                questions: sanitizeQuestionList(sec.questions || []),
            };
            const intro = (sec.intro_content || '').trim();
            if (intro) section.intro_content = intro;
            return applyShuffleOverrides(section, sec);
        });
    } else {
        result.questions = sanitizeQuestionList(m.questions || []);
    }

    return result;
}

function applyShuffleOverrides(target, source) {
    if (!target || !source || typeof source !== 'object') return target;
    if (typeof source.shuffle_questions === 'boolean') target.shuffle_questions = source.shuffle_questions;
    else delete target.shuffle_questions;
    if (typeof source.shuffle_answers === 'boolean') target.shuffle_answers = source.shuffle_answers;
    else delete target.shuffle_answers;
    return target;
}

function shuffleSelectValue(obj, key) {
    if (!obj || typeof obj[key] !== 'boolean') return 'inherit';
    return obj[key] ? 'true' : 'false';
}

function renderShuffleOverrideSelect(obj, key, onchangeAttr, label) {
    const val = shuffleSelectValue(obj, key);
    return `
        <label class="builder-shuffle-override">
            <span>${label}</span>
            <select class="builder-input-select builder-shuffle-select" onchange="${onchangeAttr}">
                <option value="inherit" ${val === 'inherit' ? 'selected' : ''}>Inherit</option>
                <option value="true" ${val === 'true' ? 'selected' : ''}>Yes</option>
                <option value="false" ${val === 'false' ? 'selected' : ''}>No</option>
            </select>
        </label>
    `;
}

function setShuffleOverride(obj, key, selectValue) {
    if (!obj || typeof obj !== 'object') return;
    if (selectValue === 'true') obj[key] = true;
    else if (selectValue === 'false') obj[key] = false;
    else delete obj[key];
}

function updateSectionShuffle(sIdx, key, value) {
    const sec = builderState.master.sections && builderState.master.sections[sIdx];
    if (sec) setShuffleOverride(sec, key, value);
}

function updateBankShuffle(sIdx, bIdx, key, value) {
    const list = getTargetQuestionList(sIdx, null);
    const bank = list && list[bIdx];
    if (bank) setShuffleOverride(bank, key, value);
}

function updateQuestionShuffle(sIdx, bIdx, qIdx, key, value) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q) setShuffleOverride(q, key, value);
}

function sanitizeQuestionList(list) {
    return list.map((item) => {
        if (item && typeof item === 'object' && 'pick' in item) {
            return applyShuffleOverrides({
                pick: Math.max(1, parseInt(item.pick, 10) || 1),
                questions: (item.questions || []).map(sanitizeSingleQuestion),
            }, item);
        }
        return sanitizeSingleQuestion(item);
    });
}

function serializeRubricList(rubricList) {
    if (!Array.isArray(rubricList) || rubricList.length === 0) return undefined;
    const cleanList = rubricList.map((r) => {
        const desc = (r.desc || '').trim();
        const maxVal = Math.max(0.01, Number(r.max) || 1);
        const row = {
            desc: desc,
            max: maxVal
        };
        const chips = Array.isArray(r.chips) && r.chips.length >= 2 ? r.chips : [
            { score: 0, desc: '' },
            { score: maxVal, desc: '' }
        ];
        let hasZero = false;
        let hasMax = false;
        for (const c of chips) {
            const score = Number(c.score);
            if (isNaN(score) || score < 0) continue;
            if (score === 0) hasZero = true;
            if (Math.abs(score - maxVal) < 1e-6) hasMax = true;
            row[String(score)] = String(c.desc || '');
        }
        if (!hasZero) row['0'] = '';
        if (!hasMax) row[String(maxVal)] = '';
        return row;
    }).filter((r) => r.desc.length > 0 || r.max > 0);
    return cleanList.length > 0 ? cleanList : undefined;
}

function normalizeRubricFromData(rawRubric) {
    if (!Array.isArray(rawRubric) || rawRubric.length === 0) return [];
    return rawRubric.map((r) => {
        if (!r || typeof r !== 'object') return { desc: '', max: 1, chips: [{ score: 0, desc: '' }, { score: 1, desc: '' }] };
        const desc = String(r.desc || '');
        let maxVal = 1;
        if (r.max !== undefined && r.max !== null && !isNaN(Number(r.max)) && Number(r.max) > 0) {
            maxVal = Number(r.max);
        } else if (r.points !== undefined && r.points !== null) {
            maxVal = Array.isArray(r.points) ? Math.max(...r.points) : Number(r.points);
            if (isNaN(maxVal) || maxVal <= 0) maxVal = 1;
        }

        const scoresMap = {};
        scoresMap[0] = '';
        scoresMap[maxVal] = '';
        for (const k of Object.keys(r)) {
            if (k === 'desc' || k === 'max' || k === 'points') continue;
            const num = Number(k);
            if (!isNaN(num) && num >= 0 && num <= maxVal) {
                scoresMap[num] = String(r[k] || '');
            }
        }
        const sortedScores = Object.keys(scoresMap).map(Number).sort((a, b) => a - b);
        const chips = sortedScores.map((s) => ({
            score: s,
            desc: scoresMap[s] !== undefined ? scoresMap[s] : (r[String(s)] !== undefined ? String(r[String(s)]) : '')
        }));
        return {
            desc: desc,
            max: maxVal,
            chips: chips
        };
    });
}

function normalizeQuestionsFromData(list) {
    if (!Array.isArray(list)) return [];
    return list.map((item) => {
        if (!item || typeof item !== 'object') return item;
        if ('pick' in item) {
            return applyShuffleOverrides({
                pick: Math.max(1, parseInt(item.pick, 10) || 1),
                questions: normalizeQuestionsFromData(item.questions || []),
            }, item);
        }
        const copy = JSON.parse(JSON.stringify(item));
        if (copy.rubric) {
            copy.rubric = normalizeRubricFromData(copy.rubric);
        }
        return copy;
    });
}

function createDefaultRandomVar(type) {
    return type === 'float'
        ? { name: '', type: 'float', min: 0, max: 1, digits: 2 }
        : { name: '', type: 'int', min: 1, max: 10, digits: 2 };
}

function normalizeRandomVarsFromData(list) {
    if (!Array.isArray(list)) return [];
    return list.filter((v) => v && typeof v === 'object').map((v) => ({
        name: String(v.name || ''),
        type: v.type === 'float' ? 'float' : 'int',
        min: v.min,
        max: v.max,
        digits: Number.isInteger(v.digits) ? v.digits : 2,
    }));
}

function numberOrNull(v) {
    if (v === '' || v === null || v === undefined || isNaN(Number(v))) return null;
    return Number(v);
}

// Rows without a name are still being filled in, so they are left out until named.
function serializeRandomVars(list) {
    if (!Array.isArray(list)) return [];
    return list.filter((v) => v && String(v.name || '').trim()).map((v) => {
        const out = {
            name: String(v.name).trim(),
            type: v.type === 'float' ? 'float' : 'int',
            min: numberOrNull(v.min),
            max: numberOrNull(v.max),
        };
        if (out.type === 'float') {
            const digits = Number(v.digits);
            out.digits = Number.isInteger(digits) && digits >= 0 ? digits : 2;
        }
        return out;
    });
}

function countBlanks(body) {
    return (String(body || '').match(/#BLANK/g) || []).length;
}

function fillBlankAnswerList(q) {
    const n = Math.max(1, countBlanks(q.body));
    const raw = Array.isArray(q.correct_answer)
        ? q.correct_answer
        : (typeof q.correct_answer === 'string' ? [q.correct_answer] : []);
    return Array.from({ length: n }, (_, i) => (raw[i] === undefined || raw[i] === null ? '' : String(raw[i])));
}

function sanitizeSingleQuestion(q) {
    if (!q || typeof q !== 'object') return createDefaultQuestion('multiple_choice');
    const type = q.type || 'multiple_choice';
    const clean = {
        type: type,
        body: q.body !== undefined ? String(q.body) : '',
    };
    if (q.points !== undefined && q.points !== null && q.points !== '' && !isNaN(Number(q.points))) {
        clean.points = Number(q.points);
    }
    if (type === 'multiple_choice') {
        clean.options = Array.isArray(q.options) && q.options.length > 0 ? q.options.map(String) : ['Option A', 'Option B'];
        if (q.correct_answer !== undefined && q.correct_answer !== null && q.correct_answer !== '' && !isNaN(Number(q.correct_answer))) {
            clean.correct_answer = parseInt(q.correct_answer, 10);
        } else {
            clean.correct_answer = null;
        }
    } else if (type === 'true_false') {
        clean.options = Array.isArray(q.options) && q.options.length > 0 ? q.options.map(String) : ['Statement 1'];
        if (Array.isArray(q.correct_answer)) {
            clean.correct_answer = q.correct_answer.map((i) => parseInt(i, 10)).filter((i) => !isNaN(i));
        } else {
            clean.correct_answer = null;
        }
    } else if (type === 'fill_blank') {
        const answers = fillBlankAnswerList(q).map((a) => a.trim());
        if (answers.every((a) => !a)) {
            clean.correct_answer = null;
        } else {
            clean.correct_answer = answers.length === 1 ? answers[0] : answers;
        }
        const cleanRubric = serializeRubricList(q.rubric);
        if (cleanRubric) {
            clean.rubric = cleanRubric;
        }
    } else if (type === 'essay') {
        clean.num_lines = q.num_lines !== undefined && q.num_lines !== null && !isNaN(Number(q.num_lines)) ? Math.max(0, parseInt(q.num_lines, 10)) : 3;
        if (typeof q.correct_answer === 'string' && q.correct_answer.trim()) {
            clean.correct_answer = q.correct_answer.trim();
        } else {
            clean.correct_answer = null;
        }
        const cleanRubric = serializeRubricList(q.rubric);
        if (cleanRubric) {
            clean.rubric = cleanRubric;
        }
    }
    return applyShuffleOverrides(clean, q);
}

function renderBuilderUI() {
    const container = document.getElementById('builder-form-container');
    if (!container) return;

    let html = '';
    html += renderTopLevelSettingsHtml();
    html += renderSectionsAndQuestionsHtml();

    container.innerHTML = html;
    attachBuilderEventListeners();
    ensureBuilderPreviewListeners();
    if (typeof enhanceTypstMarkupFields === "function") enhanceTypstMarkupFields(container);
    syncGlobalVarsPanel();
    updatePreviewModeButtons();
}

function renderTopLevelSettingsHtml() {
    const m = builderState.master;
    return `
        <div class="builder-card builder-top-settings">
            <div class="builder-card-header-bar">
                <h3 class="builder-card-title">Top-Level Settings</h3>
            </div>

            <div class="builder-form-row">
                <div class="builder-control-group">
                    <label for="builder-assn-type">Assignment Type</label>
                    <select id="builder-assn-type" class="builder-input-select">
                        <option value="quiz" ${m.assn_type === 'quiz' ? 'selected' : ''}>Quiz</option>
                        <option value="worksheet" ${m.assn_type === 'worksheet' ? 'selected' : ''}>Worksheet</option>
                        <option value="exam" ${m.assn_type === 'exam' ? 'selected' : ''}>Exam</option>
                    </select>
                </div>
                <div class="builder-control-group builder-title-group">
                    <label for="builder-title">Assignment Title</label>
                    <input type="text" id="builder-title" class="builder-input-full" value="${escapeHtml(m.title)}" placeholder="e.g. Midterm 1">
                </div>
                <div class="builder-control-group">
                    <label for="builder-version-count">Versions</label>
                    <input type="number" id="builder-version-count" class="builder-input-sm" min="1" step="1" value="${m.version_count || 1}">
                </div>
            </div>

            <div class="builder-checkbox-row">
                <span class="builder-checkbox-row-label">Shuffle</span>
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-shuffle-s" ${m.shuffle_sections ? 'checked' : ''} ${m.use_sections ? '' : 'disabled'}>
                    <span>Sections</span>
                </label>
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-shuffle-q" ${m.shuffle_questions ? 'checked' : ''}>
                    <span>Questions</span>
                </label>
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-shuffle-a" ${m.shuffle_answers ? 'checked' : ''}>
                    <span>Answers</span>
                </label>
            </div>

            <div class="builder-checkbox-row">
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-single-doc" ${m.single_doc_export ? 'checked' : ''}>
                    <span>Single Doc Export</span>
                </label>
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-double-sided" ${m.will_print_double_sided ? 'checked' : ''}>
                    <span>Print Double-Sided</span>
                </label>
            </div>

            <div class="builder-optional-toggles-row">
                <button type="button" class="builder-toggle-link ${builderToggles.intro ? 'active' : ''}" onclick="toggleTopSetting('intro')">
                    ${builderToggles.intro ? '−' : '+'} Intro Content
                </button>
                <button type="button" class="builder-toggle-link ${builderToggles.seed ? 'active' : ''}" onclick="toggleTopSetting('seed')">
                    ${builderToggles.seed ? '−' : '+'} Random Seed
                </button>
                <button type="button" class="builder-toggle-link ${builderToggles.globalVars ? 'active' : ''}" onclick="toggleTopSetting('globalVars')">
                    ${builderToggles.globalVars ? '−' : '+'} Global Vars
                </button>
            </div>

            ${builderToggles.intro ? `
                <div class="builder-field-block" style="margin-top: 8px;">
                    <label for="builder-intro">Intro Content <em>(Typst markup)</em></label>
                    <textarea id="builder-intro" class="builder-textarea" rows="2" placeholder="e.g. Please show all work and write clearly.">${escapeHtml(m.intro_content)}</textarea>
                </div>
            ` : ''}

            ${builderToggles.seed ? `
                <div class="builder-form-row" style="margin-top: 8px;">
                    <div class="builder-control-group">
                        <label for="builder-seed">Random Seed</label>
                        <input type="number" id="builder-seed" class="builder-input-md" min="1" step="1" value="${m.seed || 1234}">
                    </div>
                </div>
            ` : ''}
        </div>
    `;
}

// --- Global Vars panel (bottom half of the preview pane) ---

let globalVarsPanelRendered = false;

function markGlobalVarsPanelStale() {
    globalVarsPanelRendered = false;
}

function syncGlobalVarsPanel() {
    const panel = document.getElementById('builder-global-vars-panel');
    if (!panel) return;
    panel.classList.toggle('hidden', !builderToggles.globalVars);
    if (builderToggles.globalVars && !globalVarsPanelRendered) renderGlobalVarsPanel();
}

function renderRandomVarRowHtml(v, i) {
    const nameOk = !v.name || RANDOM_VAR_NAME_RE.test(v.name.trim());
    const step = v.type === 'int' ? '1' : 'any';
    return `
        <input type="text" class="builder-input ${nameOk ? '' : 'is-invalid'}" value="${escapeHtml(v.name)}" placeholder="name" title="${nameOk ? '' : 'Use letters, digits, _ or -, starting with a letter or _'}" oninput="updateRandomVar(${i}, 'name', this.value, this)">
        <select class="builder-input" onchange="updateRandomVar(${i}, 'type', this.value)">
            <option value="int" ${v.type === 'int' ? 'selected' : ''}>int</option>
            <option value="float" ${v.type === 'float' ? 'selected' : ''}>float</option>
        </select>
        <input type="number" class="builder-input" step="${step}" value="${v.min ?? ''}" oninput="updateRandomVar(${i}, 'min', this.value)">
        <input type="number" class="builder-input" step="${step}" value="${v.max ?? ''}" oninput="updateRandomVar(${i}, 'max', this.value)">
        ${v.type === 'float'
            ? `<input type="number" class="builder-input" min="0" step="1" value="${v.digits ?? 2}" oninput="updateRandomVar(${i}, 'digits', this.value)">`
            : '<span class="builder-rv-na">—</span>'}
        <button type="button" class="btn-icon btn-danger" title="Delete random var" onclick="removeRandomVar(${i})"><span>🗑</span></button>
    `;
}

function renderGlobalVarsPanel() {
    const panel = document.getElementById('builder-global-vars-panel');
    if (!panel) return;
    const m = builderState.master;
    const randomVars = Array.isArray(m.random_vars) ? m.random_vars : [];
    panel.innerHTML = `
        <div class="builder-gv-header">
            <h3>Global Vars</h3>
            <button type="button" class="btn-icon" title="Close" onclick="toggleTopSetting('globalVars')"><span>✕</span></button>
        </div>
        <div class="builder-gv-subhead">Random Vars <em>(new values for each version)</em></div>
        ${randomVars.length === 0 ? `
            <div class="builder-rv-empty">No random vars yet.</div>
        ` : `
            <div class="builder-rv-table">
                <span class="builder-rv-head">Name</span>
                <span class="builder-rv-head">Type</span>
                <span class="builder-rv-head">Min</span>
                <span class="builder-rv-head">Max</span>
                <span class="builder-rv-head">Decimals</span>
                <span></span>
                ${randomVars.map(renderRandomVarRowHtml).join('')}
            </div>
        `}
        <div class="builder-rv-add-row">
            <select id="builder-rv-new-type" class="builder-input-select" style="width: 90px !important;">
                <option value="int">int</option>
                <option value="float">float</option>
            </select>
            <button type="button" class="btn-sm" onclick="addRandomVar(document.getElementById('builder-rv-new-type').value)">+ Add Random Var</button>
        </div>
        <div class="builder-gv-subhead">General Vars <em>(Typst code that can use the random vars and must end in a dictionary)</em></div>
        <textarea id="builder-global-vars" class="builder-textarea" rows="8" spellcheck="false" data-typst-mode="code" oninput="updateGeneralVars(this.value)">${escapeHtml(m.global_vars || '')}</textarea>
    `;
    globalVarsPanelRendered = true;
    if (typeof enhanceTypstMarkupFields === 'function') enhanceTypstMarkupFields(panel);
}

function addRandomVar(type) {
    if (!Array.isArray(builderState.master.random_vars)) builderState.master.random_vars = [];
    builderState.master.random_vars.push(createDefaultRandomVar(type));
    renderGlobalVarsPanel();
    const rows = document.querySelectorAll('#builder-global-vars-panel .builder-rv-table input[type="text"]');
    if (rows.length) rows[rows.length - 1].focus();
}

function removeRandomVar(i) {
    const list = builderState.master.random_vars;
    if (!Array.isArray(list) || !list[i]) return;
    list.splice(i, 1);
    renderGlobalVarsPanel();
    scheduleQuestionPreview();
}

function updateRandomVar(i, field, value, inputEl) {
    const v = builderState.master.random_vars && builderState.master.random_vars[i];
    if (!v) return;
    if (field === 'name' || field === 'type') {
        v[field] = value;
    } else {
        v[field] = value === '' ? '' : Number(value);
    }
    if (field === 'name' && inputEl) {
        const ok = !value.trim() || RANDOM_VAR_NAME_RE.test(value.trim());
        inputEl.classList.toggle('is-invalid', !ok);
        inputEl.title = ok ? '' : 'Use letters, digits, _ or -, starting with a letter or _';
    }
    if (field === 'type') renderGlobalVarsPanel();
    scheduleQuestionPreview();
}

function updateGeneralVars(value) {
    builderState.master.global_vars = value;
    scheduleQuestionPreview();
}

function setBuilderPreviewIsKey(isKey) {
    if (builderState.previewIsKey === isKey) return;
    builderState.previewIsKey = isKey;
    updatePreviewModeButtons();
    if (builderState.previewKind === 'full') {
        triggerPreview();
    } else if (builderLastQuestionPath) {
        requestQuestionPreview();
    }
}

function updatePreviewModeButtons() {
    const keyBtn = document.getElementById('builder-preview-mode-key');
    const exampleBtn = document.getElementById('builder-preview-mode-example');
    if (keyBtn) keyBtn.classList.toggle('active', builderState.previewIsKey);
    if (exampleBtn) exampleBtn.classList.toggle('active', !builderState.previewIsKey);
}

function renderSectionsAndQuestionsHtml() {
    const m = builderState.master;
    let html = `
        <div class="builder-card" style="margin-top: 14px;">
            <div class="builder-section-toggle-header">
                <label class="builder-checkbox-label" style="font-size: 1.05rem; font-weight: bold;">
                    <input type="checkbox" id="builder-use-sections" ${m.use_sections ? 'checked' : ''} onchange="toggleUseSections(this.checked)">
                    <span>Use Sections</span>
                </label>
                ${m.use_sections ? `
                    <div class="builder-section-count-row">
                        <label for="builder-section-count"><strong>Number of Sections:</strong></label>
                        <input type="number" id="builder-section-count" min="1" max="20" class="builder-input-sm" value="${(m.sections || []).length}" onchange="setSectionCount(parseInt(this.value, 10))">
                        <button type="button" class="btn-sm" onclick="addSection()">+ Add Section</button>
                    </div>
                ` : ''}
            </div>
    `;

    if (m.use_sections) {
        html += `<div class="builder-sections-list">`;
        (m.sections || []).forEach((sec, sIdx) => {
            html += renderSectionCardHtml(sec, sIdx);
        });
        html += `</div>`;
    } else {
        html += `<div class="builder-questions-list">`;
        (m.questions || []).forEach((qItem, qIdx) => {
            html += renderQuestionOrBankHtml(qItem, qIdx, false, null, null);
        });
        html += renderAddQuestionButtonHtml('root', false, null, null);
        html += `</div>`;
    }

    html += `</div>`;
    return html;
}

function renderSectionCardHtml(sec, sIdx) {
    const questions = sec.questions || [];
    return `
        <div class="builder-section-card" data-section-index="${sIdx}">
            <div class="builder-section-header">
                <div class="builder-section-header-row">
                    <span class="builder-section-badge">Section ${sIdx + 1}</span>
                    <input type="text" class="builder-input builder-section-title-input" value="${escapeHtml(sec.section_title)}" placeholder="Section Title (e.g. Part I: Multiple Choice)" oninput="updateSectionTitle(${sIdx}, this.value)">
                    <div class="builder-item-actions">
                        <button type="button" class="btn-icon" title="Move Up" ${sIdx === 0 ? 'disabled' : ''} onclick="moveSection(${sIdx}, -1)"><span>▲</span></button>
                        <button type="button" class="btn-icon" title="Move Down" ${sIdx === (builderState.master.sections.length - 1) ? 'disabled' : ''} onclick="moveSection(${sIdx}, 1)"><span>▼</span></button>
                        <button type="button" class="btn-icon btn-danger" title="Delete Section" onclick="deleteSection(${sIdx})"><span>🗑</span></button>
                    </div>
                </div>
                <div>
                    <button type="button" class="builder-toggle-link ${sec.showIntro ? 'active' : ''}" onclick="toggleSectionIntro(${sIdx})">
                        ${sec.showIntro ? '−' : '+'} Intro Content
                    </button>
                </div>
                ${sec.showIntro ? `
                    <textarea class="builder-textarea" rows="2" placeholder="Intro content under this section title (optional Typst markup)" oninput="updateSectionIntro(${sIdx}, this.value)">${escapeHtml(sec.intro_content || '')}</textarea>
                ` : ''}
            </div>
            <div class="builder-shuffle-row">
                ${renderShuffleOverrideSelect(sec, 'shuffle_questions', `updateSectionShuffle(${sIdx}, 'shuffle_questions', this.value)`, 'Shuffle questions')}
                ${renderShuffleOverrideSelect(sec, 'shuffle_answers', `updateSectionShuffle(${sIdx}, 'shuffle_answers', this.value)`, 'Shuffle answers')}
            </div>
            <div class="builder-questions-list" style="margin-top: 10px;">
                ${questions.map((qItem, qIdx) => renderQuestionOrBankHtml(qItem, qIdx, false, sIdx, null)).join('')}
                ${renderAddQuestionButtonHtml(`sec-${sIdx}`, false, sIdx, null)}
            </div>
        </div>
    `;
}

function renderQuestionOrBankHtml(item, idx, isInsideBank, sIdx, bIdx) {
    if (item && typeof item === 'object' && 'pick' in item) {
        return renderBankCardHtml(item, idx, sIdx);
    }
    return renderQuestionCardHtml(item, idx, isInsideBank, sIdx, bIdx);
}

function renderBankCardHtml(bank, bIdx, sIdx) {
    const subQuestions = bank.questions || [];
    const pick = bank.pick || 1;
    return `
        <div class="builder-bank-card" data-bank-index="${bIdx}" ${sIdx !== null ? `data-section-index="${sIdx}"` : ''}>
            <div class="builder-bank-header">
                <div class="builder-bank-badge-wrap">
                    <span class="builder-bank-badge">Question Bank (Pick)</span>
                    <span class="builder-bank-info">Randomly chooses <strong>${pick}</strong> of <strong>${subQuestions.length}</strong> questions</span>
                </div>
                <div class="builder-bank-pick-row">
                    <label><strong>Pick count:</strong></label>
                    <input type="number" min="1" max="${Math.max(1, subQuestions.length - 1)}" class="builder-input-xs" value="${pick}" onchange="updateBankPick(${sIdx}, ${bIdx}, parseInt(this.value, 10))">
                </div>
                <div class="builder-item-actions">
                    <button type="button" class="btn-icon" title="Move Up" onclick="moveItem(${sIdx}, ${bIdx}, -1)"><span>▲</span></button>
                    <button type="button" class="btn-icon" title="Move Down" onclick="moveItem(${sIdx}, ${bIdx}, 1)"><span>▼</span></button>
                    <button type="button" class="btn-icon btn-danger" title="Delete Bank" onclick="deleteItem(${sIdx}, ${bIdx})"><span>🗑</span></button>
                </div>
            </div>
            <div class="builder-shuffle-row">
                ${renderShuffleOverrideSelect(bank, 'shuffle_questions', `updateBankShuffle(${sIdx}, ${bIdx}, 'shuffle_questions', this.value)`, 'Shuffle questions')}
                ${renderShuffleOverrideSelect(bank, 'shuffle_answers', `updateBankShuffle(${sIdx}, ${bIdx}, 'shuffle_answers', this.value)`, 'Shuffle answers')}
            </div>
            <div class="builder-bank-subquestions">
                ${subQuestions.map((subQ, subIdx) => renderQuestionCardHtml(subQ, subIdx, true, sIdx, bIdx)).join('')}
                ${renderAddQuestionButtonHtml(`bank-${sIdx !== null ? sIdx : 'root'}-${bIdx}`, true, sIdx, bIdx)}
            </div>
        </div>
    `;
}

function renderAddQuestionButtonHtml(key, isInsideBank, sIdx, bIdx) {
    const isExpanded = builderState.activeAddMenuKey === key;
    if (!isExpanded) {
        return `
            <div class="builder-add-q-wide" onclick="openAddQuestionMenu('${key}')" title="Add Question">
                <span class="builder-add-q-icon">+</span>
                <span class="builder-add-q-text">Add Question</span>
            </div>
        `;
    }

    return `
        <div class="builder-add-q-menu">
            ${!isInsideBank ? `
                <button type="button" class="builder-type-btn btn-bank" onclick="addQuestionItem('bank', ${sIdx}, ${bIdx})">
                    <span class="btn-type-label">🗂 Question Bank</span>
                </button>
            ` : ''}
            <button type="button" class="builder-type-btn btn-mc" onclick="addQuestionItem('multiple_choice', ${sIdx}, ${bIdx})">
                <span class="btn-type-label">🔘 Multiple Choice</span>
            </button>
            <button type="button" class="builder-type-btn btn-tf" onclick="addQuestionItem('true_false', ${sIdx}, ${bIdx})">
                <span class="btn-type-label">☑️ True/False</span>
            </button>
            <button type="button" class="builder-type-btn btn-fill" onclick="addQuestionItem('fill_blank', ${sIdx}, ${bIdx})">
                <span class="btn-type-label">✏️ Fill-in-the-Blank</span>
            </button>
            <button type="button" class="builder-type-btn btn-essay" onclick="addQuestionItem('essay', ${sIdx}, ${bIdx})">
                <span class="btn-type-label">📝 Essay</span>
            </button>
            <button type="button" class="builder-type-btn btn-cancel" onclick="closeAddQuestionMenu()">
                <span class="btn-type-label">✕ Cancel</span>
            </button>
        </div>
    `;
}

function formatBuilderQuestionId(sIdx, bIdx, qIdx) {
    const parts = [];
    if (sIdx !== null && sIdx !== undefined && sIdx !== '') parts.push(Number(sIdx));
    if (bIdx !== null && bIdx !== undefined && bIdx !== '') parts.push(Number(bIdx));
    parts.push(Number(qIdx));
    return 'q' + parts.join('.');
}

function renderQuestionCardHtml(q, qIdx, isInsideBank, sIdx, bIdx) {
    const typeNames = {
        multiple_choice: 'Multiple Choice',
        true_false: 'True / False',
        fill_blank: 'Fill-in-the-Blank',
        essay: 'Essay',
    };
    const typeBadges = {
        multiple_choice: 'badge-mc',
        true_false: 'badge-tf',
        fill_blank: 'badge-fill',
        essay: 'badge-essay',
    };

    const typeLabel = typeNames[q.type] || q.type;
    const badgeClass = typeBadges[q.type] || 'badge-default';

    return `
        <div class="builder-question-card" data-q-preview="1" data-s-idx="${sIdx === null || sIdx === undefined ? '' : sIdx}" data-b-idx="${bIdx === null || bIdx === undefined ? '' : bIdx}" data-q-idx="${qIdx}">
            <div class="builder-question-header">
                <div class="builder-q-badge-wrap">
                    <span class="builder-q-num">${formatBuilderQuestionId(sIdx, bIdx, qIdx)}</span>
                    <span class="builder-type-badge ${badgeClass}">${typeLabel}</span>
                </div>
                <div class="builder-points-row">
                    <label>Points:</label>
                    <input type="number" step="any" min="0" class="builder-input-points" value="${q.points !== undefined && q.points !== null ? q.points : ''}" placeholder="0" oninput="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'points', this.value === '' ? '' : Number(this.value))">
                </div>
                <div class="builder-item-actions">
                    <button type="button" class="btn-icon" title="Duplicate" onclick="duplicateQuestion(${sIdx}, ${bIdx}, ${qIdx})"><span>📋</span></button>
                    <button type="button" class="btn-icon" title="Move Up" onclick="moveQuestion(${sIdx}, ${bIdx}, ${qIdx}, -1)"><span>▲</span></button>
                    <button type="button" class="btn-icon" title="Move Down" onclick="moveQuestion(${sIdx}, ${bIdx}, ${qIdx}, 1)"><span>▼</span></button>
                    <button type="button" class="btn-icon btn-danger" title="Delete Question" onclick="deleteQuestion(${sIdx}, ${bIdx}, ${qIdx})"><span>🗑</span></button>
                </div>
            </div>
            ${(q.type === 'multiple_choice' || q.type === 'true_false') ? `
                <div class="builder-shuffle-row">
                    ${renderShuffleOverrideSelect(q, 'shuffle_answers', `updateQuestionShuffle(${sIdx}, ${bIdx}, ${qIdx}, 'shuffle_answers', this.value)`, 'Shuffle answers')}
                </div>
            ` : ''}

            <div class="builder-field-block" style="margin-top: 10px;">
                <label>Question Body <em>(Typst markup)</em></label>
                <textarea class="builder-textarea" rows="2" placeholder="${q.type === 'fill_blank' ? 'e.g. Mitochondria is the #BLANK of the cell.' : 'Enter question text...'}" oninput="updateQuestionBody(${sIdx}, ${bIdx}, ${qIdx}, this.value)">${escapeHtml(q.body || '')}</textarea>
            </div>

            ${renderQuestionTypeSpecificHtml(q, qIdx, isInsideBank, sIdx, bIdx)}
        </div>
    `;
}

function fillBlankAnswersId(sIdx, bIdx, qIdx) {
    return `builder-fill-answers-${sIdx ?? 'r'}-${bIdx ?? 'r'}-${qIdx}`;
}

function renderFillBlankAnswerFieldsHtml(q, sIdx, bIdx, qIdx) {
    const answers = fillBlankAnswerList(q);
    return answers.map((a, i) => `
        <div class="builder-field-block">
            <label>Correct Answer${answers.length > 1 ? ` — Blank ${i + 1}` : ''} <em>(Typst markup)</em></label>
            <input type="text" class="builder-input builder-blank-answer-input" value="${escapeHtml(a)}" placeholder="e.g. Paris, or #b" oninput="updateFillBlankAnswer(${sIdx}, ${bIdx}, ${qIdx}, ${i}, this.value)">
        </div>
    `).join('');
}

// Re-renders only the answer fields, so typing in the body keeps its focus when the #BLANK count changes.
function updateQuestionBody(sIdx, bIdx, qIdx, value) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q) return;
    const blanksBefore = countBlanks(q.body);
    q.body = value;
    if (q.type !== 'fill_blank' || countBlanks(value) === blanksBefore) return;
    q.correct_answer = fillBlankAnswerList(q);
    const container = document.getElementById(fillBlankAnswersId(sIdx, bIdx, qIdx));
    if (!container) return;
    container.innerHTML = renderFillBlankAnswerFieldsHtml(q, sIdx, bIdx, qIdx);
    if (typeof enhanceTypstMarkupFields === 'function') enhanceTypstMarkupFields(container);
}

function renderQuestionTypeSpecificHtml(q, qIdx, isInsideBank, sIdx, bIdx) {
    if (q.type === 'multiple_choice') {
        const options = Array.isArray(q.options) ? q.options : [];
        const correct = q.correct_answer;
        return `
            <div class="builder-options-block">
                <div class="builder-options-header">
                    <label style="font-weight: 600; font-size: 0.86rem; color: var(--text-subtle);">Options &amp; Correct Answer</label>
                    <button type="button" class="btn-sm" onclick="addOption(${sIdx}, ${bIdx}, ${qIdx})">+ Add Option</button>
                </div>
                <div class="builder-options-list">
                    <div class="builder-option-row">
                        <input type="radio" name="mc-ans-${sIdx}-${bIdx}-${qIdx}" ${correct === null || correct === undefined ? 'checked' : ''} onchange="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'correct_answer', null)">
                        <span style="font-size: 0.85rem; color: var(--text-muted);">None / Participation credit (any chosen option gets full points)</span>
                    </div>
                    ${options.map((opt, oIdx) => `
                        <div class="builder-option-row">
                            <input type="radio" name="mc-ans-${sIdx}-${bIdx}-${qIdx}" title="Mark as correct answer" ${correct === oIdx ? 'checked' : ''} onchange="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'correct_answer', ${oIdx})">
                            <span class="builder-option-letter">${String.fromCharCode(65 + oIdx)}.</span>
                            <input type="text" class="builder-input builder-option-input" value="${escapeHtml(opt)}" placeholder="Option text (Typst markup)" oninput="updateOptionText(${sIdx}, ${bIdx}, ${qIdx}, ${oIdx}, this.value)">
                            <button type="button" class="btn-icon btn-danger" title="Remove Option" ${options.length <= 1 ? 'disabled' : ''} onclick="removeOption(${sIdx}, ${bIdx}, ${qIdx}, ${oIdx})">✕</button>
                        </div>
                    `).join('')}
                </div>
            </div>
        `;
    }

    if (q.type === 'true_false') {
        const options = Array.isArray(q.options) ? q.options : [];
        const correct = Array.isArray(q.correct_answer) ? q.correct_answer : [];
        return `
            <div class="builder-options-block">
                <div class="builder-options-header">
                    <label style="font-weight: 600; font-size: 0.86rem; color: var(--text-subtle);">Statements (check for True)</label>
                    <button type="button" class="btn-sm" onclick="addOption(${sIdx}, ${bIdx}, ${qIdx})">+ Add Statement</button>
                </div>
                <div class="builder-options-list">
                    ${options.map((opt, oIdx) => {
                        const isTrue = correct.includes(oIdx);
                        return `
                            <div class="builder-option-row">
                                <input type="checkbox" title="Check if True" ${isTrue ? 'checked' : ''} onchange="toggleTrueFalseAnswer(${sIdx}, ${bIdx}, ${qIdx}, ${oIdx}, this.checked)">
                                <span class="builder-tf-tag ${isTrue ? 'tag-true' : 'tag-false'}">${isTrue ? 'TRUE' : 'FALSE'}</span>
                                <input type="text" class="builder-input builder-option-input" value="${escapeHtml(opt)}" placeholder="Statement text (Typst markup)" oninput="updateOptionText(${sIdx}, ${bIdx}, ${qIdx}, ${oIdx}, this.value)">
                                <button type="button" class="btn-icon btn-danger" title="Remove Statement" ${options.length <= 1 ? 'disabled' : ''} onclick="removeOption(${sIdx}, ${bIdx}, ${qIdx}, ${oIdx})">✕</button>
                            </div>
                        `;
                    }).join('')}
                </div>
            </div>
        `;
    }

    if (q.type === 'fill_blank') {
        return `
            <div class="builder-options-block">
                <div id="${fillBlankAnswersId(sIdx, bIdx, qIdx)}">
                    ${renderFillBlankAnswerFieldsHtml(q, sIdx, bIdx, qIdx)}
                </div>
                ${renderRubricBuilderHtml(q, sIdx, bIdx, qIdx)}
            </div>
        `;
    }

    if (q.type === 'essay') {
        return `
            <div class="builder-options-block">
                <div class="builder-form-row">
                    <div class="builder-control-group">
                        <label>Blank Lines</label>
                        <input type="number" min="0" max="50" class="builder-input-xs" value="${q.num_lines !== undefined ? q.num_lines : 3}" oninput="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'num_lines', parseInt(this.value, 10) || 0)">
                    </div>
                </div>
                <div class="builder-field-block">
                    <label>Correct Answer <em>(optional Typst markup, shown on the key and when grading)</em></label>
                    <textarea class="builder-textarea" rows="2" placeholder="e.g. The frequency is #calc.round(b / (b + c), digits: 2)." oninput="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'correct_answer', this.value)">${escapeHtml(q.correct_answer || '')}</textarea>
                </div>
                ${renderRubricBuilderHtml(q, sIdx, bIdx, qIdx)}
            </div>
        `;
    }

    return '';
}

function renderRubricCardHtml(r, rIdx, sIdx, bIdx, qIdx) {
    const chips = Array.isArray(r.chips) && r.chips.length >= 2 ? r.chips : [
        { score: 0, desc: '' },
        { score: Number(r.max) || 1, desc: '' }
    ];
    return `
        <div class="builder-rubric-card">
            <div class="builder-rubric-row-header">
                <div class="builder-rubric-field-inline" style="flex: 1; min-width: 160px;">
                    <label>Criterion Name:</label>
                    <input type="text" class="builder-input" style="flex: 1; height: 30px;" value="${escapeHtml(r.desc || '')}" placeholder="e.g. Form / Style" oninput="updateRubricDesc(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx}, this.value)">
                </div>
                <div class="builder-rubric-field-inline">
                    <label>Max Pts:</label>
                    <input type="number" step="any" min="0.1" class="builder-input-points" style="height: 30px;" value="${r.max !== undefined ? r.max : 1}" oninput="updateRubricMax(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx}, this.value)">
                </div>
                <button type="button" class="btn-icon btn-danger" style="margin-left: auto;" title="Delete Criterion" onclick="removeRubricItem(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx})"><span>🗑</span></button>
            </div>
            <div class="builder-rubric-chip-track">
                ${chips.map((chip, cIdx) => {
                    const isLowest = cIdx === 0;
                    const isHighest = cIdx === chips.length - 1;
                    const canDelete = !isLowest && !isHighest;
                    const nextChip = chips[cIdx + 1];
                    return `
                        <div class="builder-rubric-chip">
                            <div class="builder-rubric-chip-top">
                                ${isLowest || isHighest ? `
                                    <span class="rubric-chip-score">${chip.score} pts</span>
                                ` : `
                                    <div class="builder-rubric-chip-score-edit">
                                        <input type="number" step="any" class="builder-rubric-chip-score-input" value="${chip.score}" title="Score value" onchange="updateRubricChipScore(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx}, ${cIdx}, this.value)">
                                        <span style="font-size: 0.75rem; font-weight: 600;">pts</span>
                                    </div>
                                `}
                                ${canDelete ? `
                                    <button type="button" class="builder-rubric-chip-del-btn" title="Delete Score Chip" onclick="removeRubricChip(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx}, ${cIdx})">✕</button>
                                ` : ''}
                            </div>
                            <input type="text" class="builder-rubric-chip-label-input" value="${escapeHtml(chip.desc || '')}" placeholder="Description..." oninput="updateRubricChipDesc(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx}, ${cIdx}, this.value)">
                        </div>
                        ${nextChip ? `
                            <button type="button" class="builder-rubric-add-chip-btn" title="Add chip between ${chip.score} and ${nextChip.score}" onclick="addRubricChip(${sIdx}, ${bIdx}, ${qIdx}, ${rIdx}, ${cIdx})">+</button>
                        ` : ''}
                    `;
                }).join('')}
            </div>
        </div>
    `;
}

function renderRubricBuilderHtml(q, sIdx, bIdx, qIdx) {
    const rubric = Array.isArray(q.rubric) ? q.rubric : [];
    const rubricSum = rubric.reduce((sum, r) => sum + (Number(r.max) || 0), 0);
    const qPoints = q.points !== undefined && q.points !== null && q.points !== '' ? Number(q.points) : null;
    
    let warningHtml = '';
    if (rubric.length > 0) {
        if (qPoints === null || isNaN(qPoints)) {
            warningHtml = `
                <div class="builder-rubric-warning error">
                    <span>⚠️</span>
                    <span>Question points is not set. Rubric max points sum to <strong>${rubricSum}</strong> pts.</span>
                </div>
            `;
        } else {
            const diff = rubricSum - qPoints;
            if (Math.abs(diff) > 0.001) {
                const diffStr = (diff > 0 ? '+' : '') + (Math.round(diff * 100) / 100);
                warningHtml = `
                    <div class="builder-rubric-warning error">
                        <span>⚠️</span>
                        <span>Rubric max sum (<strong>${rubricSum}</strong> pts) does not equal question points (<strong>${qPoints}</strong> pts). Difference: <strong>${diffStr}</strong> pts.</span>
                    </div>
                `;
            } else {
                warningHtml = `
                    <div class="builder-rubric-warning ok">
                        <span>✓</span>
                        <span>Rubric max points match question total (<strong>${rubricSum}</strong> pts).</span>
                    </div>
                `;
            }
        }
    }

    return `
        <details class="builder-advanced-details" style="margin-top: 10px;" ${rubric.length > 0 ? 'open' : ''}>
            <summary style="font-weight: 600; color: var(--text-subtle); cursor: pointer;">Rubric Options (Optional for Grading) ${rubric.length > 0 ? `(${rubric.length} items)` : ''}</summary>
            <div class="builder-rubric-block">
                <div class="builder-rubric-header">
                    <span style="font-size: 0.84rem; color: var(--text-muted);">Define criteria and score chips for grading feedback.</span>
                    <button type="button" class="btn-sm" onclick="addRubricItem(${sIdx}, ${bIdx}, ${qIdx})">+ Add Rubric Item</button>
                </div>
                ${rubric.length === 0 ? `
                    <div style="font-size: 0.84rem; color: var(--text-muted); font-style: italic;">No rubric items defined. Question score will be entered directly.</div>
                ` : `
                    <div class="builder-rubric-list">
                        ${rubric.map((r, rIdx) => renderRubricCardHtml(r, rIdx, sIdx, bIdx, qIdx)).join('')}
                    </div>
                    ${warningHtml}
                `}
            </div>
        </details>
    `;
}

function attachBuilderEventListeners() {
    const assnType = document.getElementById('builder-assn-type');
    if (assnType) assnType.onchange = () => { builderState.master.assn_type = assnType.value; };

    const title = document.getElementById('builder-title');
    if (title) title.oninput = () => { builderState.master.title = title.value; };

    const intro = document.getElementById('builder-intro');
    if (intro) intro.oninput = () => { builderState.master.intro_content = intro.value; };

    const vCount = document.getElementById('builder-version-count');
    if (vCount) vCount.oninput = () => { builderState.master.version_count = parseInt(vCount.value, 10) || 1; };

    const seed = document.getElementById('builder-seed');
    if (seed) seed.oninput = () => { builderState.master.seed = parseInt(seed.value, 10) || 1234; };

    const shufQ = document.getElementById('builder-shuffle-q');
    if (shufQ) shufQ.onchange = () => { builderState.master.shuffle_questions = shufQ.checked; };

    const shufA = document.getElementById('builder-shuffle-a');
    if (shufA) shufA.onchange = () => { builderState.master.shuffle_answers = shufA.checked; };

    const shufS = document.getElementById('builder-shuffle-s');
    if (shufS) shufS.onchange = () => { builderState.master.shuffle_sections = shufS.checked; };

    const singleDoc = document.getElementById('builder-single-doc');
    if (singleDoc) singleDoc.onchange = () => { builderState.master.single_doc_export = singleDoc.checked; };

    const doubleSided = document.getElementById('builder-double-sided');
    if (doubleSided) doubleSided.onchange = () => { builderState.master.will_print_double_sided = doubleSided.checked; };
}

function openAddQuestionMenu(key) {
    builderState.activeAddMenuKey = key;
    renderBuilderUI();
}

function closeAddQuestionMenu() {
    builderState.activeAddMenuKey = null;
    renderBuilderUI();
}

function addQuestionItem(type, sIdx, bIdx) {
    const newItem = type === 'bank' ? createDefaultBank() : createDefaultQuestion(type);
    const targetList = getTargetQuestionList(sIdx, bIdx);
    targetList.push(newItem);
    builderState.activeAddMenuKey = null;
    renderBuilderUI();
}

function getTargetQuestionList(sIdx, bIdx) {
    const m = builderState.master;
    if (sIdx !== null && sIdx !== undefined) {
        const sec = m.sections[sIdx];
        if (bIdx !== null && bIdx !== undefined) {
            return sec.questions[bIdx].questions;
        }
        return sec.questions;
    } else {
        if (bIdx !== null && bIdx !== undefined) {
            return m.questions[bIdx].questions;
        }
        return m.questions;
    }
}

function getQuestionRef(sIdx, bIdx, qIdx) {
    const list = getTargetQuestionList(sIdx, bIdx);
    return list[qIdx];
}

function updateQuestionField(sIdx, bIdx, qIdx, field, val) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q) {
        q[field] = val;
    }
}

function updateOptionText(sIdx, bIdx, qIdx, oIdx, text) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q && Array.isArray(q.options)) {
        q.options[oIdx] = text;
    }
}

function addOption(sIdx, bIdx, qIdx) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q) {
        if (!Array.isArray(q.options)) q.options = [];
        q.options.push(q.type === 'multiple_choice' ? `Option ${String.fromCharCode(65 + q.options.length)}` : `Statement ${q.options.length + 1}`);
        renderBuilderUI();
    }
}

function removeOption(sIdx, bIdx, qIdx, oIdx) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q && Array.isArray(q.options) && q.options.length > 1) {
        q.options.splice(oIdx, 1);
        if (q.type === 'multiple_choice' && typeof q.correct_answer === 'number') {
            if (q.correct_answer === oIdx) q.correct_answer = null;
            else if (q.correct_answer > oIdx) q.correct_answer -= 1;
        } else if (q.type === 'true_false' && Array.isArray(q.correct_answer)) {
            q.correct_answer = q.correct_answer.filter((i) => i !== oIdx).map((i) => (i > oIdx ? i - 1 : i));
        }
        renderBuilderUI();
    }
}

function toggleTrueFalseAnswer(sIdx, bIdx, qIdx, oIdx, isChecked) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q) {
        if (!Array.isArray(q.correct_answer)) q.correct_answer = [];
        const idxInAns = q.correct_answer.indexOf(oIdx);
        if (isChecked && idxInAns < 0) {
            q.correct_answer.push(oIdx);
            q.correct_answer.sort((a, b) => a - b);
        } else if (!isChecked && idxInAns >= 0) {
            q.correct_answer.splice(idxInAns, 1);
        }
        renderBuilderUI();
    }
}

function updateFillBlankAnswer(sIdx, bIdx, qIdx, blankIdx, value) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q) return;
    const answers = fillBlankAnswerList(q);
    answers[blankIdx] = value;
    q.correct_answer = answers;
}

function duplicateQuestion(sIdx, bIdx, qIdx) {
    const list = getTargetQuestionList(sIdx, bIdx);
    if (list && list[qIdx]) {
        const copy = JSON.parse(JSON.stringify(list[qIdx]));
        list.splice(qIdx + 1, 0, copy);
        renderBuilderUI();
    }
}

function moveQuestion(sIdx, bIdx, qIdx, delta) {
    const list = getTargetQuestionList(sIdx, bIdx);
    const newIdx = qIdx + delta;
    if (list && newIdx >= 0 && newIdx < list.length) {
        const item = list.splice(qIdx, 1)[0];
        list.splice(newIdx, 0, item);
        renderBuilderUI();
    }
}

function deleteQuestion(sIdx, bIdx, qIdx) {
    const list = getTargetQuestionList(sIdx, bIdx);
    if (list && list[qIdx]) {
        list.splice(qIdx, 1);
        renderBuilderUI();
    }
}

function addRubricItem(sIdx, bIdx, qIdx) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q) {
        if (!Array.isArray(q.rubric)) q.rubric = [];
        q.rubric.push({
            desc: `Criterion ${q.rubric.length + 1}`,
            max: 1,
            chips: [
                { score: 0, desc: '' },
                { score: 1, desc: '' }
            ]
        });
        renderBuilderUI();
    }
}

function removeRubricItem(sIdx, bIdx, qIdx, rIdx) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q && Array.isArray(q.rubric)) {
        q.rubric.splice(rIdx, 1);
        renderBuilderUI();
    }
}

function updateRubricDesc(sIdx, bIdx, qIdx, rIdx, val) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q && Array.isArray(q.rubric) && q.rubric[rIdx]) {
        q.rubric[rIdx].desc = val;
    }
}

function updateRubricMax(sIdx, bIdx, qIdx, rIdx, val) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (q && Array.isArray(q.rubric) && q.rubric[rIdx]) {
        const num = Math.max(0.01, Number(val) || 0.01);
        q.rubric[rIdx].max = num;
        if (!Array.isArray(q.rubric[rIdx].chips) || q.rubric[rIdx].chips.length < 2) {
            q.rubric[rIdx].chips = [{ score: 0, desc: '' }, { score: num, desc: '' }];
        } else {
            q.rubric[rIdx].chips[q.rubric[rIdx].chips.length - 1].score = num;
        }
        renderBuilderUI();
    }
}

function addRubricChip(sIdx, bIdx, qIdx, rIdx, afterChipIdx) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q || !Array.isArray(q.rubric) || !q.rubric[rIdx]) return;
    const chips = q.rubric[rIdx].chips;
    if (!Array.isArray(chips) || afterChipIdx >= chips.length - 1) return;
    const leftScore = Number(chips[afterChipIdx].score) || 0;
    const rightScore = Number(chips[afterChipIdx + 1].score) || 1;
    const newScore = Math.round(((leftScore + rightScore) / 2) * 100) / 100;
    chips.splice(afterChipIdx + 1, 0, { score: newScore, desc: '' });
    renderBuilderUI();
}

function updateRubricChipScore(sIdx, bIdx, qIdx, rIdx, cIdx, val) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q || !Array.isArray(q.rubric) || !q.rubric[rIdx]) return;
    const chips = q.rubric[rIdx].chips;
    if (!Array.isArray(chips) || cIdx <= 0 || cIdx >= chips.length - 1) return;
    const leftScore = Number(chips[cIdx - 1].score) || 0;
    const rightScore = Number(chips[cIdx + 1].score) || 1;
    let num = Number(val);
    if (isNaN(num)) num = (leftScore + rightScore) / 2;
    num = Math.max(leftScore + 0.01, Math.min(rightScore - 0.01, num));
    chips[cIdx].score = Math.round(num * 100) / 100;
    renderBuilderUI();
}

function updateRubricChipDesc(sIdx, bIdx, qIdx, rIdx, cIdx, val) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q || !Array.isArray(q.rubric) || !q.rubric[rIdx]) return;
    const chips = q.rubric[rIdx].chips;
    if (Array.isArray(chips) && chips[cIdx]) {
        chips[cIdx].desc = val;
    }
}

function removeRubricChip(sIdx, bIdx, qIdx, rIdx, cIdx) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q || !Array.isArray(q.rubric) || !q.rubric[rIdx]) return;
    const chips = q.rubric[rIdx].chips;
    if (Array.isArray(chips) && cIdx > 0 && cIdx < chips.length - 1) {
        chips.splice(cIdx, 1);
        renderBuilderUI();
    }
}

function toggleUseSections(useSec) {
    builderState.master.use_sections = useSec;
    if (useSec && (!builderState.master.sections || builderState.master.sections.length === 0)) {
        builderState.master.sections = [
            {
                section_title: 'Section 1',
                intro_content: '',
                questions: builderState.master.questions && builderState.master.questions.length > 0
                    ? JSON.parse(JSON.stringify(builderState.master.questions))
                    : [createDefaultQuestion('multiple_choice')]
            }
        ];
    } else if (!useSec && (!builderState.master.questions || builderState.master.questions.length === 0)) {
        const firstSec = (builderState.master.sections && builderState.master.sections[0]) ? builderState.master.sections[0] : null;
        builderState.master.questions = firstSec && firstSec.questions && firstSec.questions.length > 0
            ? JSON.parse(JSON.stringify(firstSec.questions))
            : [createDefaultQuestion('multiple_choice')];
    }
    renderBuilderUI();
}

function setSectionCount(count) {
    const target = Math.max(1, count || 1);
    const secs = builderState.master.sections || [];
    while (secs.length < target) {
        secs.push(createDefaultSection(`Section ${secs.length + 1}`));
    }
    while (secs.length > target) {
        secs.pop();
    }
    builderState.master.sections = secs;
    renderBuilderUI();
}

function addSection() {
    if (!builderState.master.sections) builderState.master.sections = [];
    builderState.master.sections.push(createDefaultSection(`Section ${builderState.master.sections.length + 1}`));
    renderBuilderUI();
}

function updateSectionTitle(sIdx, title) {
    if (builderState.master.sections && builderState.master.sections[sIdx]) {
        builderState.master.sections[sIdx].section_title = title;
    }
}

function toggleSectionIntro(sIdx) {
    const sec = builderState.master.sections && builderState.master.sections[sIdx];
    if (!sec) return;
    sec.showIntro = !sec.showIntro;
    renderBuilderUI();
}

function updateSectionIntro(sIdx, intro) {
    if (builderState.master.sections && builderState.master.sections[sIdx]) {
        builderState.master.sections[sIdx].intro_content = intro;
    }
}

function moveSection(sIdx, delta) {
    const secs = builderState.master.sections;
    const newIdx = sIdx + delta;
    if (secs && newIdx >= 0 && newIdx < secs.length) {
        const sec = secs.splice(sIdx, 1)[0];
        secs.splice(newIdx, 0, sec);
        renderBuilderUI();
    }
}

function deleteSection(sIdx) {
    const secs = builderState.master.sections;
    if (secs && secs.length > 1) {
        secs.splice(sIdx, 1);
        renderBuilderUI();
    } else {
        showMessageModal({
            title: 'Notice',
            message: 'You must have at least one section when sections are enabled. You can uncheck "Use Sections" if you prefer a single question list.'
        });
    }
}

function updateBankPick(sIdx, bIdx, pick) {
    const list = getTargetQuestionList(sIdx, null);
    if (list && list[bIdx]) {
        list[bIdx].pick = Math.max(1, pick || 1);
        renderBuilderUI();
    }
}

function moveItem(sIdx, idx, delta) {
    const list = getTargetQuestionList(sIdx, null);
    const newIdx = idx + delta;
    if (list && newIdx >= 0 && newIdx < list.length) {
        const item = list.splice(idx, 1)[0];
        list.splice(newIdx, 0, item);
        renderBuilderUI();
    }
}

function deleteItem(sIdx, idx) {
    const list = getTargetQuestionList(sIdx, null);
    if (list && list[idx]) {
        list.splice(idx, 1);
        renderBuilderUI();
    }
}

// --- Preview & Save Functions ---

function parseIdxAttr(v) {
    if (v === undefined || v === null || v === '') return null;
    const n = Number(v);
    return Number.isInteger(n) ? n : null;
}

function questionPathFromEvent(e) {
    const node = e.target && e.target.closest && e.target.closest('[data-q-preview]');
    if (!node) return null;
    const qIdx = parseIdxAttr(node.getAttribute('data-q-idx'));
    if (qIdx === null) return null;
    return {
        sIdx: parseIdxAttr(node.getAttribute('data-s-idx')),
        bIdx: parseIdxAttr(node.getAttribute('data-b-idx')),
        qIdx,
    };
}

function shouldRefreshQuestionPreview(e) {
    if (!e || !e.target) return false;
    if (e.target.classList && e.target.classList.contains('builder-shuffle-select')) return false;
    if (e.target.closest && e.target.closest('[data-q-preview]')) return true;
    return e.target.id === 'builder-seed';
}

function ensureBuilderPreviewListeners() {
    const form = document.getElementById('builder-form-container');
    if (!form || form.dataset.qPreviewBound === '1') return;
    form.dataset.qPreviewBound = '1';
    form.addEventListener('focusin', onBuilderPreviewFocus);
    form.addEventListener('input', onBuilderPreviewInput);
    form.addEventListener('change', onBuilderPreviewInput);
}

function onBuilderPreviewFocus(e) {
    const path = questionPathFromEvent(e);
    if (!path) return;
    builderLastQuestionPath = path;
    scheduleQuestionPreview();
}

function onBuilderPreviewInput(e) {
    if (!shouldRefreshQuestionPreview(e)) return;
    const path = questionPathFromEvent(e);
    if (path) builderLastQuestionPath = path;
    scheduleQuestionPreview();
}

function scheduleQuestionPreview() {
    if (builderQuestionPreviewTimer) clearTimeout(builderQuestionPreviewTimer);
    builderQuestionPreviewTimer = setTimeout(() => {
        builderQuestionPreviewTimer = null;
        requestQuestionPreview();
    }, 300);
}

async function requestQuestionPreview() {
    const path = builderLastQuestionPath;
    if (!path) return;
    const q = getQuestionRef(path.sIdx, path.bIdx, path.qIdx);
    if (!q || typeof q !== 'object' || 'pick' in q) return;

    const seq = ++builderQuestionPreviewSeq;
    builderState.questionPreviewUpdating = true;
    builderState.previewKind = 'question';
    renderPreviewPane();

    const m = builderState.master;
    try {
        const res = await fetch('/api/preview_question', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                question: sanitizeSingleQuestion(q),
                global_vars: m.global_vars || '',
                random_vars: serializeRandomVars(m.random_vars),
                seed: typeof m.seed === 'number' && m.seed > 0 ? m.seed : 1234,
                is_key: builderState.previewIsKey,
                source_path: builderState.filePath || '',
            }),
        });
        const data = await res.json();
        if (seq !== builderQuestionPreviewSeq) return;
        if (!res.ok || data.status !== 'success') {
            builderState.questionPreviewError = data.message || 'Question preview failed.';
        } else {
            builderState.questionPreviewId = data.preview_id;
            builderState.questionPreviewHash = data.hash;
            builderState.questionPreviewError = null;
            if (data.preview_id) builderState.previewId = data.preview_id;
        }
    } catch (e) {
        if (seq !== builderQuestionPreviewSeq) return;
        builderState.questionPreviewError = 'Failed to connect to server: ' + (e.message || String(e));
    } finally {
        if (seq === builderQuestionPreviewSeq) {
            builderState.questionPreviewUpdating = false;
            renderPreviewPane();
        }
    }
}

function previewModeLabel() {
    return builderState.previewIsKey ? 'Key' : 'Example (version 0)';
}

function questionPreviewSrc() {
    if (!builderState.questionPreviewId || !builderState.questionPreviewHash) return '';
    return `/api/preview_question/${builderState.questionPreviewId}?h=${encodeURIComponent(builderState.questionPreviewHash)}`;
}

function renderQuestionPreviewInto(container, header) {
    const src = questionPreviewSrc();
    const updating = builderState.questionPreviewUpdating;
    const qErr = builderState.questionPreviewError;
    if (header) {
        header.textContent = updating ? 'Question preview · updating…' : `Question preview · ${previewModeLabel()}`;
    }

    let card = container.querySelector('.builder-preview-question-card');
    let img = container.querySelector('img.builder-preview-svg');
    let errBox = container.querySelector('.builder-preview-error-inline');

    if (!src && updating) {
        container.innerHTML = `
            <div class="builder-preview-placeholder">
                <div class="btn-spinner" style="width: 24px; height: 24px; margin-bottom: 12px;"></div>
                <div>Rendering question…</div>
            </div>
        `;
        return;
    }

    if (!src && qErr) {
        container.innerHTML = `
            <div class="builder-preview-error">
                <h4>Question Preview Error</h4>
                <pre class="builder-error-pre">${escapeHtml(qErr)}</pre>
            </div>
        `;
        return;
    }

    if (!src) return false;

    if (!card || !img) {
        container.innerHTML = `
            ${qErr ? `<div class="builder-preview-error builder-preview-error-inline"><h4>Question Preview Error</h4><pre class="builder-error-pre">${escapeHtml(qErr)}</pre></div>` : ''}
            <div class="builder-preview-question-card${updating ? ' is-updating' : ''}">
                <img class="builder-preview-svg" data-hash="${escapeHtml(builderState.questionPreviewHash)}" src="${src}" alt="Question preview">
            </div>
        `;
        return true;
    }

    card.classList.toggle('is-updating', !!updating);
    if (img.getAttribute('data-hash') !== builderState.questionPreviewHash) {
        img.src = src;
        img.setAttribute('data-hash', builderState.questionPreviewHash);
    }
    if (qErr) {
        if (!errBox) {
            errBox = document.createElement('div');
            errBox.className = 'builder-preview-error builder-preview-error-inline';
            container.insertBefore(errBox, card);
        }
        errBox.innerHTML = `<h4>Question Preview Error</h4><pre class="builder-error-pre">${escapeHtml(qErr)}</pre>`;
    } else if (errBox) {
        errBox.remove();
    }
    return true;
}

async function triggerPreview() {
    builderState.previewLoading = true;
    builderState.previewError = null;
    builderState.previewKind = 'full';
    renderPreviewPane();

    const masterPayload = buildMasterJsonPayload();

    try {
        const res = await fetch('/api/preview_master_json', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                master: masterPayload,
                is_key: builderState.previewIsKey,
                source_path: builderState.filePath || '',
            }),
        });
        const data = await res.json();
        if (!res.ok || data.status !== 'success') {
            builderState.previewError = data.message || 'Preview generation failed.';
            builderState.previewPages = [];
        } else {
            builderState.previewId = data.preview_id;
            builderState.previewPages = data.pages || [];
            builderState.previewError = null;
        }
    } catch (e) {
        builderState.previewError = 'Failed to connect to server: ' + (e.message || String(e));
        builderState.previewPages = [];
    } finally {
        builderState.previewLoading = false;
        renderPreviewPane();
    }
}

function renderPreviewPane() {
    const container = document.getElementById('builder-preview-content');
    const header = document.getElementById('builder-preview-header-info');
    if (!container) return;

    const showFull = builderState.previewKind === 'full';
    const hasQuestion = !!(builderState.questionPreviewId && builderState.questionPreviewHash);

    if (showFull && builderState.previewLoading) {
        container.innerHTML = `
            <div class="builder-preview-placeholder">
                <div class="btn-spinner" style="width: 24px; height: 24px; margin-bottom: 12px;"></div>
                <div>Generating Typst assignment preview...</div>
            </div>
        `;
        if (header) header.textContent = 'Rendering...';
        return;
    }

    if (showFull && builderState.previewError) {
        container.innerHTML = `
            <div class="builder-preview-error">
                <h4>Preview Error</h4>
                <pre class="builder-error-pre">${escapeHtml(builderState.previewError)}</pre>
            </div>
        `;
        if (header) header.textContent = 'Error';
        return;
    }

    if (showFull && builderState.previewId && builderState.previewPages && builderState.previewPages.length > 0) {
        if (header) {
            header.textContent = `${builderState.previewPages.length} page${builderState.previewPages.length !== 1 ? 's' : ''} · ${previewModeLabel()}`;
        }
        const zoom = builderState.previewZoom || 1.0;
        container.innerHTML = `
            <div class="builder-preview-pages" style="zoom: ${zoom};">
                ${builderState.previewPages.map((pageNum) => `
                    <div class="builder-preview-page-card">
                        <div class="builder-preview-page-label">Page ${pageNum}</div>
                        <img class="builder-preview-img" src="/api/preview_page/${builderState.previewId}/${pageNum}?v=${Date.now()}" alt="Page ${pageNum}">
                    </div>
                `).join('')}
            </div>
        `;
        return;
    }

    if (hasQuestion || builderState.questionPreviewUpdating || builderState.questionPreviewError) {
        if (renderQuestionPreviewInto(container, header) !== false) return;
    }

    container.innerHTML = `
        <div class="builder-preview-placeholder">
            <div style="font-size: 2.5rem; margin-bottom: 10px; opacity: 0.6;">📄</div>
            <div><strong>No preview yet.</strong></div>
            <div style="font-size: 0.9rem; margin-top: 6px; color: var(--text-muted);">
                Click a question field to live-render it, or use <strong>Preview</strong> for the full assignment.
            </div>
        </div>
    `;
    if (header) header.textContent = 'No preview';
}

function openSaveMasterModal() {
    const modal = document.getElementById('save-master-modal');
    if (!modal) return;
    const nameInput = document.getElementById('save-master-name-input');
    const folderInput = document.getElementById('save-master-folder-input');
    const titleStem = (builderState.master.title || 'assignment')
        .toLowerCase()
        .replace(/[^a-z0-9_-]+/g, '_')
        .replace(/^_+|_+$/g, '') || 'exam';
    if (builderState.filePath) {
        const parts = splitPath(builderState.filePath);
        if (nameInput) nameInput.value = parts.file || `${titleStem}.json`;
        if (folderInput) folderInput.value = (!parts.dir || parts.dir === '.') ? '' : parts.dir;
    } else {
        if (nameInput) nameInput.value = `${titleStem}.json`;
        if (folderInput) folderInput.value = '';
    }
    const status = document.getElementById('save-master-status');
    if (status) status.textContent = '';
    modal.classList.remove('hidden');
}

function closeSaveMasterModal() {
    const modal = document.getElementById('save-master-modal');
    if (modal) modal.classList.add('hidden');
}

function saveMasterPathFromFields() {
    const nameInput = document.getElementById('save-master-name-input');
    const folderInput = document.getElementById('save-master-folder-input');
    let name = nameInput ? nameInput.value.trim() : '';
    const folder = folderInput ? folderInput.value.trim() : '';
    if (!name) return '';
    if (!name.toLowerCase().endsWith('.json')) name += '.json';
    if (!folder || folder === '.') return name;
    return folder.replace(/[\\/]+$/, '') + '/' + name;
}

async function confirmSaveMaster() {
    const status = document.getElementById('save-master-status');
    const path = saveMasterPathFromFields();

    if (!path) {
        if (status) {
            status.textContent = 'Please enter a file name.';
            status.className = 'classes-modal-status error';
        }
        return;
    }

    const masterPayload = buildMasterJsonPayload();

    if (status) {
        status.textContent = 'Validating and saving...';
        status.className = 'classes-modal-status';
    }

    try {
        const res = await fetch('/api/save_master_json', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: path, master: masterPayload }),
        });
        const data = await res.json();
        if (!res.ok || data.status !== 'success') {
            if (status) {
                status.textContent = data.message || 'Failed to save master JSON.';
                status.className = 'classes-modal-status error';
            }
        } else {
            builderState.filePath = data.path;
            closeSaveMasterModal();
            closeMasterBuilder({ skipConfirm: true });

            // Set the master path on Create Assignment page and validate immediately
            const masterInput = document.getElementById('gen-master-path');
            if (masterInput) {
                masterInput.value = data.path;
                syncGenerateNameFromPath();
                validateMasterPath();
            }

            showMessageModal({
                title: 'Saved Successfully',
                message: `Master JSON saved to ${data.path}.\nIt has been selected and validated on the Create Assignment page.`,
            });
        }
    } catch (e) {
        if (status) {
            status.textContent = 'Error: ' + (e.message || String(e));
            status.className = 'classes-modal-status error';
        }
    }
}

async function closeMasterBuilder({ skipConfirm = false } = {}) {
    if (!skipConfirm) {
        const ok = await showConfirmModal({
            title: 'Leave without saving?',
            message: 'Go back without saving?',
            confirmLabel: 'Go back',
            cancelLabel: 'Cancel',
        });
        if (!ok) return;
    }
    showSection('generate-sec');
}

function cleanupBuilderPreviewOnLeave() {
    builderState.previewId = null;
    builderState.previewPages = [];
    builderState.previewKind = 'none';
    builderState.questionPreviewId = null;
    builderState.questionPreviewHash = null;
    fetch('/api/cleanup_builder_preview', { method: 'POST' }).catch(() => {});
}

async function loadMasterJSONFromPath(path) {
    if (!path) return;
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
        } else {
            loadMasterDataIntoState(data.master, data.path);
            renderBuilderUI();
            renderPreviewPane();
        }
    } catch (e) {
        showMessageModal({
            title: 'Error',
            message: 'Failed to load file: ' + (e.message || String(e)),
        });
    }
}
