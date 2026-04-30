require 'time'

# RefreshTracker — in-memory state for long-running background refresh jobs.
#
# A "refresh-all" run iterates 500+ symbols and can take 30+ minutes once
# Polygon's 13s/call throttle kicks in. We can't block the admin POST on
# that; instead we spawn a Thread, register a state row here, and the
# /admin/cache view polls `current` to render a progress banner.
#
# In-memory only (per-process). A Puma worker recycle clears the tracker —
# acceptable since the actual refresh state lives on disk via the cache
# files; the tracker just makes "in progress" visible.
module RefreshTracker
  STATES = %w[running completed failed cancelled].freeze
  MUTEX  = Mutex.new

  @jobs = {}

  module_function

  # Register a new job by name. Returns the initial state hash. If a job
  # of the same name is already running, raises so callers can show "busy".
  def start!(name, total: nil)
    MUTEX.synchronize do
      existing = @jobs[name]
      if existing && existing[:status] == 'running'
        raise "refresh '#{name}' already running (started #{existing[:started_at].iso8601})"
      end
      @jobs[name] = {
        name:         name,
        status:       'running',
        started_at:   Time.now,
        completed_at: nil,
        total:        total,
        done:         0,
        last_symbol:  nil,
        errors:       []
      }
    end
  end

  # Atomic merge into the named job's state. Silently no-ops if the job
  # isn't registered.
  def update(name, **kwargs)
    MUTEX.synchronize do
      job = @jobs[name]
      next nil unless job
      job.merge!(kwargs)
    end
  end

  # Increment done by 1 and optionally record the latest symbol processed.
  def tick(name, last_symbol: nil)
    MUTEX.synchronize do
      job = @jobs[name]
      next nil unless job
      job[:done] += 1
      job[:last_symbol] = last_symbol if last_symbol
      job
    end
  end

  def record_error(name, symbol, error)
    MUTEX.synchronize do
      job = @jobs[name]
      next nil unless job
      job[:errors] << { symbol: symbol, error: error.to_s.slice(0, 200), at: Time.now.iso8601 }
      job[:errors] = job[:errors].last(50) # bound memory
      job
    end
  end

  def complete!(name, ok: true)
    MUTEX.synchronize do
      job = @jobs[name]
      next nil unless job
      job[:status]       = ok ? 'completed' : 'failed'
      job[:completed_at] = Time.now
      job
    end
  end

  def current(name)
    MUTEX.synchronize { @jobs[name]&.dup }
  end

  def all
    MUTEX.synchronize { @jobs.transform_values(&:dup) }
  end

  def running?(name)
    s = current(name)
    s && s[:status] == 'running'
  end

  # Test helper.
  def reset!
    MUTEX.synchronize { @jobs.clear }
  end
end
