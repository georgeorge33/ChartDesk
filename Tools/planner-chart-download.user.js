// ==UserScript==
// @name         MSFS Planner chart downloader
// @namespace    local.chartdesk
// @version      3.0
// @description  Alt-click a chart on planner.flightsimulator.com, name it, and save the full-resolution PNG
// @match        https://planner.flightsimulator.com/*
// @connect      foxtrotatlasprod.blob.core.windows.net
// @connect      blob.core.windows.net
// @grant        GM_download
// @grant        GM_xmlhttpRequest
// @run-at       document-idle
// ==/UserScript==

// Saves the chart you are looking at, at the size the server sent it — 2480×3507 for an A4
// plate, which is what a Chartdesk library already holds.
//
// The viewer keeps the chart in a plain <img>, so there is nothing clever to do about finding
// it. What does need care is fetching it: the image lives on Azure blob storage behind a signed
// URL, cross-origin to the page, and a blob store has no reason to send CORS headers. An <img>
// does not need them, so the page displays it happily, while a `fetch` from the page would be
// refused. GM_download and GM_xmlhttpRequest run privileged and are not subject to that, which
// is the only reason this needs a userscript manager rather than a bookmarklet.

(function () {
    'use strict';

    // Which variant the box offers first. Your library holds the dark plates; the box can
    // switch per chart when the viewer has both.
    const PREFER_DARK = true;

    // Where files land, *relative to the browser's own download folder*. Nothing here can
    // escape it: a page hands the browser a name, and only the browser decides the directory.
    // To file charts into the library, point the browser's download folder at the library and
    // let these two put each chart in its airport's folder.
    //
    //   SUBFOLDER = ''        download folder itself
    //   SUBFOLDER = 'Charts'  a Charts folder inside it
    const SUBFOLDER = '';

    // 'KBOS AGC.png' lands as 'KBOS/AGC.png', which is how a Chartdesk library is laid out:
    // a folder per airport, the chart's code as the name.
    const FILE_BY_AIRPORT = true;

    /** Charts live under this path on the blob store; the map's own sprites do not. */
    const CHART_PATH = /blob\.core\.windows\.net\/charts\/chart-files\//i;

    const ACCENT = '#185890';

    // --- Finding the chart ----------------------------------------------------------------

    function isVisible(element) {
        if (!element.getClientRects || element.getClientRects().length === 0) return false;
        const style = getComputedStyle(element);
        return style.visibility !== 'hidden'
            && style.display !== 'none'
            && Number(style.opacity) > 0.05;
    }

    function candidates() {
        return [...document.images]
            .map((image) => {
                const url = image.currentSrc || image.src || '';
                return {
                    url,
                    isChart: CHART_PATH.test(url),
                    isDark: /-dark\.png/i.test(url),
                    pixels: image.naturalWidth * image.naturalHeight,
                    size: image.naturalWidth + '×' + image.naturalHeight,
                    visible: isVisible(image)
                };
            })
            // A chart is either on the known path or simply far bigger than any interface art.
            .filter((entry) => entry.isChart || entry.pixels >= 1500 * 1500)
            .sort((a, b) => b.pixels - a.pixels);
    }

    /** The largest chart of the asked-for variant, preferring one that is on screen. */
    function variant(all, dark) {
        const matching = all.filter((entry) => entry.isDark === dark);
        if (matching.length === 0) return null;
        return matching.find((entry) => entry.visible) || matching[0];
    }

    // --- The name the box opens with -------------------------------------------------------

    // What a chart is called, wherever the words turn up.
    const CHART_WORDS = /\b(RWY|ILS|LOC|LLZ|RNAV|RNP|GLS|VOR|NDB|TACAN|SID|STAR|DEPARTURE|ARRIVAL|APPROACH|APCH|VISUAL|DIAGRAM|TAXI|PARKING|GROUND|APRON|MINIMA|BRIEFING|AFC|AGC|APC|ADC|AOI|LVC|IAC|VAC|MVC|10-9)\b/i;

    const NOT_ICAO = new Set(['CHART', 'CHARTS', 'PLAN', 'PLANS', 'FLIGHT', 'HELP', 'INFO',
                              'MENU', 'VIEW', 'ZOOM', 'TRUE', 'NULL', 'NONE', 'PAGE', 'OPEN',
                              'DARK', 'LIGHT', 'SAVE', 'LOAD', 'MORE', 'EDIT', 'TEXT', 'FROM',
                              'ROUTE', 'WIND', 'FUEL', 'TIME', 'DATE', 'NAME', 'TYPE']);

    /** Short pieces of visible text, which is where a chart's name would be if anywhere. */
    function visibleText() {
        const found = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const text = (node.nodeValue || '').trim();
            if (text.length < 3 || text.length > 70) continue;
            const parent = node.parentElement;
            if (!parent || !isVisible(parent)) continue;
            found.push(text);
        }
        return found;
    }

    /** A starting point only — you type over it. Empty when there is nothing worth offering. */
    function guessStem() {
        const texts = visibleText();

        const named = texts.filter((text) => CHART_WORDS.test(text));
        // A chart's name mentions the procedure; a paragraph about it does not read like one.
        named.sort((a, b) => a.length - b.length);
        const title = named[0] || '';

        let icao = '';
        const inputs = [...document.querySelectorAll('input')]
            // Not this script's own field: it still holds the last name typed, so a chart at
            // one airport would otherwise be offered the airport before it.
            .filter((input) => !(box && box.card.contains(input)))
            .map((input) => (input.value || '').trim().toUpperCase());
        for (const text of [...inputs, ...texts.map((entry) => entry.toUpperCase())]) {
            const codes = text.match(/\b[A-Z]{4}\b/g) || [];
            const code = codes.find((candidate) => !NOT_ICAO.has(candidate));
            if (code) { icao = code; break; }
        }

        return [icao, title].filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
    }

    /** The path handed to the browser, which is a name and at most some folders under it. */
    function destination(name) {
        let path = name;
        if (FILE_BY_AIRPORT) {
            const split = name.match(/^([A-Za-z]{4})[ _-]+(.+)$/);
            if (split) path = split[1].toUpperCase() + '/' + split[2];
        }
        return [SUBFOLDER, path].filter(Boolean).join('/');
    }

    /// Upper case throughout, which is how charts are named and what the airport code has to
    /// be for anything downstream to file it. The extension stays lower case.
    function clean(stem) {
        const name = String(stem).replace(/\.png$/i, '')
            .replace(/[\\/:*?"<>|]/g, ' ')
            .replace(/\s+/g, ' ')
            .trim()
            .toUpperCase();
        return (name || 'CHART') + '.png';
    }

    // --- Saving ---------------------------------------------------------------------------

    function saveBlob(blob, name) {
        const href = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = href;
        link.download = name;
        document.body.appendChild(link);
        link.click();
        link.remove();
        setTimeout(() => URL.revokeObjectURL(href), 10000);
        toast('Saved ' + name + ' (' + Math.round(blob.size / 1024) + ' KB)');
    }

    /** Last resort: the page's own fetch, which CORS may well refuse. */
    function pageFetch(url, name) {
        fetch(url)
            .then((response) => {
                if (!response.ok) throw new Error('HTTP ' + response.status);
                return response.blob();
            })
            .then((blob) => saveBlob(blob, name))
            .catch((error) => {
                console.warn('[chart downloader] falling back to a new tab:', error);
                toast('Could not save directly — opening the chart in a tab, press ⌘S there.');
                window.open(url, '_blank');
            });
    }

    function download(url, name) {
        const path = destination(name);

        if (path !== name) {
            // Only GM_download can put a file in a folder; an <a download> can name a file and
            // nothing more.
            if (typeof GM_download === 'function') {
                GM_download({
                    url,
                    name: path,
                    saveAs: false,
                    onload: () => toast('Saved ' + path),
                    onerror: (error) => {
                        const reason = (error && (error.error || error.details)) || 'failed';
                        toast('Could not save to ' + path + ' (' + reason + ')');
                        console.warn('[chart downloader]', error, url);
                    }
                });
                return;
            }
            toast('Folders need GM_download; saving as ' + name + ' instead.');
        }

        if (typeof GM_xmlhttpRequest === 'function') {
            // Preferred over GM_download because it reports a size and cannot silently land a
            // zero-byte file when the signed URL has expired.
            GM_xmlhttpRequest({
                method: 'GET',
                url,
                responseType: 'blob',
                onload: (response) => {
                    if (response.status >= 200 && response.status < 300 && response.response) {
                        saveBlob(response.response, name);
                    } else {
                        toast('Blob store said HTTP ' + response.status + '; trying another way.');
                        pageFetch(url, name);
                    }
                },
                onerror: () => pageFetch(url, name)
            });
            return;
        }
        if (typeof GM_download === 'function') {
            GM_download({ url, name, saveAs: false,
                          onload: () => toast('Saved ' + name),
                          onerror: () => pageFetch(url, name) });
            return;
        }
        pageFetch(url, name);
    }

    // --- The naming box -------------------------------------------------------------------

    let box = null;

    function styled(tag, css, text) {
        const element = document.createElement(tag);
        element.style.cssText = css;
        if (text !== undefined) element.textContent = text;
        return element;
    }

    function buildBox() {
        const backdrop = styled('div', [
            'position:fixed', 'inset:0', 'z-index:2147483646',
            'background:rgba(0,0,0,.5)', 'display:none',
            'align-items:center', 'justify-content:center',
            'font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif'
        ].join(';'));

        const card = styled('div', [
            'min-width:420px', 'padding:18px 18px 14px', 'border-radius:12px',
            'background:#0d1524', 'color:#e8eef8',
            'box-shadow:0 18px 50px rgba(0,0,0,.6)', 'border:1px solid rgba(255,255,255,.08)'
        ].join(';'));

        const heading = styled('div', 'font-size:14px;font-weight:600;margin-bottom:12px;',
                               'Save chart');

        const row = styled('div', 'display:flex;align-items:center;gap:6px;');
        const field = document.createElement('input');
        field.type = 'text';
        field.placeholder = 'File name';
        field.spellcheck = false;
        field.style.cssText = [
            'flex:1', 'padding:7px 9px', 'border-radius:7px',
            'border:1px solid rgba(255,255,255,.16)', 'background:#050a14',
            'color:#e8eef8', 'font:13px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace',
            'outline:none', 'text-transform:uppercase'
        ].join(';');
        field.addEventListener('focus', () => {
            field.style.borderColor = ACCENT;
        });
        field.addEventListener('blur', () => {
            field.style.borderColor = 'rgba(255,255,255,.16)';
        });
        const suffix = styled('span', 'opacity:.55;font:12px/1 ui-monospace,Menlo,monospace;', '.png');
        row.appendChild(field);
        row.appendChild(suffix);

        const caption = styled('div', 'margin-top:9px;display:flex;align-items:center;gap:8px;'
                                    + 'font-size:11.5px;opacity:.65;');
        const detail = styled('span', '', '');
        const going = styled('span', 'font:11.5px/1.5 ui-monospace,Menlo,monospace;opacity:.85;', '');
        const toggle = styled('button', [
            'padding:2px 8px', 'border-radius:999px', 'cursor:pointer',
            'border:1px solid rgba(255,255,255,.18)', 'background:transparent',
            'color:inherit', 'font:11.5px/1.5 inherit'
        ].join(';'), '');
        caption.appendChild(detail);
        caption.appendChild(toggle);
        caption.appendChild(going);

        const buttons = styled('div', 'margin-top:14px;display:flex;gap:8px;justify-content:flex-end;');
        const cancel = styled('button', [
            'padding:6px 12px', 'border-radius:7px', 'cursor:pointer',
            'border:1px solid rgba(255,255,255,.18)', 'background:transparent',
            'color:#e8eef8', 'font:13px/1 inherit'
        ].join(';'), 'Cancel');
        const confirm = styled('button', [
            'padding:6px 14px', 'border-radius:7px', 'cursor:pointer', 'border:0',
            'background:' + ACCENT, 'color:#fff', 'font:13px/1 inherit', 'font-weight:600'
        ].join(';'), 'Save');
        buttons.appendChild(cancel);
        buttons.appendChild(confirm);

        card.appendChild(heading);
        card.appendChild(row);
        card.appendChild(caption);
        card.appendChild(buttons);
        backdrop.appendChild(card);
        document.body.appendChild(backdrop);

        box = { backdrop, card, field, detail, toggle, going, chart: null, all: [] };

        field.addEventListener('input', () => {
            // text-transform is paint only: the value would still be whatever was typed, and
            // the value is the filename. Setting it moves the caret to the end, so put it back.
            const upper = field.value.toUpperCase();
            if (upper !== field.value) {
                const start = field.selectionStart;
                const end = field.selectionEnd;
                field.value = upper;
                if (field.setSelectionRange) field.setSelectionRange(start, end);
            }
            showDestination();
        });

        // The viewer has its own keyboard shortcuts, and typing a chart name should not set
        // any of them off.
        for (const type of ['keydown', 'keyup', 'keypress']) {
            card.addEventListener(type, (event) => event.stopPropagation());
        }

        field.addEventListener('keydown', (event) => {
            if (event.key === 'Enter') { event.preventDefault(); accept(); }
            if (event.key === 'Escape') { event.preventDefault(); close(); }
        });
        backdrop.addEventListener('click', (event) => {
            if (event.target === backdrop) close();
        });
        cancel.addEventListener('click', close);
        confirm.addEventListener('click', accept);
        toggle.addEventListener('click', () => {
            const other = variant(box.all, !box.chart.isDark);
            if (other) { box.chart = other; describe(); }
        });

        return box;
    }

    function showDestination() {
        box.going.textContent = '→ ' + destination(clean(box.field.value));
    }

    function describe() {
        box.detail.textContent = box.chart.size + ' · ' + (box.chart.isDark ? 'dark' : 'light');
        const other = variant(box.all, !box.chart.isDark);
        box.toggle.textContent = other ? 'use ' + (box.chart.isDark ? 'light' : 'dark') : '';
        box.toggle.style.display = other ? '' : 'none';
    }

    function open() {
        const all = candidates();
        if (all.length === 0) {
            toast('No chart open — open one, then try again.');
            return;
        }

        if (!box) buildBox();
        box.all = all;
        box.chart = variant(all, PREFER_DARK) || variant(all, !PREFER_DARK) || all[0];
        describe();

        box.field.value = guessStem().toUpperCase();
        showDestination();
        box.backdrop.style.display = 'flex';
        box.field.focus();
        box.field.select();
    }

    function close() {
        if (box) box.backdrop.style.display = 'none';
    }

    function accept() {
        const name = clean(box.field.value);
        const url = box.chart.url;
        const size = box.chart.size;
        close();
        toast('Fetching ' + size + '…');
        download(url, name);
    }

    // --- Triggers and feedback ------------------------------------------------------------

    let bubble = null;
    function toast(text) {
        if (!document.body) return;
        if (!bubble) {
            bubble = styled('div', [
                'position:fixed', 'left:50%', 'bottom:26px', 'transform:translateX(-50%)',
                'z-index:2147483647', 'padding:8px 14px', 'border-radius:999px',
                'background:rgba(8,16,32,.92)', 'color:#e8eef8',
                'font:13px/1.3 -apple-system,sans-serif',
                'box-shadow:0 6px 24px rgba(0,0,0,.45)', 'pointer-events:none',
                'transition:opacity .2s', 'opacity:0'
            ].join(';'));
            document.body.appendChild(bubble);
        }
        bubble.textContent = text;
        bubble.style.opacity = '1';
        clearTimeout(toast.timer);
        toast.timer = setTimeout(() => { bubble.style.opacity = '0'; }, 3200);
    }

    // Alt-click rather than plain click, so panning and zooming still behave.
    window.addEventListener('click', (event) => {
        if (!event.altKey) return;
        if (box && box.card.contains(event.target)) return;
        event.preventDefault();
        event.stopPropagation();
        open();
    }, true);

    // ⌥D for when the chart fills the window and there is nothing safe to click.
    window.addEventListener('keydown', (event) => {
        if (event.altKey && (event.key === 'd' || event.key === 'D' || event.code === 'KeyD')) {
            event.preventDefault();
            open();
        }
    }, true);

    const launcher = styled('button', [
        'position:fixed', 'right:16px', 'bottom:16px', 'z-index:2147483645',
        'padding:7px 12px', 'border:0', 'border-radius:8px', 'cursor:pointer',
        'background:' + ACCENT, 'color:#fff', 'font:13px/1 -apple-system,sans-serif',
        'box-shadow:0 4px 14px rgba(0,0,0,.4)'
    ].join(';'), '⤓ Chart');
    launcher.addEventListener('click', (event) => {
        event.preventDefault();
        event.stopPropagation();
        open();
    });
    document.body.appendChild(launcher);
})();
