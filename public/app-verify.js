let verifyScanResults = [];
let currentVerifyIndex = 0;
let verifyCorrections = {};
let verifyAnchors = [];

const VERIFY_MIN_ANCHORS = 4;

// Entry point when clicking "Verify Scans"
async function startVerifyScans() {
    // Process Scans writes `{dir}/{new name}.assn`, falling back to the .assnversions stem.
    const versionsPath = document.getElementById('proc-assnversions-path').value;
    const newName = document.getElementById('proc-new-name').value.trim();
    const parts = splitPath(versionsPath);
    const dir = parts.dir && parts.dir !== "." ? parts.dir : ".";
    const stem = newName || stripExtension(parts.file, ".assnversions");
    const assnPath = !stem ? "" : (dir === "." ? `${stem}.assn` : `${dir}/${stem}.assn`);

    if (!assnPath) {
        showMessageModal({
            title: 'Missing Path',
            message: 'Please run Process Scans or provide a valid .assn path first.',
        });
        return false;
    }

    try {
        const res = await fetch('/api/upload_grade_context', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            // We just ran or intend to verify the fresh .assn archive.
            // Any existing tmp data is out-of-date since processScans overrides the .assn file.
            body: JSON.stringify({ assn_file: assnPath, replace_existing_tmp: true })
        });
        const data = await res.json();
        
        if (data.status !== 'success') {
            throw new Error(data.message);
        }
        bustScanImageCache();

        // Now fetch scan results
        const scanRes = await fetch('/api/get_scan_results');
        const scanData = await scanRes.json();
        if (scanData.status !== 'success') {
            throw new Error(scanData.message);
        }

        verifyScanResults = scanData.scan_results || [];
        verifyCorrections = {};
        currentVerifyIndex = 0;
        
        populateVerifyDropdown();
        showSection('verify-sec');
        renderVerifyPage();
        return true;

    } catch (e) {
        showMessageModal({
            title: 'Verification Failed',
            message: 'Failed to start verification: ' + e.message,
        });
        return false;
    }
}

function isVerifyPageComplete(res) {
    const corr = verifyCorrections[String(res.ppage_indx)];
    if (corr) {
        return Number.isFinite(corr.assn_id)
            && Number.isFinite(corr.page)
            && Array.isArray(corr.tiff_anchors)
            && corr.tiff_anchors.length >= VERIFY_MIN_ANCHORS;
    }
    // anchors_ok may be missing on older archives; treat missing as OK when identified.
    return Boolean(res.identified && res.anchors_ok !== false);
}

function populateVerifyDropdown() {
    const items = verifyScanResults.map(res => ({
        label: `Page ${res.ppage_indx}`,
        isComplete: isVerifyPageComplete(res),
    }));
    renderStatusDropdown('verify-page-dropdown', items, currentVerifyIndex, (index) => {
        currentVerifyIndex = index;
        renderVerifyPage();
    });
}

function prevVerifyPage() {
    if (currentVerifyIndex > 0) {
        currentVerifyIndex--;
        renderVerifyPage();
    }
}

function nextVerifyPage() {
    if (currentVerifyIndex < verifyScanResults.length - 1) {
        currentVerifyIndex++;
        renderVerifyPage();
    }
}

function renderVerifyPage() {
    if (verifyScanResults.length === 0) return;
    const page = verifyScanResults[currentVerifyIndex];
    
    populateVerifyDropdown();
    
    const loading = document.getElementById('verify-loading');
    const img = document.getElementById('verify-img');
    const overlay = document.getElementById('verify-anchors-overlay');
    const status = document.getElementById('verify-status');
    const assnIdInput = document.getElementById('verify-assn-id');
    const pageNumInput = document.getElementById('verify-page-num');

    loading.classList.remove('hidden');
    img.classList.add('hidden');
    
    // Reset inputs
    verifyAnchors = [];
    overlay.innerHTML = '';
    
    // Load correction if exists, otherwise defaults
    const c_key = String(page.ppage_indx);
    const existingCorrection = verifyCorrections[c_key];
    
    if (existingCorrection) {
        assnIdInput.value = existingCorrection.assn_id;
        pageNumInput.value = existingCorrection.page;
        if (existingCorrection.tiff_anchors) {
            verifyAnchors = [...existingCorrection.tiff_anchors];
        }
        status.textContent = "Corrected (Pending Finalize)";
        status.style.color = "#d97706"; // Amber
    } else if (page.identified && page.anchors_ok !== false) {
        assnIdInput.value = page.assn_id;
        pageNumInput.value = page.page;
        status.textContent = "Identified";
        status.style.color = "#16a34a";
    } else {
        assnIdInput.value = page.identified ? page.assn_id : '';
        pageNumInput.value = page.identified ? page.page : '';
        if (!page.identified) {
            status.textContent = "Unidentified (data matrix failed)";
        } else {
            status.textContent = "Anchors failed — enter ID/page and mark anchors";
        }
        status.style.color = "#dc2626";
    }

    img.onload = () => {
        loading.classList.add('hidden');
        img.classList.remove('hidden');
        drawVerifyAnchors();
    };
    img.removeAttribute('src');
    img.src = annotatedImageUrl(page.image_path);
    focusNavSentinel('verify-focus-sentinel');
}

