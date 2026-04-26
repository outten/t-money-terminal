document.addEventListener('DOMContentLoaded', function() {
  // Theme: persist via localStorage
  function applyTheme(dark) {
    document.body.classList.toggle('dark', dark);
    const btn = document.getElementById('theme-toggle');
    if (btn) btn.textContent = dark ? '☀️ Light' : '🌙 Dark';
  }
  const savedDark = localStorage.getItem('theme') === 'dark';
  applyTheme(savedDark);
  window.toggleTheme = function() {
    const isDark = !document.body.classList.contains('dark');
    localStorage.setItem('theme', isDark ? 'dark' : 'light');
    applyTheme(isDark);
  };
});

function renderSummaryChart(id, data) {
  const ctx = document.getElementById(id);
  if (!ctx) {
    console.error('Canvas element not found:', id);
    return;
  }
  if (!data || !data.length) {
    console.warn('No data provided for chart:', id);
    return;
  }
  
  try {
    new Chart(ctx, {
      type: 'bar',
      data: {
        labels: data.map(d => d.symbol),
        datasets: [{
          label: 'Price',
          data: data.map(d => parseFloat(d.price) || 0),
          backgroundColor: data.map(d =>
            d.signal === 'BUY' ? '#34c75966' : d.signal === 'SELL' ? '#ff3b3066' : '#aeaeb266'
          ),
          borderColor: data.map(d =>
            d.signal === 'BUY' ? '#34c759' : d.signal === 'SELL' ? '#ff3b30' : '#aeaeb2'
          ),
          borderWidth: 1.5
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { 
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: function(context) {
                return context.dataset.label + ': $' + context.parsed.y.toFixed(2);
              }
            }
          }
        },
        scales: {
          y: {
            beginAtZero: false,
            ticks: {
              callback: function(value) {
                return '$' + value.toFixed(0);
              }
            }
          }
        }
      }
    });
  } catch (error) {
    console.error('Error rendering summary chart:', error);
  }
}

function renderPriceChart(id, data) {
  const ctx = document.getElementById(id);
  if (!ctx || !data.length) return;
  new Chart(ctx, {
    type: 'line',
    data: {
      labels: data.map(d => d.symbol),
      datasets: [{
        label: 'Price',
        data: data.map(d => parseFloat(d.price) || 0),
        borderColor: '#0071e3',
        backgroundColor: '#0071e31a',
        tension: 0.3,
        fill: true,
        pointRadius: 5
      }]
    },
    options: { responsive: true, plugins: { legend: { display: false } } }
  });
}

function renderVolumeChart(id, data) {
  const ctx = document.getElementById(id);
  if (!ctx || !data.length) return;
  new Chart(ctx, {
    type: 'bar',
    data: {
      labels: data.map(d => d.symbol),
      datasets: [{
        label: 'Volume',
        data: data.map(d => parseInt(d.volume) || 0),
        backgroundColor: '#5ac8fa66',
        borderColor: '#5ac8fa',
        borderWidth: 1.5
      }]
    },
    options: { responsive: true, plugins: { legend: { display: false } } }
  });
}

// ---------------------------------------------------------------------------
// Historical chart powered by TradingView lightweight-charts.
// Four synchronized panes:
//   - Price: candlesticks with SMA 20/50/200 and Bollinger overlays
//   - Volume histogram (coloured by candle direction)
//   - RSI(14) with 30/70 reference lines
//   - MACD(12/26/9) signal + histogram
//
// Pane heights are tuned so the oscillator panes (RSI/MACD) have enough room
// to show their reference lines and series without crowding. The CSS
// `.tv-chart-host { min-height }` must match the sum below.
// ---------------------------------------------------------------------------

var PANE_HEIGHTS = {
  price:  360,
  volume: 360,
  rsi:    360,
  macd:   360
};

var historicalChartState = {
  priceChart: null,
  volChart:   null,
  rsiChart:   null,
  macdChart:  null,
  series:     {},
  logScale:   false,
  showBB:     true,
  showSMA:    true
};

