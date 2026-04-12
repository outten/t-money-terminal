## 1. Remove IEX Cloud Integration

- [ ] 1.1 Remove all IEX Cloud code from backend (market_data_service.rb, main.rb)
- [ ] 1.2 Remove IEX Cloud UI elements and API calls from frontend (app.js, index.erb)
- [ ] 1.3 Remove IEX Cloud references from documentation and credentials files

## 2. Alpha Vantage Integration

- [ ] 2.1 Ensure Alpha Vantage is the only real-time data provider in backend and frontend
- [ ] 2.2 Update environment variable loading and error handling for Alpha Vantage API key
- [ ] 2.3 Update UI to reference only Alpha Vantage for real-time data

## 3. Testing

- [ ] 3.1 Remove or update tests referencing IEX Cloud
- [ ] 3.2 Add/verify tests for Alpha Vantage integration (mock API if needed)

## 4. Documentation

- [ ] 4.1 Update README.md, DEVELOPER.md, and CREDENTIALS.md to reference only Alpha Vantage
- [ ] 4.2 Document migration and breaking changes
