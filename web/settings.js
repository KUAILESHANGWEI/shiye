let changingPasswordKey;
let changingPasswordRecord;
let passwordChangePending = false;

$('settingsBtn').onclick = () => $('settingsDialog').showModal();
$('closeSettings').onclick = () => $('settingsDialog').close();

function openPasswordSettings(key) {
    changingPasswordKey = key;
    changingPasswordRecord = localStorage.getItem(key);
    $('changePasswordForm').reset();
    $('changePasswordError').textContent = '';
    $('changePasswordSuccess').textContent = '';
    $('changePasswordTitle').textContent = key === lockKey ? t('修改开机密码') : t('设置删除密码');
    $('currentPasswordField').hidden = !changingPasswordRecord;
    $('currentPassword').required = !!changingPasswordRecord;
    $('changePasswordDialog').showModal();
    $(changingPasswordRecord ? 'currentPassword' : 'newPassword').focus();
}

$('changeLaunchPassword').onclick = () => openPasswordSettings(lockKey);
$('changeDeletePassword').onclick = () => openPasswordSettings(passKey);
$('cancelChangePassword').onclick = () => $('changePasswordDialog').close();
$('changePasswordDialog').addEventListener('close', () => {
    $('changePasswordForm').reset();
    changingPasswordRecord = null;
});

$('changePasswordForm').onsubmit = async event => {
    event.preventDefault();
    if (passwordChangePending) return;
    const targetKey = changingPasswordKey;
    const originalRecord = changingPasswordRecord;
    const currentPassword = $('currentPassword').value;
    const nextPassword = $('newPassword').value;
    const confirmation = $('confirmPassword').value;
    $('changePasswordError').textContent = '';
    $('changePasswordSuccess').textContent = '';
    if (!nextPassword) {
        $('changePasswordError').textContent = t('密码不能为空');
        return;
    }
    if (nextPassword !== confirmation) {
        $('changePasswordError').textContent = t('两次密码不一致');
        return;
    }
    passwordChangePending = true;
    $('savePassword').disabled = true;
    $('cancelChangePassword').disabled = true;
    try {
        if (originalRecord) {
            const record = JSON.parse(originalRecord);
            if (await digest(currentPassword, unb64(record.salt)) !== record.check) {
                $('changePasswordError').textContent = t('当前密码错误');
                return;
            }
        }
        const salt = crypto.getRandomValues(new Uint8Array(16));
        const nextRecord = JSON.stringify({salt: b64(salt), check: await digest(nextPassword, salt)});
        if (localStorage.getItem(targetKey) !== originalRecord) {
            $('changePasswordError').textContent = t('密码已在其他窗口更改，请关闭后重试。');
            return;
        }
        localStorage.setItem(targetKey, nextRecord);
        if (targetKey === lockKey) lockRecord = nextRecord;
        changingPasswordRecord = nextRecord;
        $('changePasswordForm').reset();
        $('currentPasswordField').hidden = false;
        $('currentPassword').required = true;
        $('changePasswordSuccess').textContent = t('密码已修改');
    } catch {
        $('changePasswordError').textContent = t('无法保存密码，请检查存储权限后重试。');
    } finally {
        passwordChangePending = false;
        $('savePassword').disabled = false;
        $('cancelChangePassword').disabled = false;
    }
};
$('changePasswordDialog').addEventListener('cancel', event => {
    if (passwordChangePending) event.preventDefault();
});

for (const picker of document.querySelectorAll('[data-language-picker]')) {
    picker.value = ShiyeI18n.preference();
    picker.onchange = () => {
        try {
            ShiyeI18n.setLanguage(picker.value);
            for (const other of document.querySelectorAll('[data-language-picker]')) other.value = picker.value;
            render();
            updateFileStorageStatus();
            if ($('lockScreen')) {
                $('lockTitle').textContent = lockRecord ? t('欢迎回来') : t('设置开机密码');
                $('lockHint').textContent = lockRecord ? t('请输入开机密码，打开你的收藏。') : t('首次使用，请设置打开拾页时使用的密码。');
                $('lockError').textContent = '';
            }
        } catch {
            alert(t('无法保存语言设置，请检查存储权限。'));
        }
    };
}

window.addEventListener('shiye-language-changed', () => {
    render();
    updateFileStorageStatus();
});
