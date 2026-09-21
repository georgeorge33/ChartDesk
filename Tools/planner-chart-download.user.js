// ==UserScript==
// @name         MSFS Planner chart downloader
// @namespace    local.chartdesk
// @version      4.3
// @description  Alt-click a chart on planner.flightsimulator.com to save it, or sweep every chart an airport has
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
//
// ⌥S sweeps instead: it walks the category tabs, opens every chart the airport has, and files
// each one without asking. There is no index to read — the planner has no endpoint that lists
// an airport's charts, so the only way to learn a chart's URL is to make the viewer open it —
// which is why a sweep drives the interface rather than fetching a manifest.
//
// The list is virtualised: rows are absolutely positioned inside a spacer and only those near
// the viewport exist, so a sweep scrolls and collects as it goes, keyed by each row's
// data-index. It clicks the button behind `img[alt="Preview chart"]` and waits for the image
// to finish loading rather than for its src to change, because the src changes in about two
// hundred milliseconds and the plate itself can take another second and a half.

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
                              'ROUTE', 'WIND', 'FUEL', 'TIME', 'DATE', 'NAME', 'TYPE',
                              // Four letters, and all over a chart list. Without these a
                              // sweep could file a whole airport's charts under RNAV.
                              'RNAV', 'STAR', 'MISC', 'TAXI', 'APCH', 'AREA', 'SIDS',
                              // The provider control, and the map's own attribution line:
                              // "Powered By MapLibre, Data © OpenStreetMap, LIDO".
                              'LIDO', 'DATA', 'JEPP']);

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

    /** The airport on show, which is the folder each of its charts belongs in. */
    function currentIcao() {
        const inputs = [...document.querySelectorAll('input')]
            // Not this script's own field: it still holds the last name typed, so a chart at
            // one airport would otherwise be offered the airport before it.
            .filter((input) => !(box && box.card.contains(input)))
            .map((input) => (input.value || '').trim().toUpperCase());
        for (const text of [...inputs, ...visibleText().map((entry) => entry.toUpperCase())]) {
            const codes = text.match(/\b[A-Z]{4}\b/g) || [];
            const code = codes.find((candidate) => !NOT_ICAO.has(candidate));
            if (code) return code;
        }
        return '';
    }

    /** A starting point only — you type over it. Empty when there is nothing worth offering. */
    function guessStem() {
        const named = visibleText().filter((text) => CHART_WORDS.test(text));
        // A chart's name mentions the procedure; a paragraph about it does not read like one.
        named.sort((a, b) => a.length - b.length);
        return [currentIcao(), named[0] || ''].filter(Boolean)
            .join(' ').replace(/\s+/g, ' ').trim();
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
        return fetch(url)
            .then((response) => {
                if (!response.ok) throw new Error('HTTP ' + response.status);
                return response.blob();
            })
            .then((blob) => { saveBlob(blob, name); return true; })
            .catch((error) => {
                console.warn('[chart downloader] falling back to a new tab:', error);
                toast('Could not save directly — opening the chart in a tab, press ⌘S there.');
                window.open(url, '_blank');
                return false;
            });
    }

    /**
     * Resolves true when the file has landed, false when it has not. A sweep waits on this so
     * that thirty charts go out one at a time rather than thirty at once, and so a chart that
     * fails is counted rather than lost quietly. It reports failure rather than rejecting,
     * because the single-chart path does not await it and an unhandled rejection would be the
     * only trace of a problem that has already been shown in a toast.
     */
    function download(url, name) {
        const path = destination(name);

        return new Promise((resolve) => {
            if (path !== name) {
                // Only GM_download can put a file in a folder; an <a download> can name a file
                // and nothing more.
                if (typeof GM_download === 'function') {
                    GM_download({
                        url,
                        name: path,
                        saveAs: false,
                        onload: () => { toast('Saved ' + path); resolve(true); },
                        onerror: (error) => {
                            const reason = (error && (error.error || error.details)) || 'failed';
                            toast('Could not save to ' + path + ' (' + reason + ')');
                            console.warn('[chart downloader]', error, url);
                            resolve(false);
                        }
                    });
                    return;
                }
                toast('Folders need GM_download; saving as ' + name + ' instead.');
            }

            if (typeof GM_xmlhttpRequest === 'function') {
                // Preferred over GM_download because it reports a size and cannot silently land
                // a zero-byte file when the signed URL has expired.
                GM_xmlhttpRequest({
                    method: 'GET',
                    url,
                    responseType: 'blob',
                    onload: (response) => {
                        if (response.status >= 200 && response.status < 300 && response.response) {
                            saveBlob(response.response, name);
                            resolve(true);
                        } else {
                            toast('Blob store said HTTP ' + response.status + '; trying another way.');
                            resolve(pageFetch(url, name));
                        }
                    },
                    onerror: () => resolve(pageFetch(url, name))
                });
                return;
            }
            if (typeof GM_download === 'function') {
                GM_download({ url, name, saveAs: false,
                              onload: () => { toast('Saved ' + name); resolve(true); },
                              onerror: () => resolve(pageFetch(url, name)) });
                return;
            }
            resolve(pageFetch(url, name));
        });
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

    // --- Sweeping an airport ----------------------------------------------------------------

    /** The control that opens a chart. Its alt is the planner's, not ours, and it is stable. */
    const OPEN_BUTTON = 'img[alt="Preview chart"]';
    /** The type down the left edge of a row, written vertically: IAC, VAC, SID, SIDPT, AGC. */
    const BADGE = '.vertical-writing-lr';
    const TITLE = 'div.grow.cursor-default';

    /** Long enough for a slow plate, short enough that one bad row does not stall a sweep. */
    const CHART_TIMEOUT_MS = 20000;

    /** A breath between downloads. The blob store would not notice; this is manners. */
    const GAP_MS = 400;

    // Where a plate serves both an ILS and the localiser beside it, the library holds it under
    // the ILS, so the order here is the order of preference.
    const CHIP_ORDER = ['ILS', 'LOC', 'LDA', 'GLS', 'RNAV', 'RNP', 'VOR', 'NDB', 'TACAN'];

    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    function textIn(root, selector) {
        const found = root.querySelector(selector);
        return found ? (found.textContent || '').replace(/\s+/g, ' ').trim() : '';
    }

    /** What a tab is called: one word, as DEPARTURE and MISC are. */
    const TAB_LABEL = /^[A-Za-z]{3,12}$/;

    /**
     * The Chart Provider control, which is two buttons of the same shape as a tab and labelled
     * in four letters and three. A sweep must not mistake either for a category: clicking FAA
     * halfway through would finish the airport in the other provider's charts, and the library
     * holds one or the other, never a mixture.
     */
    const SOURCE_LABELS = /^(LIDO|FAA|JEPP|JEPPESEN|NAVBLUE)$/i;

    function providerButtons() {
        return [...document.querySelectorAll('button[aria-pressed]')]
            .filter((button) => SOURCE_LABELS.test((button.textContent || '').trim()));
    }

    /**
     * The category strip: DEPARTURE, ARRIVAL, APPROACH, AIRPORT, MISC. Every one of them
     * carries the underline that marks the selected tab, which is what tells them apart from
     * the runway filter alongside — the same size and shape, but with neither underline nor
     * text of its own.
     *
     * The label has to read like a label as well. An element wrapping the whole strip answers
     * for the text of everything inside it — KDCADEPARTUREARRIVALAPPROACHAIRPORTMISC — and if
     * one of those ever carries the underline class it would otherwise be taken for a tab,
     * put that run of letters in front of every chart as it was swept, and be clicked as
     * though it were a tab of its own.
     */
    function categoryTabs() {
        return [...document.querySelectorAll('button')].filter((button) => {
            const label = (button.textContent || '').trim();
            return /border-b-(msfs|transparent)\b/.test(String(button.className || ''))
                && TAB_LABEL.test(label)
                && !SOURCE_LABELS.test(label);
        });
    }

    /**
     * Puts the viewer on Lido before a sweep begins, because the library holds Lido charts and
     * a run that started on FAA would fill an airport with the other set under names this does
     * not know how to make — the badges it reads for SID, STAR and the airport codes are Lido's.
     *
     * A missing control is not a failure. FAA charts exist for American airports and nowhere
     * else, so at most of the world there is nothing to choose and nothing to put right.
     */
    async function useLido() {
        const buttons = providerButtons();
        if (!buttons.length) return true;

        const lido = buttons.find((button) => /^LIDO$/i.test((button.textContent || '').trim()));
        if (!lido) return true;
        if (lido.getAttribute('aria-pressed') === 'true') return true;

        toast('Switching to Lido charts…');
        lido.click();
        // The list is rebuilt from the other provider's charts, which takes a moment.
        for (let waited = 0; waited < 5000; waited += 150) {
            await wait(150);
            if (lido.getAttribute('aria-pressed') === 'true') { await wait(400); return true; }
        }
        return false;
    }

    const isSelected = (tab) => /border-b-msfs\b/.test(String(tab.className || ''));

    /**
     * The chart rows. Recognising them by the button that opens a chart rather than by a class
     * keeps this working when the styling moves, and it leaves out the "For all runways"
     * headings, which carry no data-index at all.
     */
    function chartRows() {
        return [...document.querySelectorAll('[data-index]')]
            .filter((row) => row.querySelector(OPEN_BUTTON));
    }

    /** The panel a list scrolls in. The wrapper just above the rows has no height of its own. */
    function listScroller(row) {
        for (let node = row; node && node !== document.body; node = node.parentElement) {
            if (node.clientHeight > 40 && node.scrollHeight > node.clientHeight + 20) return node;
        }
        return null;
    }

    function chipRank(chip) {
        const place = CHIP_ORDER.indexOf(chip.split(/\s+/)[0].toUpperCase());
        return place === -1 ? CHIP_ORDER.length : place;
    }

    // Types whose designator says nothing about what kind of chart it is. AMEEE1 is a SID and
    // CAPSS4 is a STAR, and both are five letters and a digit — so the library's parser has no
    // way to tell a departure from an arrival unless the name says. Left to itself it files
    // every one of them under REF, or worse: SKILS5 contains ILS, and a STAR that matches on a
    // substring lands among the approaches looking entirely plausible.
    //
    // Carrying the badge also separates a procedure from its own text page, SIDPT against SID,
    // which is what stopped the two overwriting each other before.
    const TYPED_BADGES = /^(SID|SIDPT|STAR|STARPT|EOSID)$/i;

    const withType = (name, badge) =>
        (TYPED_BADGES.test(badge || '') ? name + ' ' + badge.toUpperCase() : name);

    /**
     * What a row should be called, in the shape the library already uses: AGC, ILS 01, RNAV 15.
     *
     * A chip is the planner saying how the plate is flown, and it reads exactly as the library
     * names it. A chip of NONE is the viewer admitting it has no category for the procedure —
     * an LDA, say — which is a statement rather than a name, so it is dropped and the title
     * stands instead. An airport chart carries no chip but ends its title with its own code,
     * and that code is the name. A visual approach ends with neither, and one airport can hold
     * two of them, so there nothing shorter than the title will do.
     */
    function nameFrom(badge, title, chips) {
        const usable = chips
            .map((chip) => String(chip).replace(/\s+/g, ' ').trim())
            .filter((chip) => chip && !/^NONE\b/i.test(chip))
            .sort((a, b) => chipRank(a) - chipRank(b));
        if (usable.length) return withType(usable[0], badge);

        if (badge && title.toUpperCase().endsWith(badge.toUpperCase())) {
            return withType(badge, badge);
        }
        return withType(title || badge, badge);
    }

    /** The rule above, over a row as the page holds it. */
    function rowName(row) {
        return nameFrom(
            textIn(row, BADGE),
            textIn(row, TITLE),
            [...row.querySelectorAll('button')].map((button) => button.textContent || '')
        );
    }

    /**
     * Every row of the list now showing, as index → name. The list is virtualised, so only the
     * rows near the viewport exist; this walks the panel a little under a screen at a time and
     * gathers what appears, with data-index saying whether a row has been counted already.
     */
    async function collectRows() {
        const found = new Map();
        const harvest = () => {
            for (const row of chartRows()) {
                const index = Number(row.getAttribute('data-index'));
                if (!found.has(index)) found.set(index, rowName(row));
            }
        };
        harvest();

        const scroller = chartRows().length ? listScroller(chartRows()[0]) : null;
        if (scroller) {
            const step = Math.max(60, Math.floor(scroller.clientHeight * 0.6));
            scroller.scrollTop = 0;
            await wait(220);
            harvest();
            for (let guard = 0; guard < 300; guard += 1) {
                if (scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2) break;
                const before = scroller.scrollTop;
                scroller.scrollTop = before + step;
                await wait(160);
                harvest();
                if (scroller.scrollTop === before) break;   // nothing moved; stop rather than spin
            }
            scroller.scrollTop = 0;
            await wait(200);
        }
        return [...found.entries()].sort((a, b) => a[0] - b[0]);
    }

    /** Opens one row, scrolling down to it when the list has not built that row yet. */
    async function openRow(index) {
        for (let attempt = 0; attempt < 40; attempt += 1) {
            const row = chartRows().find((candidate) =>
                Number(candidate.getAttribute('data-index')) === index);
            if (row) {
                const image = row.querySelector(OPEN_BUTTON);
                const button = image.closest('button') || image;
                button.scrollIntoView({ block: 'center' });
                await wait(60);
                button.click();
                return true;
            }

            const scroller = chartRows().length ? listScroller(chartRows()[0]) : null;
            if (!scroller) return false;
            const before = scroller.scrollTop;
            scroller.scrollTop = before + Math.max(60, Math.floor(scroller.clientHeight * 0.6));
            await wait(140);
            // At the bottom and still not found: begin again from the top rather than press
            // against the end of the list for every remaining attempt.
            if (scroller.scrollTop === before) scroller.scrollTop = 0;
        }
        return false;
    }

    /**
     * The plate that appears after a click, once it has actually loaded. Waiting on the load
     * rather than on the src matters: the src changes within a couple of hundred milliseconds
     * and the image can take another second and a half, so a URL read in between is still the
     * chart the viewer has just left.
     */
    async function waitForChart(already) {
        for (let waited = 0; waited < CHART_TIMEOUT_MS; waited += 120) {
            const loaded = candidates().filter((entry) => entry.pixels > 0);
            const wanted = variant(loaded, PREFER_DARK)
                || variant(loaded, !PREFER_DARK)
                || loaded[0];
            if (wanted && !already.has(wanted.url)) return wanted;
            await wait(120);
        }
        return null;
    }

    /**
     * One question for the whole sweep rather than one per chart. Everything lands in this
     * folder, and a wrong code here would file an airport's worth of charts under it.
     */
    function askIcao(suggested) {
        return new Promise((resolve) => {
            const backdrop = styled('div', [
                'position:fixed', 'inset:0', 'z-index:2147483646',
                'background:rgba(0,0,0,.5)', 'display:flex',
                'align-items:center', 'justify-content:center',
                'font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif'
            ].join(';'));
            const card = styled('div', [
                'min-width:340px', 'padding:18px 18px 14px', 'border-radius:12px',
                'background:#0d1524', 'color:#e8eef8',
                'box-shadow:0 18px 50px rgba(0,0,0,.6)', 'border:1px solid rgba(255,255,255,.08)'
            ].join(';'));
            const heading = styled('div', 'font-size:14px;font-weight:600;', 'Sweep every chart');
            const caption = styled('div', 'font-size:11.5px;opacity:.65;margin:4px 0 12px;',
                                   'Every chart this airport has, filed under this code. '
                                   + 'Escape stops it part way.');

            const field = document.createElement('input');
            field.type = 'text';
            field.value = suggested || '';
            field.placeholder = 'ICAO';
            field.spellcheck = false;
            field.style.cssText = [
                'width:100%', 'box-sizing:border-box', 'padding:7px 9px', 'border-radius:7px',
                'border:1px solid rgba(255,255,255,.16)', 'background:#050a14', 'color:#e8eef8',
                'font:13px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace',
                'outline:none', 'text-transform:uppercase'
            ].join(';');

            const buttons = styled('div',
                'margin-top:14px;display:flex;gap:8px;justify-content:flex-end;');
            const cancel = styled('button', [
                'padding:6px 12px', 'border-radius:7px', 'cursor:pointer',
                'border:1px solid rgba(255,255,255,.18)', 'background:transparent',
                'color:#e8eef8', 'font:13px/1 inherit'
            ].join(';'), 'Cancel');
            const go = styled('button', [
                'padding:6px 14px', 'border-radius:7px', 'cursor:pointer', 'border:0',
                'background:' + ACCENT, 'color:#fff', 'font:13px/1 inherit', 'font-weight:600'
            ].join(';'), 'Sweep');

            buttons.appendChild(cancel);
            buttons.appendChild(go);
            card.appendChild(heading);
            card.appendChild(caption);
            card.appendChild(field);
            card.appendChild(buttons);
            backdrop.appendChild(card);

            const finish = (value) => { backdrop.remove(); resolve(value); };
            // The viewer has its own shortcuts, and typing an airport code should not fire any.
            for (const type of ['keydown', 'keyup', 'keypress']) {
                card.addEventListener(type, (event) => event.stopPropagation());
            }
            field.addEventListener('keydown', (event) => {
                if (event.key === 'Enter') { event.preventDefault(); finish(field.value.trim().toUpperCase()); }
                if (event.key === 'Escape') { event.preventDefault(); finish(''); }
            });
            backdrop.addEventListener('click', (event) => {
                if (event.target === backdrop) finish('');
            });
            cancel.addEventListener('click', () => finish(''));
            go.addEventListener('click', () => finish(field.value.trim().toUpperCase()));

            document.body.appendChild(backdrop);
            field.focus();
            field.select();
        });
    }

    let sweeping = false;
    let stopped = false;

    async function sweep() {
        if (sweeping) { toast('Already sweeping — Escape stops it.'); return; }
        if (!chartRows().length) {
            toast('No chart list on screen — open an airport first.');
            return;
        }

        const icao = await askIcao(currentIcao());
        if (!icao) return;

        // Before anything is counted, because the provider decides what the whole sweep
        // collects and a half-Lido, half-FAA airport is worse than no airport at all.
        if (!(await useLido())) {
            toast('Could not switch to Lido — nothing swept.');
            return;
        }

        sweeping = true;
        stopped = false;
        // Whatever is already on screen: the first chart opened has to be told apart from it.
        const already = new Set(candidates().map((entry) => entry.url));
        // Names saved on this run. A chart reached twice is not worth fetching twice, and the
        // second attempt would be the expensive kind of nothing: its plate is already known,
        // so the wait for a new one runs its full length before giving up.
        const done = new Set();
        const missed = [];
        let saved = 0;

        try {
            // Labels rather than elements: clicking a tab re-renders the strip, so a button
            // held from before would be detached by the time its turn came and would take no
            // click at all.
            const categories = categoryTabs().map((tab) => (tab.textContent || '').trim());

            for (const category of categories) {
                if (stopped) break;
                const tab = categoryTabs().find((candidate) =>
                    (candidate.textContent || '').trim() === category);
                if (!tab) { missed.push(category + ' (tab went away)'); continue; }
                if (!isSelected(tab)) { tab.click(); await wait(600); }

                for (const [index, name] of await collectRows()) {
                    if (stopped) break;
                    if (done.has(name)) continue;
                    toast(category + ' · ' + name + ' · ' + saved + ' saved so far');

                    if (!(await openRow(index))) { missed.push(category + ' ' + name); continue; }
                    const chart = await waitForChart(already);
                    if (!chart) { missed.push(category + ' ' + name); continue; }

                    // Both variants of this chart, so the next wait cannot mistake either of
                    // them for the plate it is waiting on.
                    for (const entry of candidates()) already.add(entry.url);

                    if (await download(chart.url, clean(icao + ' ' + name))) {
                        saved += 1;
                        done.add(name);
                    } else {
                        missed.push(category + ' ' + name);
                    }
                    await wait(GAP_MS);
                }
            }
        } finally {
            sweeping = false;
            toast('Swept ' + icao + ': ' + saved + ' saved'
                  + (missed.length ? ', ' + missed.length + ' missed' : '')
                  + (stopped ? ' (stopped)' : ''));
            if (missed.length) console.warn('[chart downloader] missed:', missed);
        }
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

    // ⌥D for when the chart fills the window and there is nothing safe to click; ⌥S to take
    // the whole airport. Escape gives up a sweep that is already under way — after the chart
    // in hand, so a part-written file is never left behind.
    window.addEventListener('keydown', (event) => {
        if (event.altKey && (event.key === 'd' || event.key === 'D' || event.code === 'KeyD')) {
            event.preventDefault();
            open();
        }
        if (event.altKey && (event.key === 's' || event.key === 'S' || event.code === 'KeyS')) {
            event.preventDefault();
            sweep();
        }
        if (event.key === 'Escape' && sweeping) {
            stopped = true;
            toast('Stopping after this chart…');
        }
    }, true);

    function launcher(bottom, label, action) {
        const button = styled('button', [
            'position:fixed', 'right:16px', 'bottom:' + bottom + 'px', 'z-index:2147483645',
            'padding:7px 12px', 'border:0', 'border-radius:8px', 'cursor:pointer',
            'background:' + ACCENT, 'color:#fff', 'font:13px/1 -apple-system,sans-serif',
            'box-shadow:0 4px 14px rgba(0,0,0,.4)'
        ].join(';'), label);
        button.addEventListener('click', (event) => {
            event.preventDefault();
            event.stopPropagation();
            action();
        });
        document.body.appendChild(button);
        return button;
    }

    launcher(16, '⤓ Chart', open);
    launcher(54, '⤓ Airport', sweep);
})();
