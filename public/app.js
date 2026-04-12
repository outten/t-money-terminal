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
  if (!ctx || !data.length) return;
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
    options: { responsive: true, plugins: { legend: { display: false } } }
  });
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

var historicalChartInstance = null;
function renderHistoricalChart(id, labels, prices) {
  const ctx = document.getElementById(id);
  if (!ctx) return;
  if (historicalChartInstance) {
    historicalChartInstance.destroy();
    historicalChartInstance = null;
  }
  historicalChartInstance = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [{
        label: 'Close Price',
        data: prices,
        borderColor: '#0071e3',
        backgroundColor: '#0071e31a',
        tension: 0.3,
        fill: true,
        pointRadius: 2
      }]
    },
    options: {
      responsive: true,
      plugins: { legend: { display: false } },
      scales: {
        x: { ticks: { maxTicksLimit: 8 } },
        y: { ticks: { callback: function(v) { return '$' + v.toFixed(2); } } }
      }
    }
  });
}
