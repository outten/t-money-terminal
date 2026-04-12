# T Money Terminal

A next-generation, open-source investment terminal inspired by the Bloomberg Terminal. Built with Ruby and Sinatra.

## Features
- **Multi-page navigation**: Dashboard, US Markets, Japan, Europe, Recommendations
- **Real-time market data** via Alpha Vantage (SPY, AAPL, MSFT, EWJ, VGK)
- **24-hour data caching** with manual refresh via `make refresh-cache`  
- **Buy/Sell/Hold recommendations** based on price momentum signals
- **Charts & visualizations** — line, bar, and summary charts via Chart.js
- Light/dark mode toggle (persisted across sessions)
- Fallback to mock data with notice when API is unavailable

## Getting Started

### Prerequisites
- Ruby >= 3.0 and Bundler

### Setup
```bash
git clone <repo-url>
cd t-money-terminal
make install
```

### Credentials
See CREDENTIALS.md and Instructions.md for Alpha Vantage API key setup.

### Run
```bash
make run
# → http://localhost:4567
```

### Test
```bash
make test
```

### Refresh Data Cache
```bash
make refresh-cache
```

## Pages

| Page | URL |
|---|---|
| Dashboard | /dashboard |
| US Markets | /us |
| Japan | /japan |
| Europe | /europe |
| Recommendations | /recommendations |

> All recommendations are for informational purposes only. Not financial advice.

## License
MIT
