require_relative 'cache_store'
require_relative 'http_client'

module Providers
  # SEC EDGAR — filings index for a given CIK. No API key required, but SEC
  # requires a descriptive User-Agent per their fair-access policy.
  #
  # Docs: https://www.sec.gov/edgar/sec-api-documentation
  module EdgarService
    BASE        = 'https://data.sec.gov'
    NAMESPACE   = 'edgar'
    CACHE_TTL   = 6 * 3600
    USER_AGENT  = 'T-Money-Terminal research@local.invalid'
    THROTTLE    = Throttle.new(0.15) # SEC asks ≤10 req/sec

    module_function

    # Recent filings index for a 10-digit CIK string (zero-padded).
    # Returns an array of { form:, filing_date:, accession:, primary_doc:, url: }.
    def recent_filings(cik, limit: 20)
      cik10 = cik.to_s.rjust(10, '0')
      cache_key = "recent_#{cik10}"

      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached).first(limit) if cached

      THROTTLE.wait!
      url = "#{BASE}/submissions/CIK#{cik10}.json"
      status, parsed, _body = HttpClient.get_json(url, headers: { 'User-Agent' => USER_AGENT })
      return nil unless status.between?(200, 299) && parsed.is_a?(Hash)

      recent = parsed.dig('filings', 'recent') || {}
      forms        = recent['form']          || []
      dates        = recent['filingDate']    || []
      accessions   = recent['accessionNumber'] || []
      primary_docs = recent['primaryDocument'] || []

      rows = forms.each_with_index.map do |form, i|
        acc   = accessions[i].to_s.delete('-')
        doc   = primary_docs[i]
        {
          'form'         => form,
          'filing_date'  => dates[i],
          'accession'    => accessions[i],
          'primary_doc'  => doc,
          'url'          => acc.empty? || doc.nil? ? nil : "https://www.sec.gov/Archives/edgar/data/#{cik10.to_i}/#{acc}/#{doc}"
        }
      end

      CacheStore.write(NAMESPACE, cache_key, rows)
      symbolize(rows).first(limit)
    rescue StandardError => e
      warn "[EdgarService] recent_filings failed for CIK #{cik}: #{e.message}" unless test_env?
      nil
    end

    def symbolize(arr)
      return [] unless arr.is_a?(Array)
      arr.map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : h }
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
