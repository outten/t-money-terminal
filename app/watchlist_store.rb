require 'json'
require 'fileutils'

# WatchlistStore — file-backed single-user watchlist persisted at
# `data/watchlist.json`.
#
# The store is deliberately simple: an ordered, deduped array of uppercased
# symbols. All mutating calls acquire an in-process mutex so concurrent Sinatra
# requests (Puma under MRI) can't interleave writes. For a multi-user rebuild
# this would move to SQLite or Redis — out of scope for now.
module WatchlistStore
  DEFAULT_PATH = File.expand_path('../../data/watchlist.json', __FILE__)
  MUTEX        = Mutex.new

  module_function

  def path
    ENV['WATCHLIST_PATH'] || DEFAULT_PATH
  end

  # Returns the watchlist as an array of uppercase symbols, or [] if empty/missing.
  def read
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed.map { |s| s.to_s.upcase } : []
  rescue JSON::ParserError
    []
  end

  # Add a symbol. Returns the full updated list. No-op if already present.
  def add(symbol)
    sym = symbol.to_s.strip.upcase
    return read if sym.empty?
    MUTEX.synchronize do
      list = read_unlocked
      list = (list + [sym]).uniq
      write_unlocked(list)
      list
    end
  end

  # Remove a symbol. Returns the full updated list.
  def remove(symbol)
    sym = symbol.to_s.strip.upcase
    MUTEX.synchronize do
      list = read_unlocked - [sym]
      write_unlocked(list)
      list
    end
  end

  def include?(symbol)
    read.include?(symbol.to_s.upcase)
  end

  # --- internals -----------------------------------------------------------

  def read_unlocked
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed.map { |s| s.to_s.upcase } : []
  rescue JSON::ParserError
    []
  end

  def write_unlocked(list)
    FileUtils.mkdir_p(File.dirname(path))
    # Atomic write: serialize to a sibling file then rename, so an interrupted
    # write can't leave a half-written JSON file on disk.
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(list))
    File.rename(tmp, path)
  end
end
