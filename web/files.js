// Files use the Mac application support directory or IndexedDB in the web preview.
let filesMode = false;
let fileItems = [];
let fileDBPromise;
let fileViewURLs = [];
let filePreviewURL = null;
let fileImporting = false;

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

function encodeFile(item) {
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
    if (!Array.isArray(records)) throw Error('文件收藏数据格式不正确');
    const ids = new Set();
    return records.map(record => {
        if (!record || typeof record.id !== 'string' ||
            !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(record.id) ||
            ids.has(record.id) || typeof record.name !== 'string' || !record.name ||
            typeof record.type !== 'string' || typeof record.note !== 'string' ||
            typeof record.createdAt !== 'string' || typeof record.data !== 'string' ||
            !Number.isInteger(record.rating) || record.rating < 0 || record.rating > 3 ||
            !Number.isSafeInteger(record.size) || record.size < 0) {
            throw Error('文件收藏数据不完整');
        }
        ids.add(record.id);
        const bytes = Uint8Array.from(atob(record.data), character => character.charCodeAt(0));
        if (bytes.length !== record.size) throw Error('文件内容已损坏');
        return {
            id: record.id, name: record.name, type: record.type, size: record.size,
            note: record.note, rating: record.rating, createdAt: record.createdAt,
            blob: new Blob([bytes], {type: record.type})
        };
    });
}

async function fileStore(action, value) {
    const bridge = nativeFileCollection();
    if (bridge) {
        if (action === 'getAll') return decodeFiles(await bridge.postMessage({action}));
        if (action === 'put') {
            await bridge.postMessage({action: 'merge', value: [await encodeFile(value)]});
        } else if (action === 'merge') {
            await bridge.postMessage({action, value: await Promise.all(value.map(encodeFile))});
        } else {
            await bridge.postMessage({action, value});
        }
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
        transaction.onabort = () => reject(transaction.error || Error('文件存储已取消'));
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
        $('filesStatus').textContent = '无法打开文件资料库，请检查存储权限。';
    }
}

async function importFiles(list) {
    if (fileImporting) return;
    fileImporting = true;
    $('selectFiles').disabled = true;
    try {
        const items = Array.from(list).map(file => ({
            id: crypto.randomUUID(), name: file.name, type: file.type || '', size: file.size,
            createdAt: new Date().toISOString(), note: '', rating: 0, blob: file
        }));
        await fileStore('merge', items);
        await loadFileItems();
        $('filesStatus').textContent = `已收藏 ${items.length} 个文件。` +
            (nativeFileCollection() ? '文件已复制到拾页资料库。' : '文件保存在当前浏览器中。');
    } catch {
        $('filesStatus').textContent = '文件未能保存，请检查可用空间或存储权限后重试。';
    } finally {
        fileImporting = false;
        $('selectFiles').disabled = false;
        $('filePicker').value = '';
    }
}

async function exportFile(file) {
    try {
        if (nativeFileCollection()) {
            await nativeFileCollection().postMessage({action: 'export', value: await encodeFile(file)});
            return;
        }
        const url = URL.createObjectURL(file.blob);
        const anchor = document.createElement('a');
        anchor.href = url;
        anchor.download = file.name;
        anchor.click();
        setTimeout(() => URL.revokeObjectURL(url), 30000);
    } catch {
        alert('文件导出失败，请重试。');
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
    $('title').textContent = '文件收藏';
    $('subtitle').textContent = `${fileItems.length} 个文件 · 收好你的图片与资料`;

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
            const url = URL.createObjectURL(file.blob);
            fileViewURLs.push(url);
            cover = `<img class="file-cover" src="${esc(url)}" alt="${esc(file.name)}">`;
        } else {
            const extension = file.name.split('.').pop().slice(0, 8).toUpperCase() || 'FILE';
            cover = `<div class="file-icon">${esc(extension)}</div>`;
        }
        return `<article class="card">
            ${cover}
            <div class="card-top">
                <div class="file-title">${esc(file.name)}</div>
                <button type="button" class="menu file-delete" data-id="${esc(file.id)}" aria-label="删除文件">×</button>
            </div>
            <div class="file-meta">${fileSize(file.size)} · ${esc(new Date(file.createdAt).toLocaleDateString('zh-CN'))}${file.rating ? ' · ' + esc('★'.repeat(file.rating)) : ''}</div>
            ${file.note ? `<p class="file-note">${esc(file.note)}</p>` : ''}
            <div class="card-footer">
                <button class="subtle file-preview" data-id="${esc(file.id)}">预览</button>
                <button class="subtle file-edit" data-id="${esc(file.id)}">备注</button>
                <button class="subtle file-rate" data-id="${esc(file.id)}">评级</button>
                <button class="subtle file-export" data-id="${esc(file.id)}">导出</button>
            </div>
        </article>`;
    }).join('') : '<div class="empty"><strong>还没有匹配的文件</strong>选择文件或拖入图片、文档，开始收藏</div>';

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
                $('fileEditHeading').textContent = editingRating ? '文件评级' : '文件备注';
                $('fileNoteField').classList.toggle('hidden', editingRating);
                $('fileRatingField').classList.toggle('hidden', !editingRating);
                $('fileNoteInput').value = file.note;
                $('fileRatingInput').value = String(file.rating);
                $('fileEditDialog').showModal();
            } else if (button.classList.contains('file-delete') && confirm(`删除收藏中的“${file.name}”？原始文件不受影响。`)) {
                try {
                    await fileStore('delete', file.id);
                    await loadFileItems();
                } catch {
                    alert('删除失败，请重试。');
                }
            }
        };
    }
}

async function previewFile(file) {
    if (nativeFileCollection() && !fileIsRaster(file) && fileKind(file) !== 'text') {
        try {
            await nativeFileCollection().postMessage({action: 'preview', value: await encodeFile(file)});
        } catch {
            alert('文件预览失败，可导出后打开。');
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
        message.textContent = '此文件暂不支持网页预览，可导出后用相应应用打开。';
        box.append(message);
    }
    $('previewFileExport').onclick = () => exportFile(file);
}

const originalRenderForFiles = render;
render = function () {
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
        alert('保存失败，请检查存储空间。');
    }
};
$('closeFilePreview').onclick = () => $('filePreviewDialog').close();
$('filePreviewDialog').addEventListener('close', closeFilePreview);
$('filesStatus').textContent = nativeFileCollection()
    ? '文件保存在拾页本机资料库中，加密备份包含文件内容。'
    : '文件保存在当前浏览器中，清除网站数据会移除收藏。请定期导出加密备份。';
loadFileItems();
