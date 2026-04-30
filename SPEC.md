# T Money Terminal — Original brief

> 📌 **This is the original scoping brief, kept as historical context.** Actual feature
> progress and the current architecture live in:
>
> - [README.md](README.md) — feature surface + page list
> - [AGENTS.md](AGENTS.md) — architecture, caching contract, gotchas
> - [TODO.md](TODO.md) — shipped + open + dropped roadmap items
> - [ANALYSIS.md](ANALYSIS.md) — Bloomberg-comparison framing + data-source mapping
> - [CREDENTIALS.md](CREDENTIALS.md) — API key setup
> - [Instructions.md](Instructions.md) — user-facing how-to

---

The "T Money Terminal" project is based on answering this:

```
Michael Bloomberg was brilliant when he came up with the Bloomberg Terminal that made him famous, wealthy, etc.

Given the current technologies and data sources that are available, let's create a proof-of-concept to create the next generation terminal that will help investment professions as well as casual investors.
```

If Michael Bloomberg started today, what would be the same, different, new.

## Analyis

- create an ANALAYSIS.md
  - insights from Michael Bloomberg
    - at the time
    - today
  - what proprietary information sources did he tie into
    - can we get similar insight for our project with public, vetted data
- what, if any, paid services could increase our value to our users
  - include any cost analysis
    - include recommendation: if YES potential ROI

### Sources

- for everyting, CITE sources
- use sources that are Peer reviewed
- US stock market data
- Japan stock market data
- Europs stock market data

## Look and Feel

- think Apple: clean, easy and clear User Experience
- light and dark mode toggle in header
- charts and flow diagrams that will help the user

## Tech Stack

- Ruby
- Sinatra
- rerun

## Tests

- build tests along the way for each phase / step
  - smoke, integration, etc.

## Documentation

- maintain and update documentation along the way
  - README.md: for users
  - DEVELOPER.md: for developers and devops engineers
  - anything else you feel appropriate

## Makefile

- add directives for running and maintaining application along the way

## Instructions

Make an Insturctions.md file with anything the user of this application needs to do to support the application. For example, "You need to online to these APIs so I can get good clear data". 

## Real Time

Wherever possible, the application should display dynamic, realtime data on a recommenation to buy, sell, hold, etc.

## Execution

The initial version of this application is to do analysis and make recommendations. In the future, this application will integrate into buy / sell systems.
