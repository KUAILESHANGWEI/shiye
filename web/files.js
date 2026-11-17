// Files use the Mac application support directory or IndexedDB in the web preview.
let filesMode = false;
let fileItems = [];
let fileDBPromise;
let fileViewURLs = [];
let filePreviewURL = null;
let fileImporting = false;
let fileImportCancelled = false;
const fileThumbnails = new Map();

function nativeFileCollection() {
    return window.webkit?.messageHandlers?.fileCollection;
}

function fileDB() {
    if (!fileDBPromise) {
        fileDBPromise = new Promise((resolve, reject) => {
            const request = indexedDB.open('shiye-files-preview-v1', 1);
            request.onupgradeneeded = () => request.result.createObjectStore('files', {keyPath: 'id'});
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => {
                fileDBPromise = undefined;
                reject(request.error);
            };
        });
    }
    return fileDBPromise;
}

async function encodeFile(item) {
    if (item.native) {
        let data = '';
        for (let offset = 0; offset < item.size; offset += 786432) {
            data += await nativeFileCollection().postMessage({action: 'readFilePart', value: {id: item.id, offset, length: 786432}});
        }
        const {native, blob, ...metadata} = item;
        return {...metadata, data};
    }
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
            const {blob, ...metadata} = item;
            resolve({...metadata, data: reader.result.slice(reader.result.indexOf(',') + 1)});
        };
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(item.blob);
    });
}

function decodeFiles(records) {
    if (!Array.isArray(records)) throw Error(t("文件收藏数据格式不正确"));
    const ids = new Set();
    return records.map(record => {
        if (!record || typeof record.id !== 'string' ||
            !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(record.id) ||
            ids.has(record.id) || typeof record.name !== 'string' || !record.name ||
            typeof record.type !== 'string' || typeof record.note !== 'string' ||
            typeof record.createdAt !== 'string' || (!record.native && !(record.blob instanceof Blob) && typeof record.data !== 'string') ||
            !Number.isInteger(record.rating) || record.rating < 0 || record.rating > 3 ||
            !Number.isSafeInteger(record.size) || record.size < 0) {
            throw Error(t("文件收藏数据不完整"));
        }
        ids.add(record.id);
        if (record.native) return {...record, native: true};
        const blob = record.blob instanceof Blob ? record.blob : new Blob([Uint8Array.from(atob(record.data), character => character.charCodeAt(0))], {type: record.type});
        if (blob.size !== record.size) throw Error(t("文件内容已损坏"));
        return {
            id: record.id, name: record.name, type: record.type, size: record.size,
            note: record.note, rating: record.rating, createdAt: record.createdAt,
            blob
        };
    });
}

async function fileStore(action, value) {
    const bridge = nativeFileCollection();
    if (bridge) {
        if (action === 'getAll') return decodeFiles(await bridge.postMessage({action}));
        if (window.shiyeNativeFileStreaming) {
            if (action === 'put' && value.native) {
                await bridge.postMessage({action: 'updateMetadata', value: {id: value.id, note: value.note, rating: value.rating}});
            } else if (action === 'put' || action === 'merge') {
                const items = action === 'put' ? [value] : value;
                for (const item of items) {
                    if (fileImportCancelled) throw Error('Cancelled');
                    const {blob, native, ...metadata} = item;
                    const token = await stageNativeFile(blob, metadata);
                    try {
                        $('cancelFileImport').disabled = true;
                        await bridge.postMessage({action: 'finishImport', value: token});
                        $('cancelFileImport').disabled = false;
                    } catch (error) {
                        await bridge.postMessage({action: 'cancelImport', value: token});
                        throw error;
                    }
                }
            } else await bridge.postMessage({action, value});
        } else if (action === 'put') {
            await bridge.postMessage({action: 'merge', value: [await encodeFile(value)]});
        } else if (action === 'merge') {
            for (const item of value) await bridge.postMessage({action, value: [await encodeFile(item)]});
        } else await bridge.postMessage({action, value});
        return;
    }
    const database = await fileDB();
    return new Promise((resolve, reject) => {
        const transaction = database.transaction('files', action === 'getAll' ? 'readonly' : 'readwrite');
        const store = transaction.objectStore('files');
        let request;
        if (action === 'merge') {
            for (const item of value) store.put(item);
        } else {
            request = action === 'getAll' ? store.getAll() : store[action](value);
        }
        transaction.oncomplete = () => resolve(request?.result);
        transaction.onerror = () => reject(transaction.error);
        transaction.onabort = () => reject(transaction.error || Error(t("文件存储已取消")));
    });
}

