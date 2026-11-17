(() => {
    const dialog = $('globalSearchDialog');
    const input = $('globalSearchInput');
    let files = [];
    let matches = [];
    let limit = 50;
    let generation = 0;
    let timer;

    function excerpt(text, query) {
        const value = String(text || '').replace(/\s+/g, ' ').trim();
        const index = value.toLocaleLowerCase().indexOf(query[0] || '');
        const start = Math.max(0, index - 35);
        return (start ? '…' : '') + value.slice(start, start + 140) + (value.length > start + 140 ? '…' : '');
    }
    function search() {
        const query = input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
        matches = [];
        if (!query.length) {
            $('globalSearchStatus').textContent = t('输入关键词，搜索所有收藏');
            $('globalSearchResults').replaceChildren();
            $('globalSearchMore').hidden = true;
            return;
        }
        function add(entry, values) {
            const text = values.filter(value => typeof value === 'string').join('\n').toLocaleLowerCase();
            if (query.every(word => text.includes(word))) matches.push(entry);
        }
        for (const group of groups) {
            if (!group.bookmarkCollection) add({kind: 'group', id: group.id, title: group.name, location: t('分组'), snippet: ''}, [group.name]);
            for (const site of group.sites) {
                const kind = group.bookmarkCollection ? 'bookmark' : 'website';
                const location = group.bookmarkCollection ? t('书签收藏') : `${t('网站')} · ${group.name}`;
                add({kind, id: site.id, groupId: group.id, title: site.name, location,
                    snippet: excerpt([site.url, site.description, site.note].filter(Boolean).join(' '), query)},
                [site.name, site.url, site.description, site.note, site.author, site.platform, group.name]);
            }
        }
        for (const note of notes) {
            add({kind: 'note', id: note.id, title: note.title || t('未命名笔记'), location: t('笔记收藏'), snippet: excerpt(note.body, query)},
                [note.title, note.body]);
        }
        for (const file of files) {
            add({kind: 'file', id: file.id, title: file.name, location: t('文件收藏'), snippet: excerpt(file.note || file.type, query)},
                [file.name, file.note, file.type]);
        }
        renderResults();
    }
    function renderResults() {
        $('globalSearchStatus').textContent = ShiyeI18n.format('找到 {count} 项结果', {count: matches.length});
        $('globalSearchResults').innerHTML = matches.slice(0, limit).map((entry, index) => `<button type="button" class="global-search-result" data-index="${index}">
            <span class="global-search-result-top"><strong>${esc(entry.title)}</strong><small>${esc(entry.location)}</small></span>
            ${entry.snippet ? `<span class="global-search-snippet">${esc(entry.snippet)}</span>` : ''}</button>`).join('');
        for (const button of $('globalSearchResults').querySelectorAll('button')) {
            button.onclick = () => openResult(matches[Number(button.dataset.index)]);
        }
        $('globalSearchMore').hidden = matches.length <= limit;
    }
    async function openSearch() {
        if ($('lockScreen')) return;
        const current = ++generation;
        if (document.body.classList.contains('phone-menu-open')) $('mobileBackdrop').click();
        if (!dialog.open) dialog.showModal();
        input.focus();
        limit = 50;
        files = [];
        search();
        try {
            const latest = await fileStore('getAll');
            if (current !== generation || !dialog.open) return;
            files = latest;
            search();
        } catch {
            if (current === generation && dialog.open) $('globalSearchStatus').textContent = t('文件收藏暂时无法读取，其他收藏仍可搜索');
        }
    }
    async function openResult(entry) {
        if (!entry) return;
        dialog.close();
        let card;
        if (entry.kind === 'group' || entry.kind === 'website') {
            const owner = groups.find(group => group.id === (entry.groupId || entry.id));
            if (!owner) return;
            filesMode = false;
            noteMode = false;
            bookmarkMode = false;
            favoriteMode = false;
            selected = owner.id;
            $('search').value = '';
            render();
            card = [...$('cards').querySelectorAll('.card')].find(item => item.dataset.siteId === entry.id);
        } else if (entry.kind === 'bookmark') {
            $('bookmarkView').click();
            $('resetBookmarkFilters').click();
            card = [...$('bookmarkCards').querySelectorAll('.bookmark-edit')].find(item => item.dataset.id === entry.id)?.closest('.card');
        } else if (entry.kind === 'note') {
            $('notesView').click();
            $('resetNotesFilters').click();
            card = [...$('noteCards').querySelectorAll('.note-show')].find(item => item.dataset.id === entry.id)?.closest('.card');
        } else {
            $('filesView').click();
            await loadFileItems();
            $('resetFilesFilters').click();
            card = [...$('fileCards').querySelectorAll('.file-preview')].find(item => item.dataset.id === entry.id)?.closest('.card');
        }
        document.querySelectorAll('.global-search-match').forEach(item => item.classList.remove('global-search-match'));
        const target = card || $('title');
        if (card) card.classList.add('global-search-match');
        target.scrollIntoView({block: 'center', behavior: 'smooth'});
    }
    $('globalSearchBtn').onclick = openSearch;
    $('closeGlobalSearch').onclick = () => dialog.close();
    dialog.addEventListener('close', () => { generation++; clearTimeout(timer); });
    input.addEventListener('input', () => {
        clearTimeout(timer);
        limit = 50;
        timer = setTimeout(search, 120);
    });
    input.addEventListener('keydown', event => {
        if (event.key === 'Enter') {
            event.preventDefault();
            clearTimeout(timer);
            search();
            $('globalSearchResults').querySelector('button')?.focus();
        }
    });
    $('globalSearchMore').onclick = () => { limit += 50; renderResults(); };
    document.addEventListener('keydown', event => {
        if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== 'k' || $('lockScreen')) return;
        if (document.querySelector('dialog[open]') && !dialog.open) return;
        event.preventDefault();
        openSearch();
    });
})();
