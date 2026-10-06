require "spec"
require "../../../src/caramel"

private def finished(kind : Caramel::Crema::Kind,
                     name : String,
                     milliseconds : Int32,
                     status : Int32? = nil) : Caramel::Crema::Trace
  trace = Caramel::Crema::Trace.new(kind, name, "a" * 32, "b" * 16)
  trace.method, _, route = name.partition(' ')
  trace.route = route
  trace.status = status
  trace.finish(milliseconds.milliseconds)
  trace
end

describe Caramel::Crema::Prometheus do
  it "counts requests and jobs with their routes, statuses and durations" do
    metrics = Caramel::Crema::MetricSink.new
    metrics.finished(finished(Caramel::Crema::Kind::Request, "GET /books/:id", 3, 200))
    metrics.finished(finished(Caramel::Crema::Kind::Request, "GET /books/:id", 30, 200))
    job = finished(Caramel::Crema::Kind::Job, "App::Mail", 4)
    job.queue = "default"
    job.queue_lag = 2.milliseconds
    metrics.finished(job)
    output = String.build { |io| Caramel::Crema::Prometheus.traffic(io, metrics) }
    output.lines.reject(&.includes?("_bucket{")).join('\n').should eq(<<-TEXT)
      # HELP caramel_requests_total Requests finished, by route and status.
      # TYPE caramel_requests_total counter
      caramel_requests_total{method="GET",route="/books/:id",status="200"} 2
      # HELP caramel_request_duration_seconds Request duration.
      # TYPE caramel_request_duration_seconds histogram
      caramel_request_duration_seconds_sum{method="GET",route="/books/:id"} 0.033
      caramel_request_duration_seconds_count{method="GET",route="/books/:id"} 2
      # HELP caramel_jobs_total Job runs finished, by class and outcome.
      # TYPE caramel_jobs_total counter
      caramel_jobs_total{job="App::Mail",outcome="ok"} 1
      # HELP caramel_job_duration_seconds Job run duration.
      # TYPE caramel_job_duration_seconds histogram
      caramel_job_duration_seconds_sum{job="App::Mail"} 0.004
      caramel_job_duration_seconds_count{job="App::Mail"} 1
      # HELP caramel_job_queue_lag_seconds Time a job waited past its run_at.
      # TYPE caramel_job_queue_lag_seconds histogram
      caramel_job_queue_lag_seconds_sum{queue="default"} 0.002
      caramel_job_queue_lag_seconds_count{queue="default"} 1
      # HELP caramel_schedules_total Schedule runs finished, by outcome.
      # TYPE caramel_schedules_total counter
      # HELP caramel_errors_total Errors reported, by class.
      # TYPE caramel_errors_total counter
      TEXT
  end

  it "writes cumulative buckets that end at +Inf" do
    metrics = Caramel::Crema::MetricSink.new
    metrics.finished(finished(Caramel::Crema::Kind::Request, "GET /", 3, 200))
    metrics.finished(finished(Caramel::Crema::Kind::Request, "GET /", 30, 200))
    output = String.build { |io| Caramel::Crema::Prometheus.traffic(io, metrics) }
    buckets = output.lines.select(&.starts_with?("caramel_request_duration_seconds_bucket"))
    buckets.first.should eq(
      %(caramel_request_duration_seconds_bucket{method="GET",route="/",le="0.005"} 1))
    buckets.last.should eq(
      %(caramel_request_duration_seconds_bucket{method="GET",route="/",le="+Inf"} 2))
    buckets.size.should eq(12)
  end

  it "escapes label values" do
    metrics = Caramel::Crema::MetricSink.new
    metrics.finished(finished(Caramel::Crema::Kind::Request, %(GET /a"b\\c), 1, 404))
    output = String.build { |io| Caramel::Crema::Prometheus.traffic(io, metrics) }
    output.should contain(%(route="/a\\"b\\\\c"))
  end
end