async function exportFilesForBackup() {
    const items = await fileStore('getAll');
    return Promise.all(items.map(encodeFile));
}

async function loadFileItems() {
    try {
        fileItems = await fileStore('getAll');
        if (filesMode) renderFiles();
    } catch {
        $('filesStatus').textContent = t("无法打开文件资料库，请检查存储权限。");
    }
}

async function importFiles(list) {
    if (fileImporting) return;
    fileImporting = true;
    fileImportCancelled = false;
    $('fileImportControls').hidden = !window.shiyeNativeFileStreaming;
    $('fileImportProgress').value = 0;
    $('cancelFileImport').disabled = false;
    $('selectFiles').disabled = true;
    try {
        const items = Array.from(list).map(file => ({
            id: crypto.randomUUID(), name: file.name, type: file.type || '', size: file.size,
            createdAt: new Date().toISOString(), note: '', rating: 0, blob: file
        }));
        await fileStore('merge', items);
        await loadFileItems();
        $('filesStatus').textContent = `${t("已收藏")} ${items.length} ${t("个文件。")}` +
            (nativeFileCollection() ? t("文件已复制到拾页资料库。") : t("文件保存在当前浏览器中。"));
    } catch {
        $('filesStatus').textContent = fileImportCancelled ? t('文件存储已取消') : t("文件未能保存，请检查可用空间或存储权限后重试。");
        await loadFileItems();
    } finally {
        fileImporting = false;
        $('fileImportControls').hidden = true;
        $('selectFiles').disabled = false;
        $('filePicker').value = '';
    }
}

async function exportFile(file) {
    try {
        if (nativeFileCollection()) {
            await nativeFileCollection().postMessage({action: 'export', value: file.native ? {id: file.id, native: true} : await encodeFile(file)});
            return;
        }
        const url = URL.createObjectURL(file.blob);
        const anchor = document.createElement('a');
        anchor.href = url;
        anchor.download = file.name;
        anchor.click();
        setTimeout(() => URL.revokeObjectURL(url), 30000);
    } catch {
        alert(t("文件导出失败，请重试。"));
    }
}

function fileKind(file) {
    const name = file.name.toLowerCase();
    if (file.type.startsWith('image/') || /\.(png|jpe?g|gif|webp|heic|svg|bmp|tiff?)$/.test(name)) return 'image';
    if (file.type === 'application/pdf' || name.endsWith('.pdf')) return 'pdf';
    if (/\.(zip|rar|7z|tar|gz)$/.test(name)) return 'archive';
    if (file.type.startsWith('text/') || /\.(txt|md|csv|json|log)$/.test(name)) return 'text';
    return 'other';
}

function fileIsRaster(file) {
    return /^image\/(png|jpeg|gif|webp|bmp)$/.test(file.type);
}

function fileSize(size) {
    if (size < 1024) return size + ' B';
    if (size < 1048576) return (size / 1024).toFixed(1) + ' KB';
    return (size / 1048576).toFixed(1) + ' MB';
}

function clearFileViewURLs() {
    for (const url of fileViewURLs) URL.revokeObjectURL(url);
    fileViewURLs = [];
}

function closeFilePreview() {
    if (filePreviewURL) URL.revokeObjectURL(filePreviewURL);
    filePreviewURL = null;
    $('filePreviewContent').replaceChildren();
}

