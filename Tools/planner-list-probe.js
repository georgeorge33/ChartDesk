// Paste into the browser console on an airport page at planner.flightsimulator.com, with the
// airport's chart list showing. It reports what a sweep — one pass that opens every chart for
// an airport and saves each one — has to know before it can drive the viewer itself.
//
// Four things, none of which a still page shows on its own:
//
//   the container the chart rows live in, so a sweep can enumerate them;
//   the class a row gains when it is selected, so a sweep knows a click landed;
//   how a row's text is split across its children, so a name comes out as the row reads
//     rather than as every child run together;
//   whether the category tabs swap the list or filter it, which decides whether a sweep is
//     one loop or two.
//
//   1. Run it.
//   2. Open three or four charts, then switch category tabs and open one more.
//   3. It reports after 60 seconds, or right away if you call __plannerList.report().
//
// Printed, put on the clipboard, and saved to Downloads as planner-list-probe.txt.

(() => {
    // From planner-chart-download.user.js, so the probe agrees with the downloader about what
    // counts as a chart.
    const CHART_WORDS = /\b(RWY|ILS|LOC|LLZ|RNAV|RNP|GLS|VOR|NDB|TACAN|SID|STAR|DEPARTURE|ARRIVAL|APPROACH|APCH|VISUAL|DIAGRAM|TAXI|PARKING|GROUND|APRON|MINIMA|BRIEFING|AFC|AGC|APC|ADC|AOI|LVC|IAC|VAC|MVC|10-9)\b/i;
    const CHART_PATH = /blob\.core\.windows\.net\/charts\/chart-files\//i;

    const WATCH_MS = 60000;
    const started = performance.now();
    const since = () => (Math.round(performance.now() - started) / 1000).toFixed(1) + 's';

    const lines = [];
    const say = (text = '') => lines.push(text);
    const short = (url) => (url || '').replace(/^https?:\/\//, '').slice(0, 96);
    const textOf = (element) => (element.textContent || '').replace(/\s+/g, ' ').trim();
    const classesOf = (element) =>
        String((element && element.className) || '').split(/\s+/).filter(Boolean);

    const table = (headers, rows) => {
        if (!rows.length) { say('  (none)'); return; }
        const widths = headers.map((header, column) =>
            Math.max(header.length, ...rows.map((row) => String(row[column] ?? '').length)));
        const line = (cells) => '  ' + cells
            .map((cell, column) => String(cell ?? '').padEnd(widths[column])).join('  ').trimEnd();
        say(line(headers));
        say('  ' + widths.map((width) => '-'.repeat(width)).join('  '));
        rows.forEach((row) => say(line(row)));
    };

    function describe(element) {
        if (!element || !element.tagName) return '(none)';
        const classes = classesOf(element);
        const role = element.getAttribute && element.getAttribute('role');
        return element.tagName.toLowerCase()
            + (element.id ? '#' + element.id : '')
            + (classes.length ? '.' + classes.slice(0, 4).join('.') : '')
            + (role ? '[role=' + role + ']' : '');
    }

    function path(element, depth = 4) {
        const parts = [];
        for (let node = element; node && node !== document.body && parts.length < depth;
             node = node.parentElement) {
            parts.unshift(describe(node));
        }
        return parts.join(' > ');
    }

    // --- The rows -----------------------------------------------------------------------------

    /** Buttons whose text names a chart. Category tabs match too; grouping tells them apart. */
    function chartButtons() {
        return [...document.querySelectorAll('button')].filter((button) => {
            const text = textOf(button);
            return text.length >= 3 && text.length <= 140 && CHART_WORDS.test(text);
        });
    }

    /** Those buttons gathered by parent, which is what distinguishes a tab strip from a list. */
    function groups() {
        const byParent = new Map();
        for (const button of chartButtons()) {
            const parent = button.parentElement;
            if (!parent) continue;
            if (!byParent.has(parent)) byParent.set(parent, []);
            byParent.get(parent).push(button);
        }
        return [...byParent.entries()].sort((a, b) => b[1].length - a[1].length);
    }

    /**
     * A row's text child by child. textContent runs them together — "SIDPT (5)AMEEE 1 RNAV" is
     * three separate pieces — and a name wants one of them, not the concatenation.
     */
    function pieces(row) {
        return [...row.querySelectorAll('*')]
            .filter((element) => element.children.length === 0 && textOf(element))
            .map((element) => [describe(element).slice(0, 52), JSON.stringify(textOf(element))]);
    }

    /** A sweep has to scroll a list that only renders what is on screen. */
    function scrolling(element) {
        for (let node = element; node && node !== document.body; node = node.parentElement) {
            if (node.scrollHeight > node.clientHeight + 8) {
                return describe(node) + '  ' + node.clientHeight + ' of ' + node.scrollHeight + 'px';
            }
        }
        return '(nothing scrolls — the whole list is in the DOM)';
    }

    // --- Watching -------------------------------------------------------------------------------

    const nodeIds = new WeakMap();
    let nextId = 1;
    const idOf = (node) => {
        if (!nodeIds.has(node)) nodeIds.set(node, 'img#' + nextId++);
        return nodeIds.get(node);
    };

    const clicks = [];
    const swaps = [];
    const classChanges = [];
    const snapshots = [];

    /** What the list holds now, taken after a click so a tab switch can be seen to change it. */
    function snapshot(label) {
        const found = groups();
        const biggest = found.length ? found[0] : null;
        snapshots.push([
            since(), label,
            biggest ? biggest[1].length : 0,
            biggest ? JSON.stringify(textOf(biggest[1][0]).slice(0, 44)) : '—'
        ]);
    }

    addEventListener('click', (event) => {
        const target = event.target;
        // The row, not whatever child took the click, is what a name would come from.
        const row = target.closest ? target.closest('button') : null;
        clicks.push([since(), describe(target).slice(0, 44),
                     JSON.stringify(textOf(row || target).slice(0, 52))]);
        setTimeout(() => snapshot('after ' + JSON.stringify(textOf(row || target).slice(0, 28))), 700);
    }, true);

    const known = new Map();
    for (const image of document.images) {
        const url = image.currentSrc || image.src || '';
        if (CHART_PATH.test(url)) known.set(idOf(image), url);
    }

    function noteImage(image) {
        const url = image.currentSrc || image.src || '';
        if (!CHART_PATH.test(url)) return;
        const id = idOf(image);
        if (known.get(id) === url) return;
        const before = known.get(id);
        known.set(id, url);

        // Bound to this entry, not to whatever was pushed last: two images change per chart and
        // the later load would otherwise overwrite the earlier one's row.
        const entry = {
            at: since(),
            afterClick: clicks.length ? clicks[clicks.length - 1][0] : '—',
            node: id,
            fresh: before === undefined,
            dark: /-dark\.png/i.test(url),
            to: short(url),
            loadedAt: '',
            pixels: ''
        };
        swaps.push(entry);

        const done = () => {
            entry.loadedAt = since();
            entry.pixels = image.naturalWidth + '×' + image.naturalHeight;
        };
        if (image.complete && image.naturalWidth) done();
        else image.addEventListener('load', done, { once: true });
    }

    const observer = new MutationObserver((records) => {
        for (const record of records) {
            if (record.type === 'attributes' && record.target.tagName === 'IMG') {
                noteImage(record.target);
            }
            if (record.type === 'attributes' && record.attributeName === 'class') {
                const element = record.target;
                const text = textOf(element);
                if (!text || text.length > 140 || !CHART_WORDS.test(text)) continue;
                // The difference is the interesting part; the full class list is mostly layout
                // and would only be truncated away again.
                const was = new Set(String(record.oldValue || '').split(/\s+/).filter(Boolean));
                const now = new Set(classesOf(element));
                const gained = [...now].filter((name) => !was.has(name));
                const lost = [...was].filter((name) => !now.has(name));
                if (!gained.length && !lost.length) continue;
                classChanges.push([since(), JSON.stringify(text.slice(0, 30)),
                                   element.tagName.toLowerCase(),
                                   gained.join(' ') || '—', lost.join(' ') || '—']);
            }
            for (const added of record.addedNodes || []) {
                if (added.tagName === 'IMG') noteImage(added);
                else if (added.querySelectorAll) [...added.querySelectorAll('img')].forEach(noteImage);
            }
        }
    });
    observer.observe(document.documentElement, {
        subtree: true, childList: true,
        attributes: true, attributeOldValue: true, attributeFilter: ['src', 'class']
    });

    // --- The report -------------------------------------------------------------------------------

    let reported = false;
    function report() {
        if (reported) return;
        reported = true;
        observer.disconnect();

        say('=== planner list probe (sweep) ===');
        say('page      ' + location.href);
        say('watched   ' + since());
        say();

        const found = groups();
        say('groups of sibling buttons naming a chart: ' + found.length);
        found.slice(0, 4).forEach(([parent, buttons], index) => {
            say();
            say('  [' + (index + 1) + '] ' + buttons.length + ' buttons under ' + describe(parent));
            say('      path     ' + path(parent, 5));
            say('      scroll   ' + scrolling(parent));
            say('      button   ' + describe(buttons[0]));
            say('      texts:');
            buttons.slice(0, 14).forEach((button) =>
                say('        ' + JSON.stringify(textOf(button).slice(0, 70))));
            if (buttons.length > 14) say('        … and ' + (buttons.length - 14) + ' more');
        });
        say();

        // The largest group is the chart list if anything is; its first row shows how a name
        // is put together.
        const rows = found.length ? found[0][1] : [];
        if (rows.length) {
            say('the first row, child by child:');
            table(['element', 'text'], pieces(rows[0]));
            say();
            say('  outerHTML (first 1200 chars):');
            say('  ' + rows[0].outerHTML.slice(0, 1200).replace(/\n\s*/g, ' '));
            say();
        }

        say('list contents after each click (does a tab swap the list?):');
        table(['at', 'after', 'rows', 'first row'], snapshots.slice(0, 16));
        say();

        say('clicks you made: ' + clicks.length);
        table(['at', 'target', 'row text'], clicks.slice(0, 16));
        say();

        say('chart images that changed: ' + swaps.length);
        table(['at', 'after click', 'node', 'reused', 'variant', 'loaded', 'pixels', 'url'],
              swaps.slice(0, 16).map((entry) => [
                  entry.at, entry.afterClick, entry.node,
                  entry.fresh ? 'new node' : 'same node',
                  entry.dark ? 'dark' : 'light',
                  entry.loadedAt || '(never)', entry.pixels || '?', entry.to
              ]));
        say();

        say('class changes on chart rows — the selected state: ' + classChanges.length);
        table(['at', 'row', 'tag', 'gained', 'lost'], classChanges.slice(0, 20));
        say('=== end ===');

        const text = lines.join('\n');
        console.log(text);

        if (typeof copy === 'function') {
            copy(text);
            console.log('%cCopied to the clipboard.', 'color:#6c6');
        }
        try {
            const blob = new Blob([text], { type: 'text/plain' });
            const href = URL.createObjectURL(blob);
            const link = document.createElement('a');
            link.href = href;
            link.download = 'planner-list-probe.txt';
            document.body.appendChild(link);
            link.click();
            link.remove();
            setTimeout(() => URL.revokeObjectURL(href), 10000);
            console.log('%cSaved to Downloads as planner-list-probe.txt', 'color:#6c6');
        } catch (error) {
            console.warn('Could not save the file; the text above is the whole report.', error);
        }
        return text;
    }

    window.__plannerList = { report };
    snapshot('(start)');
    setTimeout(report, WATCH_MS);
    console.log('%cWatching for ' + (WATCH_MS / 1000) + 's — open a few charts, then switch '
                + 'category tabs and open one more. __plannerList.report() finishes early.',
                'color:#6cf');
})();
