require 'roda'
require 'json'

module Workbench
  class Server < Roda
    plugin :json

    class << self
      attr_accessor :workbench_config, :workbench_endpoints
    end

    route do |r|
      config    = self.class.workbench_config
      endpoints = self.class.workbench_endpoints

      # Authentication — all requests require a valid Bearer token
      unless authenticated?(config.server_api_key)
        response.status = 401
        next({ status: 'error', error: 'Unauthorized' })
      end

      dispatch_routes(r, endpoints, config.server_base_path)
    end

    private

    def authenticated?(api_key)
      return false if api_key.nil? || api_key.empty?
      request.env['HTTP_AUTHORIZATION'] == "Bearer #{api_key}"
    end

    def dispatch_routes(r, endpoints, base_path)
      base_segments = base_path&.delete_prefix('/')&.split('/') || []

      endpoints.each do |endpoint|
        path_segments = endpoint.route.delete_prefix('/').split('/')
        r.is(*(base_segments + path_segments)) do
          dispatch_endpoint(r, endpoint)
        end
      end

      nil # prevent the endpoints array from being used as the response body
    end

    def dispatch_endpoint(r, endpoint)
      verb = request.request_method
      method_config = endpoint.methods[verb]

      unless method_config
        response.status = 405
        return { status: 'error', error: "Method #{verb} not allowed" }
      end

      body, error = parse_json_body
      return error if error

      type   = method_config['pipeline'] ? 'pipeline' : 'task'
      target = method_config[type]

      pipeline = build_pipeline(type, target)
      pipeline.context.merge!(body.transform_keys(&:to_sym))
      pipeline.run

      { status: 'ok', type => target, outputs: pipeline.context }
    end

    # Returns [parsed_body, nil] on success or [nil, error_hash] on failure.
    def parse_json_body
      raw = request.body.read
      return [{}, nil] if raw.nil? || raw.empty?
      [JSON.parse(raw), nil]
    rescue JSON::ParserError
      response.status = 400
      [nil, { status: 'error', error: 'Invalid JSON body' }]
    end

    def build_pipeline(type, target)
      if type == 'pipeline'
        Pipeline.find(target) || Pipeline.lambda([target])
      else
        Pipeline.lambda([target])
      end
    end
  end
end