function renderFiles() {
    clearFileViewURLs();
    for (const id of ['sitePanel', 'bookmarkPanel', 'notesPanel']) $(id).classList.add('hidden');
    $('filesPanel').classList.remove('hidden');
    for (const id of ['favoriteView', 'bookmarkView', 'notesView']) $(id).classList.remove('active');
    document.querySelectorAll('#groups .group').forEach(button => button.classList.remove('active'));
    $('filesView').classList.add('active');
    document.querySelector('.toolbar').style.display = 'none';
    $('addSite').style.display = 'none';
    $('title').textContent = t("文件收藏");
    $('subtitle').textContent = `${fileItems.length} ${t("个文件 · 收好你的图片与资料")}`;

    const query = $('filesSearch').value.trim().toLowerCase();
    const kind = $('filesType').value;
    const rating = $('filesRating').value;
    const from = $('filesFrom').value;
    const to = $('filesTo').value;
    const visible = fileItems.filter(file => {
        const date = new Date(file.createdAt);
        const day = [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'),
            String(date.getDate()).padStart(2, '0')].join('-');
        return (!query || [file.name, file.note].some(text => text.toLowerCase().includes(query))) &&
            (!kind || fileKind(file) === kind) &&
            (rating === '' || file.rating === Number(rating)) &&
            (!from || day >= from) && (!to || day <= to);
    }).sort((a, b) => b.createdAt.localeCompare(a.createdAt));

    $('fileCards').innerHTML = visible.length ? visible.map(file => {
        let cover;
        if (fileIsRaster(file)) {
            const url = file.native ? fileThumbnails.get(file.id) : URL.createObjectURL(file.blob);
            if (url && !file.native) fileViewURLs.push(url);
            cover = url ? `<img class="file-cover" src="${esc(url)}" alt="${esc(file.name)}">` : `<div class="file-icon">${t('图片')}</div>`;
        } else {
            const extension = file.name.split('.').pop().slice(0, 8).toUpperCase() || 'FILE';
            cover = `<div class="file-icon">${esc(extension)}</div>`;
        }
        return `<article class="card">
            ${cover}
            <div class="card-top">
                <div class="file-title">${esc(file.name)}</div>
                <button type="button" class="menu file-delete" data-id="${esc(file.id)}" aria-label="${t("删除文件")}">×</button>
            </div>
            <div class="file-meta">${fileSize(file.size)} · ${esc(new Date(file.createdAt).toLocaleDateString(ShiyeI18n.locale()))}${file.rating ? ' · ' + esc('★'.repeat(file.rating)) : ''}</div>
            ${file.note ? `<p class="file-note">${esc(file.note)}</p>` : ''}
            <div class="card-footer">
                <button class="subtle file-preview" data-id="${esc(file.id)}">${t("预览")}</button>
                <button class="subtle file-edit" data-id="${esc(file.id)}">${t("备注")}</button>
                <button class="subtle file-rate" data-id="${esc(file.id)}">${t("评级")}</button>
                <button class="subtle file-export" data-id="${esc(file.id)}">${t("导出")}</button>
            </div>
        </article>`;
    }).join('') : ("<div class=\"empty\"><strong>" + t("还没有匹配的文件") + "</strong>" + t("选择文件或拖入图片、文档，开始收藏") + "</div>");

    for (const file of visible.filter(file => file.native && fileIsRaster(file) && !fileThumbnails.has(file.id))) {
        fileThumbnails.set(file.id, '');
        nativeFileCollection().postMessage({action: 'thumbnail', value: file.id}).then(url => {
            if (url) { fileThumbnails.set(file.id, url); if (filesMode) renderFiles(); }
            else fileThumbnails.delete(file.id);
        }).catch(() => fileThumbnails.delete(file.id));
    }
    for (const button of $('fileCards').querySelectorAll('[data-id]')) {
        button.onclick = async () => {
            const file = fileItems.find(item => item.id === button.dataset.id);
            if (!file) return;
            if (button.classList.contains('file-preview')) {
                await previewFile(file);
            } else if (button.classList.contains('file-export')) {
                await exportFile(file);
            } else if (button.classList.contains('file-edit') || button.classList.contains('file-rate')) {
                const editingRating = button.classList.contains('file-rate');
                $('fileEditForm').dataset.id = file.id;
                $('fileEditHeading').textContent = editingRating ? t("文件评级") : t("文件备注");
                $('fileNoteField').classList.toggle('hidden', editingRating);
                $('fileRatingField').classList.toggle('hidden', !editingRating);
                $('fileNoteInput').value = file.note;
                $('fileRatingInput').value = String(file.rating);
                $('fileEditDialog').showModal();
            } else if (button.classList.contains('file-delete') && confirm(ShiyeI18n.format("删除收藏中的“{name}”？原始文件不受影响。", {name: file.name}))) {
                try {
                    await fileStore('delete', file.id);
                    await loadFileItems();
                } catch {
                    alert(t("删除失败，请重试。"));
                }
            }
        };
    }
}

