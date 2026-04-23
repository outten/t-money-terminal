# T Money Terminal — Instructions

## 1. Prerequisites

- Ruby >= 3.0
- Bundler (`gem install bundler`)

## 2. Alpha Vantage API Key

The application uses Alpha Vantage for real-time market data. Market data is cached for 1 hour to stay within the free tier limits.

1. Register for a **free API key** at: https://www.alphavantage.co/support/#api-key
2. Copy your key.
3. At the project root, create a `.credentials` file:
   ```
   ALPHA_VANTAGE_API_KEY=your_key_here
   ```
4. If no API key is present, the application uses built-in mock data and flags it clearly.

## 3. Running the Application

```bash
bundle install
make run
```

Navigate to http://localhost:4567 in your browser.

## 4. Navigation

| Page | URL | Description |
|---|---|---|
| Dashboard | /dashboard | Global overview of all tracked symbols |
| US Markets | /us | SPY, AAPL, MSFT with charts |
| Japan | /japan | EWJ ETF (Japan proxy) |
| Europe | /europe | VGK ETF (Europe proxy) |
| Recommendations | /recommendations | Buy/Sell/Hold signals with rationale |

## 5. Refreshing Market Data Cache

Data is cached for **1 hour**. To manually refresh:

**Option 1: UI Button**
Click the **🔄 Refresh Data** button on any page (Dashboard, US Markets, Japan, Europe, Analysis).

**Option 2: Command Line**
```bash
make refresh-cache
```

This runs `scripts/refresh_cache.rb` which busts the disk cache and refetches from providers (respects rate limits).

## 6. Interpreting Recommendations

- **BUY** — Price momentum is positive (>+1% change). Upward trend indicated.
- **SELL** — Price momentum is negative (< -1% change). Downward pressure indicated.
- **HOLD** — Price is within normal range. No clear trend.

> ⚠️ All recommendations are for **informational purposes only** and are **not financial advice**. Always do your own research before making investment decisions.

## 7. Light/Dark Mode

Click the theme toggle in the header. Your preference is saved across sessions.

## 8. Data Sources

- **Alpha Vantage** — US, Japan (EWJ proxy), Europe (VGK proxy) via REST API
- Japan and Europe data are approximated using US-listed ETFs (EWJ, VGK) as proxies. Direct exchange APIs require paid access.
- All data citations and sources are documented in ANALYSIS.md.
