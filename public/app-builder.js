// Assignment Creator (Master JSON Builder & Live Typst Preview)

let builderState = {
    filePath: '',
    master: {
        assn_type: 'quiz',
        title: 'New Assignment',
        intro_content: '',
        margin: 1.5,
        section_numbering: '[1]',
        shuffle_questions: false,
        shuffle_answers: false,
        version_count: 1,
        seed: 1234,
        global_vars: '',
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
};

let builderToggles = {
    intro: false,
    margin: false,
    sectionNumbering: false,
    seed: false,
    globalVars: false,
};

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
    renderPreviewPane();
}

function resetBuilderState(path = '') {
    builderToggles = {
        intro: false,
        margin: false,
        sectionNumbering: false,
        seed: false,
        globalVars: false,
    };
    builderState = {
        filePath: path,
        master: {
            assn_type: 'quiz',
            title: 'New Assignment',
            intro_content: '',
            margin: 1.5,
            section_numbering: '[1]',
            shuffle_questions: false,
            shuffle_answers: false,
            version_count: 1,
            seed: 1234,
            global_vars: '',
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
    };
}

function loadMasterDataIntoState(data, path = '') {
    const questionsRaw = Array.isArray(data.questions) ? data.questions : [];
    const hasSections = questionsRaw.length > 0 && typeof questionsRaw[0] === 'object' && ('section_title' in questionsRaw[0]);

    builderToggles = {
        intro: !!(data.intro_content && data.intro_content.trim()),
        margin: data.margin !== undefined && data.margin !== null && data.margin !== 1.5,
        sectionNumbering: data.section_numbering !== undefined && data.section_numbering !== null && String(data.section_numbering).trim() !== '[1]',
        seed: data.seed !== undefined && data.seed !== null && data.seed !== 1234,
        globalVars: !!(data.global_vars && data.global_vars.trim()),
    };

    builderState.filePath = path;
    builderState.previewId = null;
    builderState.previewPages = [];
    builderState.previewLoading = false;
    builderState.previewError = null;
    builderState.activeAddMenuKey = null;

    builderState.master = {
        assn_type: data.assn_type || 'quiz',
        title: data.title || 'Untitled Assignment',
        intro_content: data.intro_content || '',
        margin: typeof data.margin === 'number' ? data.margin : 1.5,
        section_numbering: data.section_numbering !== undefined && data.section_numbering !== null ? String(data.section_numbering) : '[1]',
        shuffle_questions: !!data.shuffle_questions,
        shuffle_answers: !!data.shuffle_answers,
        version_count: typeof data.version_count === 'number' ? data.version_count : 1,
        seed: typeof data.seed === 'number' ? data.seed : 1234,
        global_vars: data.global_vars || '',
        single_doc_export: !!data.single_doc_export,
        will_print_double_sided: data.will_print_double_sided !== undefined ? !!data.will_print_double_sided : true,
        use_sections: hasSections,
        sections: hasSections ? questionsRaw.map((sec) => ({
            section_title: String(sec.section_title || ''),
            questions: normalizeQuestionsFromData(sec.questions || []),
        })) : [createDefaultSection('Section 1')],
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
    if (typeof m.margin === 'number' && m.margin >= 1.5 && m.margin <= 3.0) {
        result.margin = m.margin;
    }
    if (m.section_numbering !== undefined && m.section_numbering !== null && m.section_numbering.trim()) {
        result.section_numbering = m.section_numbering.trim();
    }
    if (m.shuffle_questions) result.shuffle_questions = true;
    if (m.shuffle_answers) result.shuffle_answers = true;
    if (typeof m.version_count === 'number' && m.version_count > 0) {
        result.version_count = m.version_count;
    }
    if (typeof m.seed === 'number' && m.seed > 0) {
        result.seed = m.seed;
    }
    if (m.global_vars && m.global_vars.trim()) {
        result.global_vars = m.global_vars.trim();
    } else {
        result.global_vars = null;
    }
    result.single_doc_export = !!m.single_doc_export;
    result.will_print_double_sided = m.will_print_double_sided !== undefined ? !!m.will_print_double_sided : true;

    if (m.use_sections) {
        result.questions = (m.sections || []).map((sec) => ({
            section_title: (sec.section_title || '').trim(),
            questions: sanitizeQuestionList(sec.questions || [])
        }));
    } else {
        result.questions = sanitizeQuestionList(m.questions || []);
    }

    return result;
}

function sanitizeQuestionList(list) {
    return list.map((item) => {
        if (item && typeof item === 'object' && 'pick' in item) {
            return {
                pick: Math.max(1, parseInt(item.pick, 10) || 1),
                questions: (item.questions || []).map(sanitizeSingleQuestion),
            };
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
            return {
                pick: Math.max(1, parseInt(item.pick, 10) || 1),
                questions: normalizeQuestionsFromData(item.questions || []),
            };
        }
        const copy = JSON.parse(JSON.stringify(item));
        if (copy.rubric) {
            copy.rubric = normalizeRubricFromData(copy.rubric);
        }
        return copy;
    });
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
    if (q.vars && typeof q.vars === 'object' && Object.keys(q.vars).length > 0) {
        clean.vars = q.vars;
    }
    if (q.secondary_vars && typeof q.secondary_vars === 'object' && Object.keys(q.secondary_vars).length > 0) {
        clean.secondary_vars = q.secondary_vars;
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
        if (Array.isArray(q.correct_answer)) {
            clean.correct_answer = q.correct_answer.map(String);
        } else if (typeof q.correct_answer === 'string' && q.correct_answer.trim()) {
            clean.correct_answer = q.correct_answer.trim();
        } else {
            clean.correct_answer = null;
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
    return clean;
}

function renderBuilderUI() {
    const container = document.getElementById('builder-form-container');
    if (!container) return;

    let html = '';
    html += renderTopLevelSettingsHtml();
    html += renderSectionsAndQuestionsHtml();

    container.innerHTML = html;
    attachBuilderEventListeners();
    if (typeof enhanceTypstMarkupFields === "function") enhanceTypstMarkupFields(container);
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
                <div class="builder-control-group" style="flex: 1; min-width: 220px;">
                    <label for="builder-title">Assignment Title</label>
                    <input type="text" id="builder-title" class="builder-input-title" value="${escapeHtml(m.title)}" placeholder="e.g. Midterm 1">
                </div>
                <div class="builder-control-group">
                    <label for="builder-version-count">Versions</label>
                    <input type="number" id="builder-version-count" class="builder-input-sm" min="1" step="1" value="${m.version_count || 1}">
                </div>
            </div>

            <div class="builder-checkbox-row">
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-shuffle-q" ${m.shuffle_questions ? 'checked' : ''}>
                    <span>Shuffle Questions</span>
                </label>
                <label class="builder-checkbox-label">
                    <input type="checkbox" id="builder-shuffle-a" ${m.shuffle_answers ? 'checked' : ''}>
                    <span>Shuffle Answers</span>
                </label>
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
                <button type="button" class="builder-toggle-link ${builderToggles.margin ? 'active' : ''}" onclick="toggleTopSetting('margin')">
                    ${builderToggles.margin ? '−' : '+'} Margin
                </button>
                <button type="button" class="builder-toggle-link ${builderToggles.sectionNumbering ? 'active' : ''}" onclick="toggleTopSetting('sectionNumbering')">
                    ${builderToggles.sectionNumbering ? '−' : '+'} Section Numbering
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

            ${(builderToggles.margin || builderToggles.sectionNumbering || builderToggles.seed) ? `
                <div class="builder-form-row" style="margin-top: 8px;">
                    ${builderToggles.margin ? `
                        <div class="builder-control-group">
                            <label for="builder-margin">Margin (cm)</label>
                            <input type="number" id="builder-margin" class="builder-input-sm" min="1.5" max="3.0" step="0.1" value="${m.margin !== undefined ? m.margin : 1.5}">
                        </div>
                    ` : ''}
                    ${builderToggles.sectionNumbering ? `
                        <div class="builder-control-group">
                            <label for="builder-sec-num">Section Numbering</label>
                            <input type="text" id="builder-sec-num" class="builder-input-md" value="${escapeHtml(m.section_numbering || '')}" placeholder="[1], 1., (A)">
                        </div>
                    ` : ''}
                    ${builderToggles.seed ? `
                        <div class="builder-control-group">
                            <label for="builder-seed">Random Seed</label>
                            <input type="number" id="builder-seed" class="builder-input-md" min="1" step="1" value="${m.seed || 1234}">
                        </div>
                    ` : ''}
                </div>
            ` : ''}

            ${builderToggles.globalVars ? `
                <div class="builder-field-block" style="margin-top: 8px;">
                    <label for="builder-global-vars">Global Vars <em>(Typst dictionary code)</em></label>
                    <textarea id="builder-global-vars" class="builder-textarea-code" rows="2" placeholder='e.g. (class_name: "BIO 101", term: "Fall 2026")'>${escapeHtml(m.global_vars || '')}</textarea>
                </div>
            ` : ''}
        </div>
    `;
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
                <span class="builder-section-badge">Section ${sIdx + 1}</span>
                <input type="text" class="builder-input builder-section-title-input" value="${escapeHtml(sec.section_title)}" placeholder="Section Title (e.g. Part I: Multiple Choice)" oninput="updateSectionTitle(${sIdx}, this.value)">
                <div class="builder-item-actions">
                    <button type="button" class="btn-icon" title="Move Up" ${sIdx === 0 ? 'disabled' : ''} onclick="moveSection(${sIdx}, -1)"><span>▲</span></button>
                    <button type="button" class="btn-icon" title="Move Down" ${sIdx === (builderState.master.sections.length - 1) ? 'disabled' : ''} onclick="moveSection(${sIdx}, 1)"><span>▼</span></button>
                    <button type="button" class="btn-icon btn-danger" title="Delete Section" onclick="deleteSection(${sIdx})"><span>🗑</span></button>
                </div>
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
        <div class="builder-question-card" data-q-index="${qIdx}">
            <div class="builder-question-header">
                <div class="builder-q-badge-wrap">
                    <span class="builder-q-num">Q${qIdx + 1}</span>
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

            <div class="builder-field-block" style="margin-top: 10px;">
                <label>Question Body <em>(Typst markup)</em></label>
                <textarea class="builder-textarea" rows="2" placeholder="${q.type === 'fill_blank' ? 'e.g. Mitochondria is the #BLANK of the cell.' : 'Enter question text...'}" oninput="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'body', this.value)">${escapeHtml(q.body || '')}</textarea>
            </div>

            ${renderQuestionTypeSpecificHtml(q, qIdx, isInsideBank, sIdx, bIdx)}

            <details class="builder-advanced-details" style="margin-top: 10px;">
                <summary>Variables &amp; Formulas (Optional)</summary>
                <div class="builder-vars-section" style="margin-top: 8px;">
                    <div class="builder-field-block">
                        <label><code>vars</code> (Random Variables, JSON)</label>
                        <textarea class="builder-textarea-code" rows="2" placeholder='e.g. {"x": [1, 2, 3], "y": {"type": "int", "min": 1, "max": 10}}' onchange="updateQuestionJsonField(${sIdx}, ${bIdx}, ${qIdx}, 'vars', this.value)">${q.vars ? escapeHtml(JSON.stringify(q.vars)) : ''}</textarea>
                    </div>
                    <div class="builder-field-block" style="margin-top: 8px;">
                        <label><code>secondary_vars</code> (Computed Typst expressions)</label>
                        <textarea class="builder-textarea-code" rows="2" placeholder='e.g. {"ans": "x + y"}' onchange="updateQuestionJsonField(${sIdx}, ${bIdx}, ${qIdx}, 'secondary_vars', this.value)">${q.secondary_vars ? escapeHtml(JSON.stringify(q.secondary_vars)) : ''}</textarea>
                    </div>
                </div>
            </details>
        </div>
    `;
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
        const correctStr = Array.isArray(q.correct_answer) ? q.correct_answer.join(', ') : (q.correct_answer || '');
        return `
            <div class="builder-options-block">
                <div class="builder-field-block">
                    <label>Correct Answer(s) <em>(comma-separated if multiple #BLANKs)</em></label>
                    <input type="text" class="builder-input-title" value="${escapeHtml(correctStr)}" placeholder="e.g. Paris or [Paris, France]" oninput="updateFillBlankAnswer(${sIdx}, ${bIdx}, ${qIdx}, this.value)">
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
                    <div class="builder-control-group" style="flex: 1; min-width: 220px;">
                        <label>Sample Solution / Key <em>(optional Typst markup)</em></label>
                        <input type="text" class="builder-input-title" value="${escapeHtml(q.correct_answer || '')}" placeholder="Answer to show on the Key" oninput="updateQuestionField(${sIdx}, ${bIdx}, ${qIdx}, 'correct_answer', this.value)">
                    </div>
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

    const margin = document.getElementById('builder-margin');
    if (margin) margin.oninput = () => { builderState.master.margin = parseFloat(margin.value) || 1.5; };

    const secNum = document.getElementById('builder-sec-num');
    if (secNum) secNum.oninput = () => { builderState.master.section_numbering = secNum.value; };

    const vCount = document.getElementById('builder-version-count');
    if (vCount) vCount.oninput = () => { builderState.master.version_count = parseInt(vCount.value, 10) || 1; };

    const seed = document.getElementById('builder-seed');
    if (seed) seed.oninput = () => { builderState.master.seed = parseInt(seed.value, 10) || 1234; };

    const shufQ = document.getElementById('builder-shuffle-q');
    if (shufQ) shufQ.onchange = () => { builderState.master.shuffle_questions = shufQ.checked; };

    const shufA = document.getElementById('builder-shuffle-a');
    if (shufA) shufA.onchange = () => { builderState.master.shuffle_answers = shufA.checked; };

    const singleDoc = document.getElementById('builder-single-doc');
    if (singleDoc) singleDoc.onchange = () => { builderState.master.single_doc_export = singleDoc.checked; };

    const doubleSided = document.getElementById('builder-double-sided');
    if (doubleSided) doubleSided.onchange = () => { builderState.master.will_print_double_sided = doubleSided.checked; };

    const gVars = document.getElementById('builder-global-vars');
    if (gVars) gVars.oninput = () => { builderState.master.global_vars = gVars.value; };
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

function updateQuestionJsonField(sIdx, bIdx, qIdx, field, rawStr) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q) return;
    if (!rawStr || !rawStr.trim()) {
        delete q[field];
        return;
    }
    try {
        q[field] = JSON.parse(rawStr);
    } catch (e) {
        // Keep string if not valid JSON
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

function updateFillBlankAnswer(sIdx, bIdx, qIdx, rawValue) {
    const q = getQuestionRef(sIdx, bIdx, qIdx);
    if (!q) return;
    const parts = rawValue.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
    q.correct_answer = parts.length > 1 ? parts : (parts.length === 1 ? parts[0] : '');
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

async function triggerPreview() {
    builderState.previewLoading = true;
    builderState.previewError = null;
    renderPreviewPane();

    const masterPayload = buildMasterJsonPayload();

    try {
        const res = await fetch('/api/preview_master_json', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ master: masterPayload }),
        });
        const data = await res.json();
        if (!res.ok || data.status !== 'success') {
            builderState.previewError = data.message || 'Preview generation failed.';
            builderState.previewId = null;
            builderState.previewPages = [];
        } else {
            builderState.previewId = data.preview_id;
            builderState.previewPages = data.pages || [];
            builderState.previewError = null;
        }
    } catch (e) {
        builderState.previewError = 'Failed to connect to server: ' + (e.message || String(e));
        builderState.previewId = null;
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

    if (builderState.previewLoading) {
        container.innerHTML = `
            <div class="builder-preview-placeholder">
                <div class="btn-spinner" style="width: 24px; height: 24px; margin-bottom: 12px;"></div>
                <div>Generating Typst assignment preview...</div>
            </div>
        `;
        if (header) header.textContent = 'Rendering...';
        return;
    }

    if (builderState.previewError) {
        container.innerHTML = `
            <div class="builder-preview-error">
                <h4>Preview Error</h4>
                <pre class="builder-error-pre">${escapeHtml(builderState.previewError)}</pre>
            </div>
        `;
        if (header) header.textContent = 'Error';
        return;
    }

    if (!builderState.previewId || !builderState.previewPages || builderState.previewPages.length === 0) {
        container.innerHTML = `
            <div class="builder-preview-placeholder">
                <div style="font-size: 2.5rem; margin-bottom: 10px; opacity: 0.6;">📄</div>
                <div><strong>No preview generated yet.</strong></div>
                <div style="font-size: 0.9rem; margin-top: 6px; color: var(--text-muted);">
                    Click the <strong>"Preview"</strong> button above to render the assignment.
                </div>
            </div>
        `;
        if (header) header.textContent = 'No preview';
        return;
    }

    if (header) {
        header.textContent = `${builderState.previewPages.length} page${builderState.previewPages.length !== 1 ? 's' : ''}`;
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
}

function zoomPreview(delta) {
    if (delta === 0) {
        builderState.previewZoom = 1.0;
    } else {
        builderState.previewZoom = Math.max(0.4, Math.min(2.5, (builderState.previewZoom || 1.0) + delta));
    }
    renderPreviewPane();
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
            closeMasterBuilder();

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

function closeMasterBuilder() {
    showSection('generate-sec');
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
