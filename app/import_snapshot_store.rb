require 'json'
require 'fileutils'
require 'time'
require 'date'

# ImportSnapshotStore — persistent snapshots of every broker import.
#
# Each snapshot lives at `data/imports/<source>/<basename>.json` and contains
# the full parsed CSV result (positions + skipped rows + parser metadata).
# Snapshots are append-only (we don't delete on re-import), giving us an
# audit trail and enabling week-over-week comparison views without re-parsing.
#
# Layout:
#   data/imports/
#     fidelity/
#       Portfolio_Positions_Apr-29-2026.json
#       Portfolio_Positions_May-06-2026.json
#       ...
#
# Usage:
#   ImportSnapshotStore.write(source: 'fidelity',
#                             basename: 'Portfolio_Positions_Apr-29-2026',
#                             data: parsed_hash)
#   ImportSnapshotStore.latest(source: 'fidelity')   # → snapshot hash or nil
#   ImportSnapshotStore.list(source: 'fidelity')     # → [{basename:, written_at:, ...}, ...]
#   ImportSnapshotStore.find_position('AAPL', source: 'fidelity')
#     # → broker row for AAPL from the most recent snapshot, or nil
#
# Tests redirect storage via `IMPORT_SNAPSHOT_DIR`.
module ImportSnapshotStore
  DEFAULT_DIR = File.expand_path('../../data/imports', __FILE__)
  MUTEX       = Mutex.new

  module_function

  def base_dir
    ENV['IMPORT_SNAPSHOT_DIR'] || DEFAULT_DIR
  end

  def source_dir(source)
    File.join(base_dir, source.to_s)
  end

  # Persist a parsed CSV result. Adds `written_at` so the latest-by-date
  # logic stays meaningful even when the source CSV has no date in its name.
  def write(source:, basename:, data:)
    raise ArgumentError, 'source required'   if source.to_s.strip.empty?
    raise ArgumentError, 'basename required' if basename.to_s.strip.empty?

    payload = data.merge(
      'source'     => source.to_s,
      'basename'   => basename.to_s,
      'written_at' => Time.now.utc.iso8601(3) # millisecond precision so back-to-back writes don't collide
    )

    MUTEX.synchronize do
      FileUtils.mkdir_p(source_dir(source))
      path = File.join(source_dir(source), "#{basename}.json")
      tmp  = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(deep_stringify(payload)))
      File.rename(tmp, path)
      payload['path'] = path
      payload
    end
  end

  # Most recent snapshot for `source`. "Most recent" means: the file whose
  # filename-encoded date is newest, falling back to mtime, falling back to
  # the recorded `written_at`. Returns the parsed hash with :path filled in,
  # or nil when no snapshot exists.
  def latest(source:)
    paths = Dir.glob(File.join(source_dir(source), '*.json'))
    return nil if paths.empty?

    chosen = paths.max_by { |p| [extract_date(p) || Date.new(0), File.mtime(p)] }
    read_path(chosen)
  end

  # Lightweight index of all snapshots for `source`, newest-first. Returns
  # `[{basename:, file_date:, written_at:, positions_count:, path:}, ...]`.
  def list(source:)
    Dir.glob(File.join(source_dir(source), '*.json')).map { |p|
      data = read_path(p) || {}
      {
        basename:        data['basename'] || File.basename(p, '.json'),
        file_date:       data['file_date'],
        written_at:      data['written_at'],
        positions_count: (data['positions'] || []).length,
        path:            p
      }
    }.sort_by { |h| h[:file_date].to_s }.reverse
  end

  # Convenience: find a single broker row for `symbol` in the latest snapshot.
  # Returns nil when no snapshot exists or the symbol isn't in it.
  def find_position(symbol, source:)
    snapshot = latest(source: source)
    return nil unless snapshot
    sym = symbol.to_s.upcase
    (snapshot['positions'] || []).find { |p| p['symbol']&.upcase == sym }
  end

  # --- internals -----------------------------------------------------------

  def read_path(path)
    return nil unless File.exist?(path)
    raw = File.read(path)
    return nil if raw.strip.empty?
    parsed = JSON.parse(raw)
    parsed['path'] = path
    parsed
  rescue JSON::ParserError
    nil
  end

  def extract_date(path)
    base = File.basename(path, '.json')
    if (m = base.match(/(\w{3})-(\d{2})-(\d{4})/))
      months = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
      idx    = months.index(m[1])
      return Date.new(m[3].to_i, idx + 1, m[2].to_i) if idx
    end
    nil
  rescue ArgumentError
    nil
  end

  # JSON.pretty_generate accepts symbols as keys but later parsers see them
  # as strings — normalize on the way in so reads are predictable.
  def deep_stringify(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
    when Array then obj.map { |v| deep_stringify(v) }
    when Date  then obj.iso8601
    when Time  then obj.utc.iso8601
    else obj
    end
  end
end
