## MODIFIED Requirements

### Requirement: Company and fund profile section
The analysis page SHALL display the symbol's company or fund profile including name, description, exchange, industry/category, market cap, PE ratio, 52-week high/low, and IPO date (where available). Links to Google Finance and Yahoo Finance SHALL be provided and SHALL open in a new tab. When the Finnhub profile includes a non-blank `weburl` value, the page SHALL also display a direct link to the company or fund's homepage that opens in a new tab. The data source SHALL be cited.

#### Scenario: Profile displayed with source link
- **WHEN** the user views the analysis page for any symbol
- **THEN** a profile section is visible showing available company/fund metadata, with Google Finance and Yahoo Finance links that open in a new tab
- **AND** the data source is cited (Finnhub or hardcoded for known ETFs)

#### Scenario: Homepage link shown when weburl available
- **WHEN** the Finnhub profile contains a non-blank `weburl`
- **THEN** the profile section shows a "Website" link to that URL that opens in a new tab with rel="noopener noreferrer"

#### Scenario: Homepage link absent when weburl missing
- **WHEN** the Finnhub profile has no `weburl` or it is blank
- **THEN** no homepage link is rendered in the profile section