function destroyHistoricalChart() {
  var s = historicalChartState;
  ['priceChart', 'volChart', 'rsiChart', 'macdChart'].forEach(function(k) {
    if (s[k]) { try { s[k].remove(); } catch (_) {} s[k] = null; }
  });
  s.series = {};
}

function isDarkMode() {
  return document.body.classList.contains('dark');
}

function chartPalette() {
  if (isDarkMode()) {
    return {
      bg:       '#2c2c2e',
      text:     '#f5f5f7',
      grid:     '#3a3a3c',
      border:   '#48484a',
      up:       '#34c759',
      down:     '#ff453a',
      sma20:    '#ff9f0a',
      sma50:    '#0a84ff',
      sma200:   '#bf5af2',
      bb:       '#8e8e93',
      rsi:      '#5ac8fa',
      macd:     '#0a84ff',
      signal:   '#ff9f0a'
    };
  }
  return {
    bg:       '#ffffff',
    text:     '#1d1d1f',
    grid:     '#f2f2f7',
    border:   '#d1d1d6',
    up:       '#34c759',
    down:     '#ff3b30',
    sma20:    '#ff9500',
    sma50:    '#0071e3',
    sma200:   '#af52de',
    bb:       '#8e8e93',
    rsi:      '#5ac8fa',
    macd:     '#0071e3',
    signal:   '#ff9500'
  };
}

function baseChartOptions(pal, height) {
  return {
    autoSize: true, // v4.x: track container size automatically
    height: height,
    layout: {
      background: { type: 'solid', color: pal.bg },
      textColor: pal.text,
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif',
      fontSize: 11
    },
    grid: {
      vertLines: { color: pal.grid },
      horzLines: { color: pal.grid }
    },
    rightPriceScale: { borderColor: pal.border, scaleMargins: { top: 0.1, bottom: 0.05 } },
    timeScale: { borderColor: pal.border, timeVisible: false, secondsVisible: false },
    crosshair: {
      mode: 1, // Normal (stays at data points)
      vertLine: { color: pal.border, labelBackgroundColor: pal.border },
      horzLine: { color: pal.border, labelBackgroundColor: pal.border }
    },
    handleScroll: true,
    handleScale:  true
  };
}

// Convert [{date:'YYYY-MM-DD', ...}] into lightweight-charts' {time, value|open|high|...} format.
// lightweight-charts accepts a 'YYYY-MM-DD' string as a business-day time value.
function mapLine(series, bars) {
  var out = [];
  for (var i = 0; i < bars.length; i++) {
    var v = series[i];
    if (v === null || v === undefined) continue;
    out.push({ time: bars[i].date, value: v });
  }
  return out;
}

function mapHistogram(series, bars, colorFn) {
  var out = [];
  for (var i = 0; i < bars.length; i++) {
    var v = series[i];
    if (v === null || v === undefined) continue;
    var entry = { time: bars[i].date, value: v };
    if (colorFn) entry.color = colorFn(v, i, bars);
    out.push(entry);
  }
  return out;
}

function mapCandles(bars) {
  return bars.map(function(b) {
    // Fall back to close-only synthetic candle if a provider didn't supply OHLC.
    var o = (b.open  !== undefined && b.open  !== null) ? b.open  : b.close;
    var h = (b.high  !== undefined && b.high  !== null) ? b.high  : b.close;
    var l = (b.low   !== undefined && b.low   !== null) ? b.low   : b.close;
    return { time: b.date, open: o, high: h, low: l, close: b.close };
  });
}

function mapVolume(bars, pal) {
  return bars.map(function(b, i) {
    var prev = i > 0 ? bars[i - 1].close : b.close;
    var up = b.close >= prev;
    return {
      time:  b.date,
      value: b.volume || 0,
      color: up ? (pal.up + '66') : (pal.down + '66')
    };
  });
}

function renderHistoricalChart(containerId, payload) {
  try {
    _renderHistoricalChart(containerId, payload);
  } catch (err) {
    console.error('[renderHistoricalChart] failed:', err);
    var el = document.getElementById(containerId);
    if (el) {
      el.innerHTML = '<p class="no-data chart-no-data">Chart failed to render: ' +
        (err && err.message ? err.message : err) + '</p>';
    }
  }
}