function handleVerifyClick(e) {
    if (verifyAnchors.length >= 14) {
        // Reset if clicking again after 14
        verifyAnchors = [];
    }
    const img = e.target;
    const rect = img.getBoundingClientRect();
    
    // Calculate click coordinates relative to the original image dimensions
    const scaleX = img.naturalWidth / rect.width;
    const scaleY = img.naturalHeight / rect.height;
    
    const x = (e.clientX - rect.left) * scaleX;
    const y = (e.clientY - rect.top) * scaleY;
    
    verifyAnchors.push([x, y]);
    drawVerifyAnchors();
}

function clearVerifyAnchors() {
    verifyAnchors = [];
    drawVerifyAnchors();
}

function drawVerifyAnchors() {
    const overlay = document.getElementById('verify-anchors-overlay');
    const img = document.getElementById('verify-img');
    overlay.innerHTML = '';
    
    if (!img.naturalWidth || img.naturalWidth === 0) return;

    // Use the same getBoundingClientRect space as click handling so markers
    // stay aligned even when clientWidth and CSS layout width diverge.
    const imgRect = img.getBoundingClientRect();
    const overlayRect = overlay.getBoundingClientRect();
    const scaleX = imgRect.width / img.naturalWidth;
    const scaleY = imgRect.height / img.naturalHeight;
    const offsetX = imgRect.left - overlayRect.left;
    const offsetY = imgRect.top - overlayRect.top;
    
    verifyAnchors.forEach((pt, i) => {
        const marker = document.createElement('div');
        marker.className = 'verify-anchor-marker';
        marker.style.left = `${offsetX + pt[0] * scaleX}px`;
        marker.style.top = `${offsetY + pt[1] * scaleY}px`;
        
        const label = document.createElement('div');
        label.className = 'verify-anchor-label';
        label.textContent = i + 1;
        
        marker.appendChild(label);
        overlay.appendChild(marker);
    });
}

// Window resize should redraw anchors to match new image size
window.addEventListener('resize', () => {
    const verifySec = document.getElementById('verify-sec');
    if (verifySec && !verifySec.classList.contains('hidden')) {
        drawVerifyAnchors();
    }
});

async function clearArchiveContext() {
    try {
        await fetch('/api/clear_archive_context', { method: 'POST' });
    } catch (e) {
        console.error(e);
    }
}

async function leaveVerifyScans() {
    await clearArchiveContext();
    showSection('process-sec');
}

function saveVerifyCorrection() {
    const page = verifyScanResults[currentVerifyIndex];
    const assnIdInput = document.getElementById('verify-assn-id').value;
    const pageNumInput = document.getElementById('verify-page-num').value;
    
    if (!assnIdInput || !pageNumInput) {
        showMessageModal({
            title: 'Missing Fields',
            message: 'Please provide both Assn ID and Page Number.',
        });
        return;
    }

    if (verifyAnchors.length < VERIFY_MIN_ANCHORS) {
        showMessageModal({
            title: 'More Anchors Needed',
            message: `Please mark at least ${VERIFY_MIN_ANCHORS} anchor positions on the image.`,
        });
        return;
    }
    
    const correction = {
        assn_id: parseInt(assnIdInput),
        page: parseInt(pageNumInput),
        tiff_anchors: [...verifyAnchors],
    };
    
    verifyCorrections[String(page.ppage_indx)] = correction;
    renderVerifyPage(); // To update status text
}

async function finalizeScans() {
    if (Object.keys(verifyCorrections).length === 0) {
        // No corrections, just go back to main menu or wherever
        showMessageModal({
            title: 'Verification Complete',
            message: 'No corrections made. Verification complete.',
        });
        await clearArchiveContext();
        showSection('main-menu');
        return;
    }

    const tiffPath = document.getElementById('proc-tiff-path').value;
    const assnPath = document.getElementById('proc-assnversions-path').value;
    const newName = document.getElementById('proc-new-name').value.trim();
    
    const spinner = document.getElementById('finalize-scans-spinner');
    const label = document.getElementById('finalize-scans-label');
    spinner.classList.remove('hidden');
    label.textContent = 'Reprocessing...';

    // Disconnect old socket if any
    if (activeProcessSocket && activeProcessSocket.readyState <= WebSocket.OPEN) {
        activeProcessSocket.close(1000, "Starting new process run");
    }

    const ws = new WebSocket(`ws://${location.host}/api/ws_process`);
    activeProcessSocket = ws;
    ws.onopen = () => ws.send(JSON.stringify({
        tiff_file: tiffPath,
        assn_file: assnPath,
        new_file_name: newName,
        corrections: verifyCorrections,
        namereader_file: document.getElementById('proc-namereader-path').value.trim()
    }));
    
    let fullOutput = "";
    ws.onmessage = (event) => {
        fullOutput += event.data;
        if (String(event.data).trim() === "Done") {
            ws.close(1000, "Run complete");
        }
    };
    ws.onerror = (error) => {
        showMessageModal({
            title: 'Error',
            message: 'Error reprocessing scans: ' + error,
        });
    };
    ws.onclose = async () => {
        spinner.classList.add('hidden');
        label.textContent = 'Finalize Scans';
        if (activeProcessSocket === ws) activeProcessSocket = null;
        // process_scans rewrote the .assn archive in its own temp dir; drop the verify extract.
        await clearArchiveContext();
        showMessageModal({
            title: 'Success',
            message: 'Scans finalized successfully!',
        });
        showSection('main-menu');
    };
}
