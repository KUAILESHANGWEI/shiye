let pendingCloudSnapshot;
let cloudStatus = '';

function updateCloudStatus() {
    $('cloudSyncSection').hidden = !window.shiyeCloudAvailable;
    $('cloudSyncStatus').textContent = t(cloudStatus || 'iCloud 正在连接');
    if (window.shiyeIsPhone) document.querySelector('.note-paste-hint').textContent = t('长按正文可粘贴图片');
}
function applyCloudSnapshot() {
    if (!pendingCloudSnapshot || document.querySelector('dialog[open]') || noteEditorSaving || noteImageJobs) return;
    const snapshot = pendingCloudSnapshot;
    pendingCloudSnapshot = null;
    groups = snapshot.groups;
    notes = snapshot.notes;
    fileItems = decodeFiles(snapshot.files);
    if (!groups.some(group => group.id === selected)) selected = groups.find(group => !group.bookmarkCollection)?.id;
    render();
    window.webkit?.messageHandlers?.snapshotPresented?.postMessage(snapshot);
}
window.shiyeReceiveNativeSnapshot = snapshot => {
    if (!Array.isArray(snapshot.groups) || !Array.isArray(snapshot.notes) || !Array.isArray(snapshot.files)) return;
    pendingCloudSnapshot = snapshot;
    applyCloudSnapshot();
};
window.shiyeReceiveSyncStatus = status => { cloudStatus = status; updateCloudStatus(); };
for (const dialog of document.querySelectorAll('dialog')) dialog.addEventListener('close', () => queueMicrotask(applyCloudSnapshot));
window.addEventListener('shiye-language-changed', updateCloudStatus);
updateCloudStatus();

if (window.shiyeIsPhone) {
    document.body.classList.add('shiye-ios');
    function updatePhoneViewport() {
        const viewport = window.visualViewport;
        const height = viewport?.height ?? window.innerHeight;
        document.documentElement.style.setProperty('--phone-visible-height', `${height}px`);
        document.documentElement.style.setProperty('--phone-visible-top', `${viewport?.offsetTop ?? 0}px`);
        document.body.classList.toggle('phone-keyboard-open', height < document.documentElement.clientHeight - 100);
        const field = document.activeElement;
        if (field?.matches('dialog input, dialog textarea, dialog [contenteditable=true]')) {
            requestAnimationFrame(() => field.scrollIntoView({block: 'nearest'}));
        }
    }
    window.visualViewport?.addEventListener('resize', updatePhoneViewport);
    window.visualViewport?.addEventListener('scroll', updatePhoneViewport);
    window.addEventListener('resize', updatePhoneViewport);
    document.addEventListener('focusin', updatePhoneViewport);
    updatePhoneViewport();

    const nav = document.querySelector('.collection-nav');
    document.body.append(nav);
    const collectionTabs = ['favoriteView', 'bookmarkView', 'notesView', 'filesView'];
    let swipe;
    function swipeBlocked() {
        return document.querySelector('dialog[open], #lockScreen') || document.body.classList.contains('phone-menu-open');
    }
    document.addEventListener('touchstart', event => {
        swipe = null;
        const target = event.target;
        if (event.touches.length !== 1 || swipeBlocked()) return;
        if (!target.closest('.collection-nav') && target.closest('input, textarea, select, button, a, [contenteditable], .drag-handle, .size-control')) return;
        const touch = event.touches[0];
        swipe = {id: touch.identifier, x: touch.clientX, y: touch.clientY, time: performance.now()};
    }, {passive: true});
    document.addEventListener('touchmove', event => {
        if (!swipe) return;
        if (event.touches.length !== 1 || swipeBlocked()) { swipe = null; return; }
        const touch = event.touches[0];
        const dx = Math.abs(touch.clientX - swipe.x), dy = Math.abs(touch.clientY - swipe.y);
        if (dy > 12 && dy >= dx) { swipe = null; return; }
        if (dx > 12 && dx > dy * 1.5 && event.cancelable) event.preventDefault();
    }, {passive: false});
    document.addEventListener('touchend', event => {
        const gesture = swipe;
        swipe = null;
        if (!gesture || swipeBlocked() || event.touches.length) return;
        const touch = Array.from(event.changedTouches).find(touch => touch.identifier === gesture.id);
        if (!touch) return;
        const dx = touch.clientX - gesture.x, dy = touch.clientY - gesture.y;
        if (Math.abs(dx) < 60 || Math.abs(dx) <= Math.abs(dy) * 1.5 || performance.now() - gesture.time > 900) return;
        const index = collectionTabs.findIndex(id => $(id).classList.contains('active'));
        if (index < 0) return;
        const next = index + (dx < 0 ? 1 : -1);
        if (next >= 0 && next < collectionTabs.length) $(collectionTabs[next]).click();
    }, {passive: true});
    document.addEventListener('touchcancel', () => { swipe = null; }, {passive: true});

    $('mobileMenu').onclick = () => document.body.classList.toggle('phone-menu-open');
    $('mobileBackdrop').onclick = () => document.body.classList.remove('phone-menu-open');
    $('mobileSettings').onclick = () => $('settingsBtn').click();
    for (const id of ['favoriteView', 'bookmarkView', 'notesView', 'filesView', 'groups', 'settingsBtn', 'importBtn', 'exportBtn']) {
        $(id).addEventListener('click', () => document.body.classList.remove('phone-menu-open'));
    }
}