async function previewFile(file) {
    if (nativeFileCollection() && (file.native || (!fileIsRaster(file) && fileKind(file) !== 'text'))) {
        try {
            await nativeFileCollection().postMessage({action: 'preview', value: file.native ? {id: file.id, native: true} : await encodeFile(file)});
        } catch {
            alert(t("文件预览失败，可导出后打开。"));
        }
        return;
    }
    closeFilePreview();
    $('filePreviewHeading').textContent = file.name;
    $('filePreviewDialog').dataset.id = file.id;
    $('filePreviewDialog').showModal();
    const box = $('filePreviewContent');
    if (fileIsRaster(file)) {
        filePreviewURL = URL.createObjectURL(file.blob);
        const image = document.createElement('img');
        image.src = filePreviewURL;
        image.alt = file.name;
        box.append(image);
    } else if (fileKind(file) === 'pdf') {
        filePreviewURL = URL.createObjectURL(new Blob([file.blob], {type: 'application/pdf'}));
        const frame = document.createElement('iframe');
        frame.src = filePreviewURL;
        frame.title = file.name;
        frame.setAttribute('sandbox', '');
        box.append(frame);
    } else if (fileKind(file) === 'text' && file.size <= 2 * 1024 * 1024) {
        const text = document.createElement('pre');
        text.textContent = await file.blob.text();
        if ($('filePreviewDialog').open && $('filePreviewDialog').dataset.id === file.id) box.append(text);
    } else {
        const message = document.createElement('p');
        message.textContent = t("此文件暂不支持网页预览，可导出后用相应应用打开。");
        box.append(message);
    }
    $('previewFileExport').onclick = () => exportFile(file);
}

const originalRenderForFiles = render;
render = function () {
    $('favoriteTools').classList.toggle('hidden', !favoriteMode || filesMode);
    if (filesMode) {
        renderGroups();
        renderFiles();
        return;
    }
    $('filesPanel').classList.add('hidden');
    $('filesView').classList.remove('active');
    clearFileViewURLs();
    originalRenderForFiles();
};

for (const id of ['favoriteView', 'bookmarkView', 'notesView', 'groups']) {
    $(id).addEventListener('click', () => { filesMode = false; }, true);
}
$('filesView').onclick = () => {
    filesMode = true;
    noteMode = false;
    bookmarkMode = false;
    favoriteMode = false;
    render();
    loadFileItems();
};
$('selectFiles').onclick = () => $('filePicker').click();
$('filePicker').onchange = event => importFiles(event.target.files);
$('filesDrop').ondragover = event => {
    event.preventDefault();
    $('filesDrop').classList.add('drag-over');
};
$('filesDrop').ondragleave = () => $('filesDrop').classList.remove('drag-over');
$('filesDrop').ondrop = event => {
    event.preventDefault();
    $('filesDrop').classList.remove('drag-over');
    importFiles(event.dataTransfer.files);
};
for (const id of ['filesSearch', 'filesType', 'filesRating', 'filesFrom', 'filesTo']) {
    $(id).addEventListener('input', renderFiles);
}
$('resetFilesFilters').onclick = () => {
    for (const id of ['filesSearch', 'filesType', 'filesRating', 'filesFrom', 'filesTo']) $(id).value = '';
    renderFiles();
};
$('filesColumns').value = localStorage.getItem('shiye-files-columns') || 'auto';
$('filesColumns').onchange = () => {
    document.documentElement.style.setProperty('--files-grid', gridColumns($('filesColumns').value));
    localStorage.setItem('shiye-files-columns', $('filesColumns').value);
};
$('filesColumns').onchange();
$('cancelFileEdit').onclick = () => $('fileEditDialog').close();
$('fileEditForm').onsubmit = async event => {
    event.preventDefault();
    const file = fileItems.find(item => item.id === $('fileEditForm').dataset.id);
    if (!file) return;
    const next = {...file, note: $('fileNoteInput').value.trim(), rating: Number($('fileRatingInput').value)};
    try {
        await fileStore('put', next);
        $('fileEditDialog').close();
        await loadFileItems();
    } catch {
        alert(t("保存失败，请检查存储空间。"));
    }
};
$('closeFilePreview').onclick = () => $('filePreviewDialog').close();
$('filePreviewDialog').addEventListener('close', closeFilePreview);
function updateFileStorageStatus() {
    $('filesStatus').textContent = nativeFileCollection()
    ? t("文件保存在拾页本机资料库中，加密备份包含文件内容。")
    : t("文件保存在当前浏览器中，清除网站数据会移除收藏。请定期导出加密备份。");
}
updateFileStorageStatus();
loadFileItems();

