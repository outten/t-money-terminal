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

    function render(list, payload) {
      items = list || [];
      results.innerHTML = '';

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

      // No matches but the query looks like a ticker → offer to discover it.
      // Adds a synthetic "Discover XYZ" item that POSTs to /api/symbols/discover
      // and routes to /analysis/XYZ on success.
      if (payload && payload.can_discover) {
        const li = document.createElement('li');
        li.className = 'search-result-item search-discover';
        li.innerHTML =
          '<span class="sr-symbol">' + payload.query + '</span>' +
          '<span class="sr-name">Look up this ticker…</span>' +
          '<span class="sr-region">discover</span>';
        li.addEventListener('mousedown', function (e) {
          e.preventDefault();
          discover(payload.query, li);
        });
        results.appendChild(li);
        items = items.concat([{ symbol: payload.query, name: payload.query, region: 'discover', _discover: true }]);
      }

      if (!results.children.length) { hide(); return; }
      show();
    }

    function discover(symbol, liEl) {
      if (liEl) liEl.classList.add('loading');
      fetch('/api/symbols/discover', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ symbol: symbol })
      })
        .then(function (r) {
          return r.json().then(function (body) { return { ok: r.ok, body: body }; });
        })
        .then(function (resp) {
          if (resp.ok && resp.body && resp.body.symbol) {
            go(resp.body.symbol);
          } else {
            if (liEl) {
              liEl.classList.remove('loading');
              liEl.classList.add('error');
              liEl.querySelector('.sr-name').textContent =
                (resp.body && resp.body.error) ? resp.body.error : 'Could not find that ticker.';
            }
          }
        })
        .catch(function () {
          if (liEl) { liEl.classList.remove('loading'); liEl.classList.add('error'); }
        });
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
          render(payload.results || [], payload);
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
        if (!pick) return;
        if (pick._discover) {
          const lis = results.querySelectorAll('.search-result-item');
          discover(pick.symbol, lis[lis.length - 1]);
        } else {
          go(pick.symbol);
        }
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

  // ---- Portfolio value-over-time chart on /portfolio ---------------------
  function initPortfolioHistory() {
    const canvas = document.getElementById('portfolio-history-chart');
    const series = window.PORTFOLIO_HISTORY;
    if (!canvas || !series || series.length < 2) return;

    const labels = series.map(function (p) { return p.date; });
    const values = series.map(function (p) { return p.total_value; });

    new Chart(canvas, {
      type: 'line',
      data: {
        labels: labels,
        datasets: [{
          label: 'Portfolio value',
          data: values,
          borderColor: '#0071e3',
          backgroundColor: '#0071e322',
          borderWidth: 2,
          pointRadius: 2,
          pointHoverRadius: 5,
          fill: true,
          tension: 0.15,
          spanGaps: true
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        scales: {
          x: { ticks: { maxTicksLimit: 10, autoSkip: true } },
          y: {
            title: { display: true, text: 'Total value ($)' },
            ticks: {
              callback: function (v) {
                if (Math.abs(v) >= 1e6) return '$' + (v / 1e6).toFixed(2) + 'M';
                if (Math.abs(v) >= 1e3) return '$' + (v / 1e3).toFixed(0) + 'k';
                return '$' + v.toFixed(0);
              }
            }
          }
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: function (ctx) {
                const point = series[ctx.dataIndex];
                const lines = ['Total: $' + point.total_value.toLocaleString(undefined, { maximumFractionDigits: 2 })];
                if (point.day_change != null) {
                  const sign = point.day_change >= 0 ? '+' : '';
                  const pctText = point.day_change_pct != null
                    ? ' (' + sign + (point.day_change_pct * 100).toFixed(2) + '%)'
                    : '';
                  lines.push('Δ vs prior: ' + sign + '$' + Math.abs(point.day_change).toLocaleString(undefined, { maximumFractionDigits: 2 }) + pctText);
                }
                if (point.unrealized_pl != null) {
                  const sign = point.unrealized_pl >= 0 ? '+' : '';
                  lines.push('Unrealized P&L: ' + sign + '$' + Math.abs(point.unrealized_pl).toLocaleString(undefined, { maximumFractionDigits: 2 }));
                }
                return lines;
              }
            }
          }
        }
      }
    });
  }

  // ---- Lot detail expand/collapse on /portfolio --------------------------
  function initLotToggles() {
    document.querySelectorAll('.lot-toggle').forEach(function (btn) {
      btn.addEventListener('click', function () {
        const target = document.getElementById(btn.dataset.target);
        if (!target) return;
        const open = target.hidden;
        target.hidden = !open;
        btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        btn.textContent = btn.textContent.replace(/[▾▴]/, open ? '▴' : '▾');
      });
    });
  }

  // ---- Boot ---------------------------------------------------------------
  // (The correlation heatmap is server-rendered as an HTML table — no JS needed.)
  window.addEventListener('DOMContentLoaded', function () {
    initSymbolSearch();
    initWatchlistButton();
    initAlerts();
    initCompare();
    initPortfolioHistory();
    initLotToggles();
  });
})();
