const notesKey = 'shiye-notes-preview-v1';
let notes = [];
try {
    const loaded = JSON.parse(window.shiyeNativeNotes || localStorage.getItem(notesKey) || '[]');
    if (Array.isArray(loaded)) notes = loaded;
} catch {}
let noteWriteQueue = Promise.resolve();
let noteEditSession = 0;
let noteImageJobs = 0;
let noteEditorSaving = false;

function noteContent(note) {
    return note?.content || (note?.body ? [{type: 'text', text: note.body}] : []);
}

function validNoteImage(data) {
    if (typeof data !== 'string' || !/^data:image\/(png|jpeg|gif|webp|bmp);base64,[A-Za-z0-9+/]+={0,2}$/.test(data)) return false;
    try { return atob(data.slice(data.indexOf(',') + 1)).length > 0; } catch { return false; }
}

function validateImportedNotes(value) {
    if (value === undefined) return [];
    if (!Array.isArray(value)) throw Error(t('笔记数据格式不正确'));
    const ids = new Set();
    return value.map(note => {
        if (!note || typeof note.id !== 'string' || !note.id || ids.has(note.id) ||
            typeof note.title !== 'string' || typeof note.body !== 'string' ||
            typeof note.createdAt !== 'string' || !Number.isInteger(note.rating) || note.rating < 0 || note.rating > 3) {
            throw Error(t('笔记数据不完整'));
        }
        const record = {id: note.id, title: note.title, body: note.body, createdAt: note.createdAt, rating: note.rating};
        if (note.content !== undefined) {
            if (!Array.isArray(note.content)) throw Error(t('笔记数据不完整'));
            record.content = note.content.map(part => {
                if (part?.type === 'text' && typeof part.text === 'string') return {type: 'text', text: part.text};
                if (part?.type === 'image' && validNoteImage(part.data)) return {type: 'image', data: part.data};
                throw Error(t('笔记数据不完整'));
            });
            if (record.content.filter(part => part.type === 'text').map(part => part.text).join('').trim() !== note.body.trim()) {
                throw Error(t('笔记数据不完整'));
            }
        }
        if (!note.body.trim() && !record.content?.some(part => part.type === 'image')) throw Error(t('笔记数据不完整'));
        ids.add(note.id);
        return record;
    });
}

function mergeImportedNotes(local, incoming) {
    const next = structuredClone(local);
    let added = 0, updated = 0;
    for (const note of incoming) {
        const index = next.findIndex(item => item.id === note.id);
        if (index < 0) {
            next.push(structuredClone(note));
            added++;
            continue;
        }
        const old = next[index];
        const replacement = {...note};
        // Older backups cannot describe images. Keep them when their text is unchanged.
        if (note.content === undefined && old.content && old.body === note.body) replacement.content = old.content;
        if (['title', 'body', 'createdAt', 'rating'].some(key => old[key] !== replacement[key]) ||
            JSON.stringify(old.content) !== JSON.stringify(replacement.content)) {
            next[index] = structuredClone(replacement);
            updated++;
        }
    }
    return {next, added, updated};
}

function saveNotes(change = current => current) {
    const task = noteWriteQueue.then(async () => {
        const next = typeof change === 'function' ? change(structuredClone(notes)) : structuredClone(change);
        const data = JSON.stringify(next);
        const bridge = window.webkit?.messageHandlers?.persistNotes;
        if (bridge) await bridge.postMessage(data);
        else localStorage.setItem(notesKey, data);
        notes = next;
        return true;
    }).catch(() => {
        alert(t('保存失败，请检查存储空间。'));
        return false;
    });
    noteWriteQueue = task.then(() => {});
    return task;
}

function fillNoteContent(container, content) {
    container.replaceChildren();
    for (const part of content) {
        if (part.type === 'text') container.append(document.createTextNode(part.text));
        else if (part.type === 'image' && validNoteImage(part.data)) {
            const image = document.createElement('img');
            image.src = part.data;
            image.alt = t('笔记图片');
            container.append(image);
        }
    }
}

