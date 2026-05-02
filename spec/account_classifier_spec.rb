require 'rspec'
require_relative '../app/account_classifier'

RSpec.describe AccountClassifier do
  describe '.classify' do
    it 'detects Roth IRA / Roth 401(k)' do
      expect(AccountClassifier.classify('ROTH IRA')).to eq('roth')
      expect(AccountClassifier.classify('Roth 401(k)')).to eq('roth')
      expect(AccountClassifier.classify('Roth Individual Retirement')).to eq('roth')
    end

    it 'detects Traditional IRA (after Roth so the Roth wins)' do
      expect(AccountClassifier.classify('Traditional IRA')).to eq('traditional_ira')
      expect(AccountClassifier.classify('Trad IRA')).to eq('traditional_ira')
      expect(AccountClassifier.classify('Rollover IRA')).to eq('traditional_ira')
    end

    it 'detects 401(k) / 403(b) / 457 / TSP plans' do
      expect(AccountClassifier.classify('My Company 401(k)')).to eq('tax_deferred_401k')
      expect(AccountClassifier.classify('University 403(b)')).to eq('tax_deferred_401k')
      expect(AccountClassifier.classify('457 deferred comp')).to eq('tax_deferred_401k')
      expect(AccountClassifier.classify('Federal TSP')).to eq('tax_deferred_401k')
    end

    it 'detects "RETIREMENT-INVESTMENT PLAN" / "EMPLOYEE PLAN" wording (Fidelity 401k labels)' do
      expect(AccountClassifier.classify('COMCAST CORPORATION RETIREMENT-INVESTMENT PLAN')).to eq('tax_deferred_401k')
      expect(AccountClassifier.classify('Acme Inc Employee Plan')).to eq('tax_deferred_401k')
    end

    it 'detects deferred annuities' do
      expect(AccountClassifier.classify('Deferred Annuity')).to eq('deferred_annuity')
      expect(AccountClassifier.classify('Variable Annuity')).to eq('deferred_annuity')
    end

    it 'detects HSA' do
      expect(AccountClassifier.classify('HSA at Fidelity')).to eq('hsa')
      expect(AccountClassifier.classify('Health Savings Account')).to eq('hsa')
    end

    it 'detects taxable / individual / joint / TOD / trust accounts' do
      expect(AccountClassifier.classify('Individual - TOD')).to eq('taxable')
      expect(AccountClassifier.classify('Joint Tenants With Right of Survivorship')).to eq('taxable')
      expect(AccountClassifier.classify('Family Trust')).to eq('taxable')
      expect(AccountClassifier.classify('Taxable Brokerage')).to eq('taxable')
    end

    it 'returns "other" for empty / unknown account names' do
      expect(AccountClassifier.classify('')).to eq('other')
      expect(AccountClassifier.classify(nil)).to eq('other')
      expect(AccountClassifier.classify('Some Random Account')).to eq('other')
    end

    it 'is case-insensitive on common patterns' do
      expect(AccountClassifier.classify('roth ira')).to eq('roth')
      expect(AccountClassifier.classify('individual - tod')).to eq('taxable')
    end
  end

  describe '.kind_label' do
    it 'returns human labels for known kinds' do
      expect(AccountClassifier.kind_label('taxable')).to eq('Taxable')
      expect(AccountClassifier.kind_label('roth')).to eq('Roth')
      expect(AccountClassifier.kind_label('tax_deferred_401k')).to eq('Tax-deferred (401k / 403b / 457)')
      expect(AccountClassifier.kind_label('other')).to eq('Other / unclassified')
    end
  end

  describe '.kind_color' do
    it 'returns a hex color string for each known kind' do
      AccountClassifier::KINDS.each do |k|
        expect(AccountClassifier.kind_color(k)).to match(/\A#[0-9a-fA-F]+\z/)
      end
    end
  end
end
