# API Credentials Setup

To enable real-time market data, provide API keys in a `.credentials` file at the project root.

## 1. Obtain API Keys

- **Tiingo** *(recommended — historical price data)*
  - Sign up at https://www.tiingo.com
  - Go to Account → API → copy your token
- **Alpha Vantage** *(quotes fallback — 25 req/day free)*
  - Sign up at https://www.alphavantage.co/support/#api-key
- **Finnhub** *(analyst recommendations + company profiles)*
  - Sign up at https://finnhub.io

## 2. Create `.credentials` File

At the root of your project, create a file named `.credentials`:

```
TIINGO_API_KEY=your_tiingo_token_here
ALPHA_VANTAGE_API_KEY=your_alpha_vantage_key_here
FINNHUB_API_KEY=your_finnhub_key_here
```

## 3. Load Credentials in Development

The app uses the `dotenv` gem to automatically load these environment variables from `.credentials`.

## 4. Security
- **Never commit `.credentials` to version control.** It is already in `.gitignore`.
- Share credentials securely with trusted team members only.

---

After setup, run `make refresh-cache` to pre-populate the disk cache, then `make dev` to start the app.