function renderNotes() {
    $('bookmarkPanel').classList.add('hidden');
    $('sitePanel').classList.add('hidden');
    $('bookmarkView').classList.remove('active');
    $('favoriteView').classList.remove('active');
    document.querySelectorAll('#groups .group').forEach(button => button.classList.remove('active'));
    document.querySelector('.toolbar').style.display = 'none';
    $('addSite').style.display = 'none';
    $('title').textContent = t('笔记收藏');
    $('subtitle').textContent = `${notes.length} ${t('条笔记 · 收好值得记下的内容')}`;
    const query = $('notesSearch').value.trim().toLowerCase();
    const rating = $('notesRating').value;
    const precision = $('notesDatePrecision').value;
    const from = $('notesFrom').value, to = $('notesTo').value;
    const filtered = notes.filter(note => {
        const date = note.createdAt ? new Date(note.createdAt) : null;
        const day = date && !isNaN(date) ? [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-').slice(0, {year: 4, month: 7, day: 10}[precision]) : '';
        return (!query || [note.title || '', note.body || ''].some(text => text.toLowerCase().includes(query))) &&
            (rating === '' || (note.rating || 0) === Number(rating)) && (!from || day >= from) && (!to || day <= to);
    });
    $('noteCards').innerHTML = filtered.length ? filtered.slice().reverse().map(note => {
        const image = noteContent(note).find(part => part.type === 'image' && validNoteImage(part.data));
        return `<article class="card ${image ? 'note-with-image' : ''}"><div class="card-top"><div class="note-heading">${esc(note.title || t('未命名笔记'))}</div><button class="menu note-delete" data-id="${esc(note.id)}" title="${t('删除笔记')}" aria-label="${t('删除笔记')}">×</button></div>
            ${image ? `<img class="note-card-image" src="${esc(image.data)}" alt="${t('笔记图片')}">` : ''}
            <p class="note-content">${esc(note.body)}</p><div class="note-meta">${note.rating ? '★'.repeat(note.rating) + ' · ' : ''}${note.createdAt ? esc(new Date(note.createdAt).toLocaleString(ShiyeI18n.locale())) : t('时间未知')}</div>
            <div class="card-footer"><button type="button" class="subtle note-show" data-id="${esc(note.id)}">${t('显示')}</button><button type="button" class="subtle note-edit" data-id="${esc(note.id)}">${t('编辑')}</button><button type="button" class="subtle note-rate" data-id="${esc(note.id)}">${t('评级')}</button></div></article>`;
    }).join('') : `<div class="empty"><strong>${t('还没有匹配的笔记')}</strong>${t('点击“新建笔记”记录内容，或调整筛选条件')}</div>`;
    $('noteCards').querySelectorAll('.note-show').forEach(button => button.onclick = () => {
        const note = notes.find(item => item.id === button.dataset.id);
        if (!note) return;
        $('detailsTitle').textContent = note.title || t('笔记');
        fillNoteContent($('detailsText'), noteContent(note));
        $('detailsDialog').showModal();
    });
    $('noteCards').querySelectorAll('.note-edit').forEach(button => button.onclick = () => {
        const note = notes.find(item => item.id === button.dataset.id);
        if (note) openNoteEditor(note);
    });
    $('noteCards').querySelectorAll('.note-rate').forEach(button => button.onclick = () => {
        const note = notes.find(item => item.id === button.dataset.id);
        if (!note) return;
        $('noteRatingDialog').dataset.id = note.id;
        updateNoteRating(note.rating || 0);
        $('noteRatingDialog').showModal();
    });
    $('noteCards').querySelectorAll('.note-delete').forEach(button => button.onclick = async () => {
        const note = notes.find(item => item.id === button.dataset.id);
        if (note && confirm(ShiyeI18n.format('删除“{name}”？', {name: note.title || t('未命名笔记')}))) {
            await saveNotes(current => current.filter(item => item.id !== note.id));
            renderNotes();
        }
    });
}

function editorNoteContent() {
    const content = [];
    function text(value) {
        if (!value) return;
        const last = content[content.length - 1];
        if (last?.type === 'text') last.text += value;
        else content.push({type: 'text', text: value});
    }
    function newline() {
        const last = content[content.length - 1];
        if (last && !(last.type === 'text' && last.text.endsWith('\n'))) text('\n');
    }
    function visit(node) {
        if (node.nodeType === Node.TEXT_NODE) text(node.textContent);
        else if (node.nodeName === 'IMG') {
            if (validNoteImage(node.getAttribute('src'))) content.push({type: 'image', data: node.getAttribute('src')});
        } else if (node.nodeName === 'BR') text('\n');
        else {
            const block = ['DIV', 'P', 'LI'].includes(node.nodeName);
            if (block && node.previousSibling) newline();
            for (const child of node.childNodes) visit(child);
            if (block && node.nextSibling) newline();
        }
    }
    for (const child of $('noteEditBody').childNodes) visit(child);
    return content;
}

function openNoteEditor(note) {
    noteEditSession++;
    noteImageJobs = 0;
    $('saveNote').disabled = false;
    $('noteEditForm').dataset.id = note?.id || '';
    $('noteEditHeading').textContent = note ? t('编辑笔记') : t('新建笔记');
    $('noteEditTitle').value = note?.title || $('newNoteTitle').value.trim();
    $('noteEditError').textContent = '';
    fillNoteContent($('noteEditBody'), noteContent(note));
    $('noteEditDialog').showModal();
    $('noteEditBody').focus();
}

function insertNoteText(text, range) {
    const editor = $('noteEditBody');
    editor.focus();
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    if (!document.execCommand('insertText', false, text)) {
        range.deleteContents();
        const node = document.createTextNode(text);
        range.insertNode(node);
        range.setStartAfter(node);
        range.collapse(true);
        selection.removeAllRanges();
        selection.addRange(range);
    }
}

$('noteEditBody').addEventListener('paste', async event => {
    const editor = $('noteEditBody');
    const clipboard = event.clipboardData;
    if (!clipboard || noteEditorSaving) return;
    event.preventDefault();
    const selection = window.getSelection();
    let range = selection.rangeCount && editor.contains(selection.anchorNode) ? selection.getRangeAt(0).cloneRange() : document.createRange();
    if (!editor.contains(range.commonAncestorContainer)) { range.selectNodeContents(editor); range.collapse(false); }
    const images = Array.from(clipboard.items).filter(item => item.kind === 'file' && item.type.startsWith('image/')).map(item => item.getAsFile()).filter(Boolean);
    if (!images.length) { insertNoteText(clipboard.getData('text/plain'), range); return; }
    const session = noteEditSession;
    noteImageJobs++;
    $('saveNote').disabled = true;
    $('noteEditError').textContent = '';
    try {
        for (const file of images) {
            const data = await new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result);
                reader.onerror = () => reject(reader.error);
                reader.readAsDataURL(file);
            });
            if (session !== noteEditSession) return;
            if (!validNoteImage(data)) throw Error(t('无法粘贴此图片，请复制 PNG、JPEG 或 GIF 图片后重试。'));
            const image = new Image();
            image.src = data;
            await image.decode();
            if (session !== noteEditSession) return;
            editor.focus();
            selection.removeAllRanges();
            selection.addRange(range);
            if (!document.execCommand('insertImage', false, data)) {
                range.deleteContents();
                image.alt = t('笔记图片');
                range.insertNode(image);
                range.setStartAfter(image);
                range.collapse(true);
                selection.removeAllRanges();
                selection.addRange(range);
            }
            range = selection.getRangeAt(0).cloneRange();
        }
    } catch {
        if (session === noteEditSession) $('noteEditError').textContent = t('无法粘贴此图片，请复制 PNG、JPEG 或 GIF 图片后重试。');
    } finally {
        if (session === noteEditSession) { noteImageJobs--; $('saveNote').disabled = noteImageJobs > 0; }
    }
});
$('noteEditBody').addEventListener('drop', event => event.preventDefault());
$('noteEditDialog').addEventListener('close', () => { noteEditSession++; $('noteEditBody').replaceChildren(); });
$('noteEditDialog').addEventListener('cancel', event => { if (noteEditorSaving) event.preventDefault(); });
$('notesView').onclick = () => { noteMode = true; favoriteMode = false; bookmarkMode = false; render(); };
$('addNote').onclick = () => openNoteEditor();
$('cancelNoteEdit').onclick = () => $('noteEditDialog').close();
$('noteEditForm').onsubmit = async event => {
    event.preventDefault();
    if (noteImageJobs || noteEditorSaving) return;
    const content = editorNoteContent();
    const body = content.filter(part => part.type === 'text').map(part => part.text).join('').trim();
    if (!body && !content.some(part => part.type === 'image')) { $('noteEditError').textContent = t('请写入笔记或粘贴图片'); return; }
    const id = $('noteEditForm').dataset.id;
    const title = $('noteEditTitle').value.trim();
    noteEditorSaving = true;
    $('saveNote').disabled = true;
    $('cancelNoteEdit').disabled = true;
    $('noteEditBody').contentEditable = 'false';
    $('noteEditTitle').disabled = true;
    try {
        const saved = await saveNotes(current => {
            const existing = current.find(item => item.id === id);
            if (existing) Object.assign(existing, {title, body, content});
            else current.push({id: crypto.randomUUID(), title, body, content, createdAt: new Date().toISOString(), rating: 0});
            return current;
        });
        if (saved) { $('newNoteTitle').value = ''; $('noteEditDialog').close(); renderNotes(); }
    } finally {
        noteEditorSaving = false;
        $('saveNote').disabled = false;
        $('cancelNoteEdit').disabled = false;
        $('noteEditBody').contentEditable = 'true';
        $('noteEditTitle').disabled = false;
    }
};
function updateNoteRating(value) {
    $('noteRatingDialog').querySelectorAll('[data-note-rating]').forEach(button => button.style.opacity = Number(button.dataset.noteRating) <= value ? '1' : '0.3');
}
async function setNoteRating(value) {
    const id = $('noteRatingDialog').dataset.id;
    const saved = await saveNotes(current => { const note = current.find(item => item.id === id); if (note) note.rating = value; return current; });
    if (saved) { $('noteRatingDialog').close(); renderNotes(); }
}
$('noteRatingDialog').querySelectorAll('[data-note-rating]').forEach(button => button.onclick = () => setNoteRating(Number(button.dataset.noteRating)));
$('clearNoteRating').onclick = () => setNoteRating(0);
$('cancelNoteRating').onclick = () => $('noteRatingDialog').close();
$('notesDatePrecision').onchange = () => {
    const type = {year: 'number', month: 'month', day: 'date'}[$('notesDatePrecision').value];
    for (const id of ['notesFrom', 'notesTo']) { $(id).value = ''; $(id).type = type; }
    renderNotes();
};
$('resetNotesFilters').onclick = () => { for (const id of ['notesSearch', 'notesRating', 'notesFrom', 'notesTo']) $(id).value = ''; renderNotes(); };
for (const id of ['notesSearch', 'notesRating', 'notesFrom', 'notesTo']) $(id).addEventListener('input', renderNotes);
$('notesColumns').value = localStorage.getItem('shiye-notes-columns') || '4';
$('notesColumns').onchange = () => {
    document.documentElement.style.setProperty('--notes-grid', gridColumns($('notesColumns').value));
    localStorage.setItem('shiye-notes-columns', $('notesColumns').value);
};
$('notesColumns').onchange();