$('cancelFileImport').onclick = () => { fileImportCancelled = true; };

async function stageNativeFile(blob, metadata) {
    const bridge = nativeFileCollection();
    const token = await bridge.postMessage({action: 'beginImport', value: metadata});
    try {
        for (let offset = 0; offset < blob.size; offset += 1048576) {
            if (fileImportCancelled) throw Error('Cancelled');
            const part = await encodeFile({blob: blob.slice(offset, offset + 1048576)});
            await bridge.postMessage({action: 'appendImport', value: {token, offset, data: part.data}});
            $('fileImportProgress').value = Math.min(1, (offset + 1048576) / blob.size);
        }
        if (fileImportCancelled) throw Error('Cancelled');
        return token;
    } catch (error) {
        await bridge.postMessage({action: 'cancelImport', value: token});
        throw error;
    }
}

function backupPassword() {
    const password = prompt(t('请设置此备份的加密密码'));
    if (password === null) return null;
    if (!password) { alert(t('密码不能为空')); return null; }
    if (prompt(t('再次输入备份密码')) !== password) { alert(t('两次密码不一致')); return null; }
    return password;
}
const legacyExportBackup = $('exportBtn').onclick;
$('exportBtn').onclick = async () => {
    if (!window.shiyeNativeFileStreaming) return legacyExportBackup();
    const password = backupPassword();
    if (password === null) return;
    $('exportBtn').disabled = true;
    try { await nativeFileCollection().postMessage({action: 'exportArchive', value: {password}}); }
    catch (error) { alert(t('导出失败：') + error.message); }
    finally { $('exportBtn').disabled = false; }
};
// Native archives use authenticated, ordered frames and a final completion frame.
async function readWebBackupArchive(file, password) {
    const invalid = () => Error(t('密码错误或备份文件已损坏'));
    let offset = 0;
    async function read(count) {
        if (!Number.isSafeInteger(count) || count < 0 || count > file.size - offset) throw invalid();
        const bytes = new Uint8Array(await file.slice(offset, offset + count).arrayBuffer());
        if (bytes.length !== count) throw invalid();
        offset += count;
        return bytes;
    }
    const header = await read(25);
    if (new TextDecoder().decode(header.slice(0, 9)) !== 'SHIYE-A1\n') throw invalid();
    const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveKey']);
    const secret = await crypto.subtle.deriveKey({name: 'PBKDF2', salt: header.slice(9), iterations: 200000, hash: 'SHA-256'}, base, {name: 'AES-GCM', length: 256}, false, ['decrypt']);
    let frameIndex = 0;
    async function frame() {
        if (fileImportCancelled) throw Error(t('文件存储已取消'));
        const lengthBytes = await read(4);
        const length = new DataView(lengthBytes.buffer).getUint32(0);
        if (length < 28 || length > 64 * 1024 * 1024) throw invalid();
        const sealed = await read(length);
        const aad = new Uint8Array(33);
        aad.set(header);
        new DataView(aad.buffer).setBigUint64(25, BigInt(frameIndex));
        let plaintext;
        try {
            plaintext = await crypto.subtle.decrypt({name: 'AES-GCM', iv: sealed.slice(0, 12), additionalData: aad}, secret, sealed.slice(12));
        } catch { throw invalid(); }
        frameIndex++;
        $('fileImportProgress').value = offset / file.size;
        return plaintext;
    }
    async function json() {
        try {
            const value = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(await frame()));
            if (!value || Array.isArray(value) || typeof value !== 'object') throw invalid();
            return value;
        } catch (error) {
            if (fileImportCancelled) throw error;
            throw invalid();
        }
    }
    const counts = await json();
    if (![counts.groups, counts.notes, counts.files].every(count => Number.isSafeInteger(count) && count >= 0 && count <= 1000000)) throw invalid();
    const importedGroups = [], importedNotes = [], importedFiles = [];
    for (let index = 0; index < counts.groups; index++) importedGroups.push(await json());
    for (let index = 0; index < counts.notes; index++) importedNotes.push(await json());
    for (let index = 0; index < counts.files; index++) {
        const metadata = await json();
        if (!Number.isSafeInteger(metadata.size) || metadata.size < 0) throw invalid();
        let blob = new Blob([], {type: typeof metadata.type === 'string' ? metadata.type : ''});
        for (let remaining = metadata.size; remaining > 0;) {
            const block = await frame();
            const expected = Math.min(1048576, remaining);
            if (block.byteLength !== expected) throw invalid();
            blob = new Blob([blob, block], {type: blob.type});
            remaining -= expected;
        }
        importedFiles.push({...metadata, native: false, blob});
    }
    const completedFrames = frameIndex;
    const end = await json();
    if (end.finished !== true || end.frames !== completedFrames || offset !== file.size) throw invalid();
    return {data: {format: 'shiyebookmarks', version: 1, groups: importedGroups, notes: importedNotes}, files: decodeFiles(importedFiles)};
}

