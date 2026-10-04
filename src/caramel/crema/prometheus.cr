require "../version"
require "./sinks"
require "./runtime"

module Caramel::Crema
  # The Prometheus text exposition served at `/v1/metrics`. Labels hold route
  # templates, class names and statuses, never paths or messages.
  module Prometheus
    CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"
    BOUNDS       = Histogram::BOUNDS_MS.map { |bound| bound / 1000.0 }

    alias Labels = Hash(String, String)

    def self.write(io : IO, metrics : MetricSink, runtime : Runtime) : Nil
      traffic(io, metrics)
      process(io, runtime)
      pools(io, runtime)
    end

    # The families that count finished work: requests, jobs, schedules and errors.
    def self.traffic(io : IO, metrics : MetricSink) : Nil
      requests(io, metrics)
      jobs(io, metrics)
      schedules(io, metrics)
      errors(io, metrics)
    end

    private def self.requests(io : IO, metrics : MetricSink) : Nil
      family(io, "caramel_requests_total", "counter", "Requests finished, by route and status.")
      metrics.requests.each do |(method, route, status), count|
        sample(io, "caramel_requests_total", count,
          labels(method: method, route: route, status: status))
      end
      family(io, "caramel_request_duration_seconds", "histogram", "Request duration.")
      metrics.durations.each do |kind, key, entry|
        next unless kind == "request"

        method, _, route = key.partition(' ')
        histogram(io, "caramel_request_duration_seconds", entry.histogram,
          entry.total_ms / 1000.0, labels(method: method, route: route))
      end
    end

    private def self.jobs(io : IO, metrics : MetricSink) : Nil
      family(io, "caramel_jobs_total", "counter", "Job runs finished, by class and outcome.")
      outcomes(io, metrics, "job", "caramel_jobs_total")
      family(io, "caramel_job_duration_seconds", "histogram", "Job run duration.")
      metrics.durations.each do |kind, key, entry|
        next unless kind == "job"

        histogram(io, "caramel_job_duration_seconds", entry.histogram,
          entry.total_ms / 1000.0, labels(job: key))
      end
      family(io, "caramel_job_queue_lag_seconds", "histogram", "Time a job waited past its run_at.")
      metrics.lag.each do |queue, lag|
        histogram(io, "caramel_job_queue_lag_seconds", lag, 0.0, labels(queue: queue))
      end
    end

    private def self.schedules(io : IO, metrics : MetricSink) : Nil
      family(io, "caramel_schedules_total", "counter", "Schedule runs finished, by outcome.")
      outcomes(io, metrics, "schedule", "caramel_schedules_total")
    end

    # Job and schedule runs: the label is named for the kind.
    private def self.outcomes(io : IO, metrics : MetricSink, kind : String, name : String) : Nil
      metrics.outcomes.each do |(found, subject, outcome), count|
        next unless found == kind

        sample(io, name, count, {kind => subject, "outcome" => outcome})
      end
    end

    private def self.errors(io : IO, metrics : MetricSink) : Nil
      family(io, "caramel_errors_total", "counter", "Errors reported, by class.")
      metrics.errors.each do |error_class, count|
        sample(io, "caramel_errors_total", count, labels(error_class: error_class))
      end
    end

    private def self.process(io : IO, runtime : Runtime) : Nil
      family(io, "caramel_inflight", "gauge", "Requests, jobs and schedule runs in flight.")
      flights = Crema.in_flight.group_by(&.kind.wire)
      %w[request job schedule].each do |kind|
        sample(io, "caramel_inflight", flights[kind]?.try(&.size) || 0, labels(kind: kind))
      end
      stats = GC.stats
      gauge(io, "caramel_gc_heap_bytes", "Heap size.", stats.heap_size)
      gauge(io, "caramel_gc_free_bytes", "Free heap bytes.", stats.free_bytes)
      family(io, "caramel_gc_allocated_bytes_total", "counter", "Bytes allocated since start.")
      sample(io, "caramel_gc_allocated_bytes_total", stats.total_bytes)
      gauge(io, "caramel_fibers", "Fibers alive.", Crema.fiber_count)
      family(io, "caramel_crema_dropped_total", "counter", "Events a sink lost.")
      Crema.dropped.each do |sink, count|
        sample(io, "caramel_crema_dropped_total", count, labels(sink: sink))
      end
      family(io, "caramel_build_info", "gauge", "The application and framework versions.")
      sample(io, "caramel_build_info", 1, labels(app: runtime.app, caramel: Caramel::VERSION))
      gauge(io, "caramel_process_start_time_seconds", "Process start.", runtime.started_at.to_unix)
    end

    private def self.pools(io : IO, runtime : Runtime) : Nil
      pools = runtime.pools
      family(io, "caramel_db_pool_connections", "gauge", "Database pool connections, by state.")
      pools.each do |pool|
        counts = {"open" => pool.open, "idle" => pool.idle, "in_flight" => pool.in_flight}
        counts.each do |state, count|
          sample(io, "caramel_db_pool_connections", count, labels(pool: pool.name, state: state))
        end
      end
      family(io, "caramel_db_pool_max", "gauge", "Database pool size limit.")
      pools.each { |pool| sample(io, "caramel_db_pool_max", pool.max, labels(pool: pool.name)) }
    end

    private def self.labels(**pairs) : Labels
      pairs.to_h.transform_keys(&.to_s).transform_values(&.to_s)
    end

    private def self.family(io : IO, name : String, type : String, help : String) : Nil
      io << "# HELP " << name << ' ' << help << '\n'
      io << "# TYPE " << name << ' ' << type << '\n'
    end

    private def self.gauge(io : IO, name : String, help : String, value : Number) : Nil
      family(io, name, "gauge", help)
      sample(io, name, value)
    end

    private def self.sample(io : IO,
                            name : String,
                            value : Number,
                            labels : Labels = Labels.new) : Nil
      io << name
      unless labels.empty?
        io << '{'
        labels.each_with_index do |(key, label), index|
          io << ',' if index > 0
          io << key << "=\"" << escape(label) << '"'
        end
        io << '}'
      end
      io << ' ' << value << '\n'
    end

    # Cumulative buckets, then the sum and the count.
    private def self.histogram(io : IO, name : String, counts : Histogram, sum : Float64,
                               labels : Labels) : Nil
      running = 0_i64
      BOUNDS.each_with_index do |bound, index|
        running += counts.counts[index]
        sample(io, "#{name}_bucket", running, labels.merge({"le" => bound.to_s}))
      end
      sample(io, "#{name}_bucket", counts.total, labels.merge({"le" => "+Inf"}))
      sample(io, "#{name}_sum", sum, labels)
      sample(io, "#{name}_count", counts.total, labels)
    end

    private def self.escape(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n")
    end
  end
end
