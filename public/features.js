// features.js — client-side behaviour for the Section 4 UX features:
//   • top-nav symbol search with autocomplete + keyboard navigation
//   • watchlist add/remove buttons on /analysis/:symbol
//   • price alerts CRUD on /analysis/:symbol
//
// Loaded by views/layout.erb after app.js. Everything is guarded so it's safe
// on pages where the target elements don't exist.

(function () {
  'use strict';

  // ---- Symbol search ------------------------------------------------------
  function initSymbolSearch() {
    const input   = document.getElementById('symbol-search');
    const results = document.getElementById('symbol-search-results');
    if (!input || !results) return;

    let currentRequest = 0;
    let highlighted    = -1;
    let items          = [];

    function hide() { results.hidden = true; highlighted = -1; }
    function show() { if (items.length) results.hidden = false; }

    function render(list) {
      items = list || [];
      results.innerHTML = '';
      if (!items.length) { hide(); return; }
      items.forEach(function (row, idx) {
        const li = document.createElement('li');
        li.className = 'search-result-item';
        li.dataset.symbol = row.symbol;
        li.innerHTML =
          '<span class="sr-symbol">' + row.symbol + '</span>' +
          '<span class="sr-name">'   + row.name   + '</span>' +
          '<span class="sr-region">' + row.region + '</span>';
        li.addEventListener('mousedown', function (e) {
          // mousedown (not click) so the input's blur doesn't hide us first.
          e.preventDefault();
          go(row.symbol);
        });
        li.addEventListener('mouseenter', function () { setHighlight(idx); });
        results.appendChild(li);
      });
      show();
    }

    function setHighlight(idx) {
      const lis = results.querySelectorAll('.search-result-item');
      lis.forEach(function (el) { el.classList.remove('highlight'); });
      if (idx >= 0 && idx < lis.length) {
        lis[idx].classList.add('highlight');
        highlighted = idx;
      }
    }

    function go(symbol) {
      if (!symbol) return;
      window.location.href = '/analysis/' + encodeURIComponent(symbol);
    }

    function query(q) {
      const mine = ++currentRequest;
      const url  = '/api/symbols?q=' + encodeURIComponent(q) + '&limit=10';
      fetch(url)
        .then(function (r) { return r.json(); })
        .then(function (payload) {
          if (mine !== currentRequest) return; // stale response
          render(payload.results || []);
        })
        .catch(function () { /* swallow */ });
    }

    input.addEventListener('input', function () {
      const q = input.value.trim();
      if (!q) { hide(); return; }
      query(q);
    });

    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown')      { e.preventDefault(); setHighlight(Math.min(highlighted + 1, items.length - 1)); }
      else if (e.key === 'ArrowUp')   { e.preventDefault(); setHighlight(Math.max(highlighted - 1, 0)); }
      else if (e.key === 'Enter')     {
        e.preventDefault();
        const pick = highlighted >= 0 ? items[highlighted] : items[0];
        if (pick) go(pick.symbol);
      }
      else if (e.key === 'Escape')    { hide(); input.blur(); }
    });

    input.addEventListener('blur', function () {
      // Delay so mousedown on a result can fire first.
      setTimeout(hide, 120);
    });
    input.addEventListener('focus', function () { if (input.value.trim()) query(input.value.trim()); });
  }

  // ---- Watchlist ----------------------------------------------------------
  function initWatchlistButton() {
    const btn = document.getElementById('watchlist-toggle');
    if (!btn) return;
    const symbol = btn.dataset.symbol;
    if (!symbol) return;

    function refresh() {
      fetch('/api/watchlist')
        .then(function (r) { return r.json(); })
        .then(function (payload) {
          const inList = (payload.symbols || []).indexOf(symbol) !== -1;
          btn.dataset.state = inList ? 'on' : 'off';
          btn.textContent   = inList ? '★ In Watchlist' : '☆ Add to Watchlist';
        });
    }

    btn.addEventListener('click', function () {
      const isOn = btn.dataset.state === 'on';
      const url  = '/api/watchlist' + (isOn ? '/' + symbol : '');
      const opts = isOn
        ? { method: 'DELETE' }
        : { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ symbol: symbol }) };
      fetch(url, opts).then(refresh);
    });

    refresh();
  }

  // ---- Price alerts -------------------------------------------------------
  function initAlerts() {
    const form = document.getElementById('alert-form');
    const list = document.getElementById('alert-list');
    if (!form || !list) return;
    const symbol = form.dataset.symbol;

    function render(alerts) {
      list.innerHTML = '';
      if (!alerts.length) {
        list.innerHTML = '<li class="alert-empty">No alerts set.</li>';
        return;
      }
      alerts.forEach(function (a) {
        const li = document.createElement('li');
        li.className = 'alert-row' + (a.triggered_at ? ' alert-triggered' : '');
        const cond = a.condition === 'above' ? '≥' : '≤';
        li.innerHTML =
          '<span class="alert-cond">' + a.symbol + ' ' + cond + ' $' +
            Number(a.threshold).toFixed(2) + '</span>' +
          (a.triggered_at
            ? '<span class="alert-status">Triggered @ $' + Number(a.last_price).toFixed(2) + '</span>'
            : '<span class="alert-status">Active</span>') +
          '<button type="button" class="alert-remove" data-id="' + a.id + '">Remove</button>';
        list.appendChild(li);
      });
      list.querySelectorAll('.alert-remove').forEach(function (btn) {
        btn.addEventListener('click', function () {
          fetch('/api/alerts/' + btn.dataset.id, { method: 'DELETE' }).then(refresh);
        });
      });
    }

    function refresh() {
      fetch('/api/alerts?symbol=' + encodeURIComponent(symbol))
        .then(function (r) { return r.json(); })
        .then(function (payload) { render(payload.alerts || []); });
    }

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      const condition = form.querySelector('[name=condition]').value;
      const threshold = form.querySelector('[name=threshold]').value;
      fetch('/api/alerts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ symbol: symbol, condition: condition, threshold: threshold })
      })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.error) { alert(res.error); return; }
        form.querySelector('[name=threshold]').value = '';
        refresh();
      });
    });

    refresh();
  }

  // ---- Compare page -------------------------------------------------------
  function initCompare() {
    const container = document.getElementById('compareChart');
    if (!container) return;
    const symbols = (container.dataset.symbols || '').split(',').filter(Boolean);
    const period  = container.dataset.period || '1y';
    if (!symbols.length) return;

    const url = '/api/compare?symbols=' + encodeURIComponent(symbols.join(',')) +
                '&period=' + encodeURIComponent(period);
    fetch(url)
      .then(function (r) { return r.json(); })
      .then(function (payload) { renderCompareChart(container, payload); })
      .catch(function (err) { console.error('[compare] failed', err); });
  }

  function renderCompareChart(container, payload) {
    const series = payload.series || [];
    if (!series.length) {
      container.innerHTML = '<p class="no-data">No data available for the selected symbols.</p>';
      return;
    }

    const canvas = document.createElement('canvas');
    canvas.id = 'compareCanvas';
    container.innerHTML = '';
    container.appendChild(canvas);

    const palette = ['#0071e3', '#34c759', '#ff9500', '#af52de', '#ff3b30', '#5ac8fa'];

    // Union of dates across all series, sorted ascending.
    const dateSet = new Set();
    series.forEach(function (s) { (s.points || []).forEach(function (p) { dateSet.add(p.date); }); });
    const labels = Array.from(dateSet).sort();

    const datasets = series.map(function (s, i) {
      const byDate = {};
      (s.points || []).forEach(function (p) { byDate[p.date] = p.value; });
      return {
        label: s.symbol,
        data: labels.map(function (d) { return byDate[d] == null ? null : byDate[d]; }),
        borderColor: palette[i % palette.length],
        backgroundColor: palette[i % palette.length] + '22',
        borderWidth: 1.5,
        pointRadius: 0,
        spanGaps: true,
        tension: 0.15
      };
    });

    new Chart(canvas, {
      type: 'line',
      data: { labels: labels, datasets: datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        scales: {
          x: { ticks: { maxTicksLimit: 10, autoSkip: true } },
          y: {
            title: { display: true, text: 'Rebased to 100' },
            ticks: { callback: function (v) { return v.toFixed(0); } }
          }
        },
        plugins: {
          legend: { position: 'top' },
          tooltip: {
            callbacks: {
              label: function (ctx) { return ctx.dataset.label + ': ' + ctx.parsed.y.toFixed(2); }
            }
          }
        }
      }
    });
  }

  // ---- Boot ---------------------------------------------------------------
  window.addEventListener('DOMContentLoaded', function () {
    initSymbolSearch();
    initWatchlistButton();
    initAlerts();
    initCompare();
  });
})();