const legacyImportBackup = $('file').onchange;
$('file').onchange = async event => {
    const file = event.target.files[0];
    if (!file) return;
    let header;
    try { header = await file.slice(0, 9).text(); }
    catch { alert(t('导入失败：') + t('文件内容已损坏')); event.target.value = ''; return; }
    if (header !== 'SHIYE-A1\n' && !file.name.toLowerCase().endsWith('.shiye')) return legacyImportBackup(event);
    const password = prompt(t('请输入导出此备份时设置的密码'));
    if (password === null) { event.target.value = ''; return; }
    if (fileImporting) { event.target.value = ''; return; }
    fileImporting = true;
    fileImportCancelled = false;
    $('fileImportControls').hidden = false;
    $('cancelFileImport').disabled = false;
    let token;
    try {
        if (!window.shiyeNativeFileStreaming) {
            const archive = await readWebBackupArchive(file, password);
            if (fileImportCancelled) return;
            $('cancelFileImport').disabled = true;
            await importBackupData(archive.data, archive.files);
            return;
        }
        token = await stageNativeFile(file, {id: crypto.randomUUID(), name: file.name, type: 'application/octet-stream', size: file.size, note: '', rating: 0, createdAt: new Date().toISOString()});
        $('cancelFileImport').disabled = true;
        const archive = await nativeFileCollection().postMessage({action: 'inspectArchive', value: {token, password}});
        const importedGroups = validateBackupGroups(archive.groups);
        const importedNotes = validateImportedNotes(archive.notes);
        const mergedGroups = mergeImportedGroups(groups, importedGroups);
        const mergedNotes = mergeImportedNotes(notes, importedNotes);
        if (!confirm(t('确认导入？'))) return;
        await nativeFileCollection().postMessage({action: 'commitArchive', value: {token, groups: mergedGroups.next, notes: mergedNotes.next}});
        token = null;
        await loadFileItems();
        alert(t('导入完成。'));
    } catch (error) { alert(t('导入失败：') + error.message); }
    finally {
        if (token) {
            await nativeFileCollection().postMessage({action: 'cancelImport', value: token});
            await nativeFileCollection().postMessage({action: 'cancelArchive', value: token});
        }
        fileImporting = false;
        $('fileImportControls').hidden = true;
        event.target.value = '';
    }
};

const legacyCloudBackup = $('backupNow').onclick;
$('backupNow').onclick = async () => {
    if (!window.shiyeNativeFileStreaming) return legacyCloudBackup();
    const targets = [];
    if ($('backupIcloudEnabled').checked) targets.push('icloud');
    if ($('backupGoogleEnabled').checked) targets.push('google');
    if (!targets.length) { alert(t('请至少选择一个备份位置')); return; }
    const password = backupPassword();
    if (password === null) return;
    $('backupNow').disabled = true;
    try {
        const outcomes = await nativeFileCollection().postMessage({action: 'exportArchive', value: {password, targets}});
        if (Array.isArray(outcomes)) alert(outcomes.join('\n'));
    } catch (error) { alert(t('导出失败：') + error.message); }
    finally { $('backupNow').disabled = false; }
};
