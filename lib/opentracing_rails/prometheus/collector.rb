require 'prometheus/client'

module OpenTracing
  module Rails
    module Prometheus

      NORM_RE = %r{[^A-Za-z0-9\-_/.]}
      NS_RE = %r{[.\-]/}

      METRICS_NAME_OPERATION = 'operations'.freeze
      METRICS_NAME_HTTP_REQUESTS = 'requests'.freeze
      METRICS_NAME_HTTP_REQUEST_LATENCY = 'request_latency'.freeze
      METRICS_NAME_HTTP_STATUS_CODES = 'http_requests'.freeze
      LABEL_PARENT_SERVICE_UNKNOWN = 'unknown'.freeze
      DEFAULT_NORMALIZE = ->(name) { name.gsub(Prometheus::NORM_RE, '-') }

      def self.metric_name(name, namespace = '')
        ns = ->(nm) { nm.gsub(Prometheus::NS_RE, '_') }

        if namespace.blank?
          ns.call(name)
        elsif name.blank?
          ns.call(namespace)
        else
          ns.call(namespace) + ':' + ns.call(name)
        end
      end

      def self.error_value(span)
        return nil unless span.tags.key?('error')

        error = span.tags['error']
        error.blank? || error.casecmp('false').zero? ? 'false' : 'true'
      end

      # Collects HTTP metrics from opentracing spans into prometheus metrics
      class HTTPMetrics
        def initialize(registry: ::Prometheus::Client.registry, namespace: "", normalize: DEFAULT_NORMALIZE)
          @namespace = namespace
          @normalize = normalize

          mn_req = metric_name(METRICS_NAME_HTTP_REQUESTS)
          @requests = registry.counter(mn_req, 'Counts the number of requests made distinguished by their endpoint and error status')

          mn_lat = metric_name(METRICS_NAME_HTTP_REQUEST_LATENCY)
          @latency = registry.histogram(mn_lat, 'Duration of HTTP requests in second distinguished by their endpoint and error status')

          mn_stat = metric_name(METRICS_NAME_HTTP_STATUS_CODES)
          @status_codes = registry.counter(mn_stat, 'Counts the responses distinguished by endpoint and status code bucket')
        end

        def record(span, duration)
          status_code = span.tags['http.status_code'].to_s.to_i
          sc = status_code/100

          endpoint = @normalize.call("HTTP #{span.operation_name} #{span.tags['http.url']}")
          span.operation_name = endpoint.blank? ? 'rails' : endpoint 
          endpoint = 'other' if endpoint.blank?
          err = Prometheus.error_value(span)

          mtags = tags(endpoint, err)

          @requests.increment(mtags)
          @latency.observe(mtags, duration)
          @status_codes.increment(endpoint: endpoint, status_code: "#{sc}xx") if sc >= 2 && sc <= 5
        end

        private

        def metric_name(name)
          Prometheus.metric_name(name, @namespace).to_sym
        end


        def tags(endpoint, err)
          {
            'endpoint': endpoint,
            'error': err
          }
        end
      end

      # Collector decorator for the default collector.
      # This collector adds metrics gathering for opentracing/jaeger spans
      class Collector
        def initialize(
          collector: ::Jaeger::Client::Collector.new,
          registry: ::Prometheus::Client.registry,
          namespace: '',
          normalize: DEFAULT_NORMALIZE
        )
          @collector = collector
          @namespace = namespace
          @http_metrics = HTTPMetrics.new(registry: registry, namespace: namespace, normalize: normalize)
          @operation_metrics = registry.histogram(:operation_duration_seconds, 'Duration of operations in second')
        end

        def send_span(span, end_time)
          duration = (end_time - span.start_time).to_f
          track_prometheus(span, duration)
          @collector.send_span(span, end_time)
        end

        def retrieve()
          @collector.retrieve
        end

        private

        def track_prometheus(span, duration)
          if http_server?(span)
            @http_metrics.record(span, duration)
          else
            @operation_metrics.observe(operation_tags(span), duration)
          end
        end

        def http_server?(span)
          span.tags['span.kind'] == 'server' &&
            (span.tags['http.url'].present? || span.tags['http.method'].present?)
        end

        def operation_tags(span)
          {
            'name': span.operation_name,
            'error': Prometheus.error_value(span)
          }
        end
      end
    end
  end
end
