// Paste into the browser console with a chart open on planner.flightsimulator.com. It reports
// how the viewer holds its chart — one big PNG in an <img>, one painted into a <canvas>, or a
// grid of tiles — which is what the downloader otherwise has to guess at.
//
// Reload the chart first. Resource timing keeps a limited buffer, so on a page that has been
// open a while the chart's own request may already have fallen out of it.
//
// The report comes back three ways, so none of it has to be transcribed: printed as plain text,
// put on the clipboard, and saved to your Downloads folder as planner-probe.txt.

(() => {
    const lines = [];
    const say = (text = '') => lines.push(text);
    const short = (url) => (url || '').replace(/^https?:\/\//, '').slice(0, 120);

    /** Fixed-width columns, so the report stays readable as plain text. */
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

    say('=== planner probe ===');
    say('page         ' + location.href);
    say('contentType  ' + document.contentType);
    say('viewport     ' + innerWidth + '×' + innerHeight + ' @' + devicePixelRatio + 'x');
    say();

    const images = [...document.images]
        .filter((image) => image.naturalWidth >= 200)
        .sort((a, b) => b.naturalWidth * b.naturalHeight - a.naturalWidth * a.naturalHeight);
    say('<img> over 200px: ' + images.length);
    table(['pixels', 'shown', 'src'], images.slice(0, 8).map((image) => [
        image.naturalWidth + '×' + image.naturalHeight,
        Math.round(image.width) + '×' + Math.round(image.height),
        short(image.currentSrc || image.src)
    ]));
    say();

    const canvases = [...document.querySelectorAll('canvas')];
    say('<canvas>: ' + canvases.length);
    table(['pixels', 'css', 'class'], canvases.slice(0, 6).map((canvas) => [
        canvas.width + '×' + canvas.height,
        Math.round(canvas.clientWidth) + '×' + Math.round(canvas.clientHeight),
        String(canvas.className || '').slice(0, 50)
    ]));
    say();

    const resources = performance.getEntriesByType('resource')
        .filter((entry) => entry.initiatorType === 'img'
            || /\.(png|jpe?g|webp)(\?|#|$)/i.test(entry.name))
        .map((entry) => ({
            kb: Math.round((entry.transferSize || entry.encodedBodySize || 0) / 1024),
            type: entry.initiatorType,
            url: entry.name
        }))
        .sort((a, b) => b.kb - a.kb);
    const small = resources.filter((entry) => entry.kb > 0 && entry.kb < 80);
    say('image requests: ' + resources.length + ', under 80 KB: ' + small.length
        + (resources.length >= 12 && small.length === resources.length ? '  (LOOKS TILED)' : ''));
    table(['KB', 'from', 'url'], resources.slice(0, 12)
        .map((entry) => [entry.kb, entry.type || '?', short(entry.url)]));
    say();

    const headings = [...document.querySelectorAll('h1, h2, h3, [class*="title" i], [class*="name" i]')]
        .map((element) => (element.textContent || '').trim())
        .filter((text) => text.length > 3 && text.length < 80);
    say('headings a filename would come from:');
    headings.slice(0, 10).forEach((text) => say('  ' + JSON.stringify(text)));
    say('=== end ===');

    const report = lines.join('\n');
    console.log(report);

    // `copy` exists only in the console, which is where this is meant to be pasted.
    if (typeof copy === 'function') {
        copy(report);
        console.log('%cCopied to the clipboard.', 'color:#6c6');
    }

    try {
        const blob = new Blob([report], { type: 'text/plain' });
        const href = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = href;
        link.download = 'planner-probe.txt';
        document.body.appendChild(link);
        link.click();
        link.remove();
        setTimeout(() => URL.revokeObjectURL(href), 10000);
        console.log('%cSaved to Downloads as planner-probe.txt', 'color:#6c6');
    } catch (error) {
        console.warn('Could not save the file; the text above is the whole report.', error);
    }
})();