function _renderHistoricalChart(containerId, payload) {
  // Backwards compatibility: older call-sites pass (id, labels, prices).
  if (Array.isArray(payload) === false && arguments.length === 3) {
    var labels = arguments[1], prices = arguments[2];
    var bars = labels.map(function(d, i) { return { date: d, close: prices[i] }; });
    payload = { bars: bars, indicators: {} };
  }

  var container = document.getElementById(containerId);
  if (!container) {
    console.warn('[chart] container not found:', containerId);
    return;
  }
  if (!window.LightweightCharts) {
    container.innerHTML = '<p class="no-data chart-no-data">Chart library failed to load.</p>';
    return;
  }

  destroyHistoricalChart();
  container.innerHTML = '';

  var bars = (payload && payload.bars) || [];
  var ind  = (payload && payload.indicators) || {};
  if (!bars.length) {
    container.innerHTML = '<p class="no-data chart-no-data">No historical data available.</p>';
    return;
  }

  var pal = chartPalette();
  var state = historicalChartState;

  // Build 4 DOM panes inside the container (price / volume / rsi / macd).
  function pane(h, className) {
    var el = document.createElement('div');
    el.className = 'tv-pane ' + (className || '');
    el.style.height = h + 'px';
    el.style.width = '100%';
    container.appendChild(el);
    return el;
  }
  var priceEl = pane(PANE_HEIGHTS.price,  'tv-price');
  var volEl   = pane(PANE_HEIGHTS.volume, 'tv-volume');
  var rsiEl   = pane(PANE_HEIGHTS.rsi,    'tv-rsi');
  var macdEl  = pane(PANE_HEIGHTS.macd,   'tv-macd');

  // ---- Price pane: candlesticks + SMA + Bollinger ------------------------
  var priceChart = LightweightCharts.createChart(priceEl, baseChartOptions(pal, PANE_HEIGHTS.price));
  state.priceChart = priceChart;
  priceChart.applyOptions({
    rightPriceScale: { mode: state.logScale ? 1 : 0, borderColor: pal.border }
  });
  var candleSeries = priceChart.addCandlestickSeries({
    upColor:       pal.up,
    downColor:     pal.down,
    borderUpColor: pal.up,
    borderDownColor: pal.down,
    wickUpColor:   pal.up,
    wickDownColor: pal.down
  });
  candleSeries.setData(mapCandles(bars));
  state.series.candle = candleSeries;

  function addLine(colour, width) {
    return priceChart.addLineSeries({
      color: colour, lineWidth: width || 1.5, priceLineVisible: false, lastValueVisible: false
    });
  }
  if (state.showSMA) {
    state.series.sma20  = addLine(pal.sma20);   state.series.sma20.setData(mapLine(ind.sma20  || [], bars));
    state.series.sma50  = addLine(pal.sma50);   state.series.sma50.setData(mapLine(ind.sma50  || [], bars));
    state.series.sma200 = addLine(pal.sma200);  state.series.sma200.setData(mapLine(ind.sma200 || [], bars));
  }
  if (state.showBB && (ind.bb_upper || []).length) {
    state.series.bbU = addLine(pal.bb, 1); state.series.bbU.setData(mapLine(ind.bb_upper  || [], bars));
    state.series.bbM = addLine(pal.bb, 1); state.series.bbM.setData(mapLine(ind.bb_middle || [], bars));
    state.series.bbL = addLine(pal.bb, 1); state.series.bbL.setData(mapLine(ind.bb_lower  || [], bars));
  }

  // ---- Volume pane -------------------------------------------------------
  var volChart = LightweightCharts.createChart(volEl, baseChartOptions(pal, PANE_HEIGHTS.volume));
  state.volChart = volChart;
  var volSeries = volChart.addHistogramSeries({ priceFormat: { type: 'volume' }, color: pal.bb });
  volSeries.setData(mapVolume(bars, pal));

  // ---- RSI pane ----------------------------------------------------------
  var rsiChart = LightweightCharts.createChart(rsiEl, baseChartOptions(pal, PANE_HEIGHTS.rsi));
  state.rsiChart = rsiChart;
  var rsiSeries = rsiChart.addLineSeries({ color: pal.rsi, lineWidth: 1.5, priceLineVisible: false });
  rsiSeries.setData(mapLine(ind.rsi || [], bars));
  rsiSeries.createPriceLine({ price: 70, color: pal.down, lineWidth: 1, lineStyle: 2, axisLabelVisible: true, title: '70' });
  rsiSeries.createPriceLine({ price: 30, color: pal.up,   lineWidth: 1, lineStyle: 2, axisLabelVisible: true, title: '30' });
  rsiChart.priceScale('right').applyOptions({ autoScale: false, scaleMargins: { top: 0.1, bottom: 0.1 } });

  // ---- MACD pane ---------------------------------------------------------
  var macdChart = LightweightCharts.createChart(macdEl, baseChartOptions(pal, PANE_HEIGHTS.macd));
  state.macdChart = macdChart;
  var macdLine   = macdChart.addLineSeries({ color: pal.macd,   lineWidth: 1.5, priceLineVisible: false });
  var sigLine    = macdChart.addLineSeries({ color: pal.signal, lineWidth: 1.5, priceLineVisible: false });
  var histSeries = macdChart.addHistogramSeries({ color: pal.bb });
  macdLine.setData(mapLine(ind.macd || [], bars));
  sigLine.setData(mapLine(ind.macd_signal || [], bars));
  histSeries.setData(mapHistogram(ind.macd_histogram || [], bars, function(v) {
    return v >= 0 ? (pal.up + '99') : (pal.down + '99');
  }));

  // ---- Sync time scales so panning/zooming the price pane moves all -----
  var charts = [priceChart, volChart, rsiChart, macdChart];
  charts.forEach(function(c, i) {
    c.timeScale().subscribeVisibleLogicalRangeChange(function(range) {
      if (!range) return;
      charts.forEach(function(other, j) {
        if (i === j) return;
        var r = other.timeScale().getVisibleLogicalRange();
        if (!r || r.from !== range.from || r.to !== range.to) {
          other.timeScale().setVisibleLogicalRange(range);
        }
      });
    });
  });

  // ---- Crosshair → OHLCV readout on the price pane -----------------------
  var readout = document.createElement('div');
  readout.className = 'tv-readout';
  priceEl.appendChild(readout);
  function formatReadout(bar) {
    if (!bar) { readout.innerHTML = ''; return; }
    var chg = bar.open ? ((bar.close - bar.open) / bar.open * 100) : null;
    var chgClass = chg === null ? '' : (chg >= 0 ? 'positive' : 'negative');
    var chgStr = chg === null ? '' : (chg >= 0 ? '+' : '') + chg.toFixed(2) + '%';
    readout.innerHTML =
      '<span class="tv-readout-date">' + bar.date + '</span>' +
      '<span>O <b>' + (bar.open ?? '—') + '</b></span>' +
      '<span>H <b>' + (bar.high ?? '—') + '</b></span>' +
      '<span>L <b>' + (bar.low  ?? '—') + '</b></span>' +
      '<span>C <b>' + bar.close + '</b></span>' +
      (bar.volume ? '<span>V <b>' + bar.volume.toLocaleString() + '</b></span>' : '') +
      (chg !== null ? '<span class="' + chgClass + '">' + chgStr + '</span>' : '');
  }
  formatReadout(bars[bars.length - 1]);
  priceChart.subscribeCrosshairMove(function(param) {
    if (!param || !param.time) { formatReadout(bars[bars.length - 1]); return; }
    var match = bars.find(function(b) { return b.date === param.time; });
    formatReadout(match || bars[bars.length - 1]);
  });

  // Fit the full series on first render. autoSize: true handles width tracking.
  priceChart.timeScale().fitContent();
}

// Toggle linear / log scale on the price pane.
function toggleHistoricalLogScale() {
  historicalChartState.logScale = !historicalChartState.logScale;
  if (historicalChartState.priceChart) {
    historicalChartState.priceChart.priceScale('right').applyOptions({
      mode: historicalChartState.logScale ? 1 : 0
    });
  }
  var btn = document.getElementById('log-scale-btn');
  if (btn) btn.textContent = historicalChartState.logScale ? 'Linear' : 'Log';
}
