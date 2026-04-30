# ANALYSIS — Bloomberg-comparison framing + actual data sources

## Insights from Michael Bloomberg

### At the time
- Bloomberg Terminal revolutionized financial data access by aggregating real-time market data, analytics, and news in one place.
- Proprietary data feeds, exclusive exchange partnerships, and a dedicated network gave Bloomberg a structural moat.
- Power-user UI: dense, fast, keyboard-driven — optimized for traders.

### Today
- Many data sources are now public (Yahoo, Stooq) or accessible via free-tier APIs (Tiingo, Finnhub, FMP, Polygon, FRED).
- User expectations for design and usability are higher (Apple/Google-influenced).
- Open-source frameworks + cloud infrastructure dramatically lower the barrier to entry.

## Proprietary then vs. public now

Bloomberg relied on exclusive feeds. T Money Terminal aggregates **only public, free-tier sources**:

| Need | Bloomberg | T Money Terminal |
|---|---|---|
| Real-time quotes | Direct exchange feeds | Tiingo / Alpha Vantage / Finnhub / Yahoo (waterfall) |
| Historical OHLCV | Proprietary | Yahoo / FMP / Polygon / Finnhub / Tiingo / AV-weekly (waterfall) |
| Fundamentals | Aggregated | FMP (`/stable/key-metrics`, `ratios`, `discounted-cash-flow`, `earnings-calendar`) |
| Macro | Bloomberg Economics | FRED (Fed funds, treasuries, CPI, unemployment, VIX) |
| News + analyst | Bloomberg News, exclusive | Finnhub primary, NewsAPI fallback; Finnhub analyst recs |
| International indices | Direct | Stooq (Nikkei, Hang Seng, DAX, FTSE, CAC, S&P 500, Nasdaq, Dow) |
| Filings | Bloomberg | SEC EDGAR (10-K / 10-Q / 8-K) — wired but no UI panel yet |
| Options | Bloomberg | Polygon (free tier: end-of-day) |
| Recommendations | Analyst-of-record | Finnhub analyst aggregation + locally-computed momentum + technical signals |

The cost of building this stack: **$0/month** at typical retail-investor usage volume. See [CREDENTIALS.md](CREDENTIALS.md) for free-tier limits and the FMP whitelist caveat.

## Paid services that could increase value

- **Polygon paid tier** — real-time options + intraday trades + extended-hours data + 5+ year history. Starting ~$30/month. Would unlock options visualizations the free tier kneecaps.
- **Premium news/sentiment** — Bloomberg, Refinitiv, Morningstar all in the $50–$200/month range; not justified at proof-of-concept stage.
- **Direct exchange data** — irrelevant for retail use.

**Recommendation**: stay free-tier. The provider waterfall + market-aware caching + broker-import-as-refresh already produces a fast, accurate experience for personal investing. Move to paid only if a specific feature (live options, intraday algos) demands it.

## Data sources actually wired up

| Source | Used by | Free | Auth |
|---|---|---|---|
| [Tiingo](https://www.tiingo.com) | Quotes + historical | Yes | API key |
| [Alpha Vantage](https://www.alphavantage.co) | Quote + weekly historical fallback | Yes (5/min, 25/day) | API key |
| [Finnhub](https://finnhub.io) | Analyst, profile, news, candles | Yes (60/min) | API key |
| [Financial Modeling Prep](https://site.financialmodelingprep.com/developer/docs) | Fundamentals + DCF + historical fallback | Yes (250/day; per-symbol whitelist) | API key |
| [Polygon.io](https://polygon.io) | Daily aggregates + options | Yes (5/min) | API key |
| [FRED](https://fred.stlouisfed.org) | Macro (Fed funds, treasuries, CPI, unemployment, VIX) | Yes (unlimited) | API key |
| [NewsAPI](https://newsapi.org) | News fallback to Finnhub | Yes (100/day) | API key |
| [Stooq](https://stooq.com) | International indices + ETF history | Yes | None |
| [Yahoo Finance](https://finance.yahoo.com) | Quote + historical primary | Yes | None (IP-throttled) |
| [SEC EDGAR](https://www.sec.gov/edgar/sec-api-documentation) | 10-K / 10-Q / 8-K filings | Yes | None (UA header) |

All sources are public; no scraping, no ToS-violating endpoints.

> All recommendations, analytics, and valuations rendered by this app are for informational purposes only. Not financial advice.
