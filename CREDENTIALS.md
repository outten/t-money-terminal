# API Credentials Setup

To enable real-time market data from Alpha Vantage and IEX Cloud, you must provide API keys in a `.credentials` file at the project root.

## IEX Cloud

Was retired on August, 2024.

## 1. Obtain API Keys

- **Alpha Vantage:**
  - Sign up at https://www.alphavantage.co/support/#api-key
  - Copy your API key
- **IEX Cloud:**
  - Register at https://iexcloud.io/cloud-login#/register/
  - Copy your secret API token

## 2. Create `.credentials` File

At the root of your project, create a file named `.credentials` with the following content:

```
ALPHA_VANTAGE_API_KEY=your_alpha_vantage_key_here
IEX_CLOUD_API_KEY=your_iex_cloud_key_here
```

Replace the values with your actual API keys.

## 3. Load Credentials in Development

The app uses the `dotenv` gem to automatically load these environment variables from `.credentials`.

## 4. Security
- **Never commit `.credentials` to version control.** Add it to your `.gitignore`.
- Share credentials securely with trusted team members only.

---

After setup, restart your app to use the new credentials.
