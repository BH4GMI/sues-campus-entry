(function () {
    var out = {};
    out.bodyClass = String(document.body.className);
    out.vModal = (function () {
        var m = document.querySelector('.v-modal');
        return m ? { display: getComputedStyle(m).display, inline: m.style.display || '' } : null;
    })();

    var wraps = document.querySelectorAll('.el-dialog__wrapper');
    out.wrappers = Array.prototype.map.call(wraps, function (w) {
        var r = w.getBoundingClientRect();
        var isOpen = getComputedStyle(w).display !== 'none';
        var btn = w.querySelector('.el-dialog__headerbtn, .el-dialog__close, button.el-dialog__headerbtn');
        var inner = w.querySelector('.el-dialog');
        var notice = w.querySelector('.alert-notice, .alert-notice-item');
        return {
            cls: String(w.className).slice(0, 55),
            open: isOpen,
            w: Math.round(r.width),
            h: Math.round(r.height),
            title: (w.querySelector('.el-dialog__title') || {}).textContent || '',
            closeBtn: btn ? String(btn.className) : null,
            closeBtnTag: btn ? btn.tagName : null,
            closeBtnVisible: btn ? btn.offsetParent !== null : false,
            closeBtnRect: btn ? (function () { var b = btn.getBoundingClientRect(); return { w: Math.round(b.width), h: Math.round(b.height), top: Math.round(b.top), left: Math.round(b.left) }; })() : null,
            innerDisplay: inner ? getComputedStyle(inner).display : null,
            hasNotice: !!notice,
            noticeItems: w.querySelectorAll('.alert-notice-item').length
        };
    }).filter(function (x) { return x.open || x.hasNotice; });

    out.alertNoticeParents = Array.prototype.map.call(document.querySelectorAll('.alert-notice'), function (e) {
        var chain = [], node = e, d = 0;
        while (node && d < 4) {
            chain.push(node.tagName + '.' + String(node.className).slice(0, 40));
            node = node.parentElement;
            d++;
        }
        return chain;
    });

    return JSON.stringify(out, null, 1);
})()
