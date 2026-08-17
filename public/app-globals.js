// Shared constants, DOM element references, and mutable global state.
// This file must be loaded before the other app-*.js files, which depend on these globals.

// Constants

const GREEN_CHECK_SVG = `data:image/svg+xml;utf8,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#16a34a" d="M20.285 6.709a1 1 0 0 1 .006 1.414l-9.2 9.281a1 1 0 0 1-1.423.005L3.71 11.532a1 1 0 1 1 1.416-1.41l5.25 5.276 8.495-8.569a1 1 0 0 1 1.414-.12z"/></svg>')}`;
const ORANGE_CIRCLE_SVG = `data:image/svg+xml;utf8,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8" fill="#f59e0b"/></svg>')}`;

// Common DOM elements

const mainMenu = document.getElementById('main-menu');
const generateSection = document.getElementById('generate-sec');
const builderSection = document.getElementById('builder-sec');
const processSection = document.getElementById('process-sec');
const gradeSection = document.getElementById('grade-sec');
const gradingUI = document.getElementById('grading-ui');
const gradeStep1 = document.getElementById('grade-step-1');
const gradeStep2 = document.getElementById('grade-step-2');
const filePicker = document.getElementById('file-picker-modal');
const existingTmpModal = document.getElementById('existing-tmp-modal');
const existingTmpMessage = document.getElementById('existing-tmp-message');
const existingTmpLoadBtn = document.getElementById('existing-tmp-load-btn');
const existingTmpReplaceBtn = document.getElementById('existing-tmp-replace-btn');
const existingTmpCancelBtn = document.getElementById('existing-tmp-cancel-btn');
const input = document.getElementById('student-name-input');
const assignLeftPane = document.getElementById('assign-left-pane');
const assignPageWrap = document.getElementById('assign-page-wrap');
const assignLoading = document.getElementById('assign-loading');
const gradeLeftPane = document.getElementById('grade-left-pane');
const gradePageWrap = document.getElementById('grade-page-wrap');
const gradeLoading = document.getElementById('grade-loading');
const gradeQLine = document.getElementById('grade-q-line');
const Q_LINE_OFFSET_PX = 14;
const startGradingBtn = document.getElementById('start-grading-btn');
const startGradingSpinner = document.getElementById('start-grading-spinner');
const startGradingLabel = document.getElementById('start-grading-label');

// Global vars

let currentPickerInput = null;
let currentPickerAcceptExts = null;
let currentPickerFolderMode = false;
let gradingData = {};
// Bumped on every scan render so that asynchronous page loads from a superseded render (the grader
// navigated away before images finished loading) can detect they are stale and do nothing.
let scanRenderToken = 0;
let scanCacheBust = Date.now();

function bustScanImageCache() {
    scanCacheBust = Date.now();
}

function annotatedPagePngUrl(assnId, page) {
    return `/api/annotated_page_png/${assnId}/${page}?v=${scanCacheBust}`;
}

function annotatedImageUrl(imagePath) {
    return `/api/annotated_image/${imagePath}?v=${scanCacheBust}`;
}

let studentsList = [];
let masterQuestions = {};
let assnIds = [];
let currentAssnIndex = 0;
let currentSuggestions = [];
let highlightedSuggestionIndex = -1;
let activeGenerateSocket = null;
let activeProcessSocket = null;

let questionsMap = {};
let questionIds = [];
let currentQIndex = 0;
let currentAssnIndexForQ = 0;

// Theme: "system" follows prefers-color-scheme; "light"/"dark" force a mode.
const THEME_STORAGE_KEY = 'biscuit-theme';
const themeSelect = document.getElementById('theme-select');

function applyTheme(theme) {
    const mode = (theme === 'light' || theme === 'dark') ? theme : 'system';
    if (mode === 'system') {
        document.documentElement.removeAttribute('data-theme');
    } else {
        document.documentElement.setAttribute('data-theme', mode);
    }
    localStorage.setItem(THEME_STORAGE_KEY, mode);
    if (themeSelect) themeSelect.value = mode;
}

function initTheme() {
    const saved = localStorage.getItem(THEME_STORAGE_KEY)
        || localStorage.getItem('exam-theme')
        || 'system';
    applyTheme(saved);
    if (themeSelect) {
        themeSelect.addEventListener('change', () => applyTheme(themeSelect.value));
    }
}

initTheme();

// Shared message modal (replaces browser alert)
function closeMessageModal() {
    const modal = document.getElementById('message-modal');
    if (modal) modal.classList.add('hidden');
}

function showMessageModal({ title = 'Notice', message = '', okLabel = 'OK' } = {}) {
    const modal = document.getElementById('message-modal');
    if (!modal) return;
    document.getElementById('message-modal-title').textContent = title;
    document.getElementById('message-modal-body').textContent = message;
    const okBtn = document.getElementById('message-modal-ok');
    okBtn.textContent = okLabel;
    okBtn.onclick = closeMessageModal;
    document.getElementById('message-modal-close').onclick = closeMessageModal;
    modal.classList.remove('hidden');
}

function closeVerifyPrompt() {
    const modal = document.getElementById('verify-prompt-modal');
    if (modal) modal.classList.add('hidden');
}

function openVerifyPrompt() {
    const modal = document.getElementById('verify-prompt-modal');
    if (modal) modal.classList.remove('hidden');
}

function setVerifyScansLoading(isLoading) {
    const btn = document.getElementById('verify-scans-prompt-btn');
    const spinner = document.getElementById('verify-scans-prompt-spinner');
    const label = document.getElementById('verify-scans-prompt-label');
    const notNow = document.querySelector('#verify-prompt-modal .modal-actions button:not(#verify-scans-prompt-btn)');
    if (btn) btn.disabled = !!isLoading;
    if (notNow) notNow.disabled = !!isLoading;
    if (spinner) spinner.classList.toggle('hidden', !isLoading);
    if (label) label.textContent = isLoading ? 'Loading...' : 'Verify Scans';
}

async function acceptVerifyPrompt() {
    setVerifyScansLoading(true);
    try {
        const ok = await startVerifyScans();
        if (ok) closeVerifyPrompt();
    } finally {
        setVerifyScansLoading(false);
    }
}
