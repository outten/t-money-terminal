# ANALYSIS.md

## Insights from Michael Bloomberg

### At the Time
- Bloomberg Terminal revolutionized financial data access by aggregating real-time market data, analytics, and news in one place.
- Proprietary data sources and exclusive partnerships gave Bloomberg a competitive edge.
- The interface, while dense, was highly optimized for speed and power users.

### Today
- Many data sources are now public or available via APIs (e.g., Yahoo Finance, Alpha Vantage, IEX Cloud).
- User expectations for design and usability are much higher (influenced by Apple, Google, etc.).
- Open-source tools and cloud infrastructure lower the barrier to entry for building financial applications.

## Proprietary Information Sources (Then vs. Now)
- Bloomberg relied on exclusive data feeds from exchanges, newswires, and financial institutions.
- Today, similar insights can be achieved using a mix of public APIs, open data, and paid services for premium data.

## Public Data Sources for This Project
- US: IEX Cloud, Yahoo Finance, Alpha Vantage
- Japan: Nikkei, Yahoo Japan Finance, Quandl
- Europe: Euronext, Yahoo Finance, Quandl

## Paid Services to Increase Value
- Consider premium APIs for real-time or historical data (e.g., Bloomberg, Refinitiv, Morningstar)
- Cost analysis: Most premium APIs are subscription-based, ranging from $50–$200/month for small teams
- Recommendation: Start with public data; evaluate ROI for paid services as user needs grow

## Sources
- [IEX Cloud](https://iexcloud.io/)
- [Yahoo Finance](https://finance.yahoo.com/)
- [Alpha Vantage](https://www.alphavantage.co/)
- [Quandl](https://www.quandl.com/)
- [Nikkei](https://www.nikkei.com/)
- [Euronext](https://www.euronext.com/)

*All sources are public or peer-reviewed where possible. Update as new sources are integrated.*

# Mock market data for US, Japan, and Europe is already integrated in the dashboard (see app.js and index.erb).
# Next, create a new Ruby service and UI endpoint for fetching and displaying real-time data from a public API (e.g., Alpha Vantage or IEX Cloud).
