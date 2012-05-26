require 'vcr/util/version_checker'
require 'vcr/request_handler'
require 'webmock'

VCR::VersionChecker.new('WebMock', WebMock.version, '1.8.0', '1.8').check_version!

module VCR
  class LibraryHooks
    # @private
    module WebMock
      # @private
      module Helpers
        def vcr_request_for(webmock_request)
          VCR::Request.new \
            webmock_request.method,
            webmock_request.uri.to_s,
            webmock_request.body,
            request_headers_for(webmock_request)
        end

        # @private
        def vcr_response_for(webmock_response)
          VCR::Response.new \
            VCR::ResponseStatus.new(*webmock_response.status),
            webmock_response.headers,
            webmock_response.body,
            nil
        end

        if defined?(::Excon)
          # @private
          def request_headers_for(webmock_request)
            return nil unless webmock_request.headers

            # WebMock hooks deeply into a Excon at a place where it manually adds a "Host"
            # header, but this isn't a header we actually care to store...
            webmock_request.headers.dup.tap do |headers|
              headers.delete("Host")
            end
          end
        else
          # @private
          def request_headers_for(webmock_request)
            webmock_request.headers
          end
        end

        def typed_request_for(webmock_request, remove = false)
          if webmock_request.instance_variables.include?(:@__typed_vcr_request)
            meth = remove ? :remove_instance_variable : :instance_variable_get
            return webmock_request.send(meth, :@__typed_vcr_request)
          end

          warn <<-EOS.gsub(/^\s+\|/, '')
            |WARNING: There appears to be a bug in WebMock's after_request hook
            |         and VCR is attempting to work around it. Some VCR features
            |         may not work properly.
          EOS

          Request::Typed.new(vcr_request_for(webmock_request), :unknown)
        end
      end

      class RequestHandler < ::VCR::RequestHandler
        include Helpers

        attr_reader :request
        def initialize(request)
          @request = request
        end

      private

        def set_typed_request_for_after_hook(*args)
          super
          request.instance_variable_set(:@__typed_vcr_request, @after_hook_typed_request)
        end

        def vcr_request
          @vcr_request ||= vcr_request_for(request)
        end

        def on_unhandled_request
          invoke_after_request_hook(nil)
          super
        end

        def on_stubbed_request
          {
            :body    => stubbed_response.body,
            :status  => [stubbed_response.status.code.to_i, stubbed_response.status.message],
            :headers => stubbed_response.headers
          }
        end
      end

      extend Helpers

      ::WebMock.globally_stub_request { |req| RequestHandler.new(req).handle }

      ::WebMock.after_request(:real_requests_only => true) do |request, response|
        unless VCR.library_hooks.disabled?(:webmock)
          http_interaction = VCR::HTTPInteraction.new \
            typed_request_for(request), vcr_response_for(response)

          VCR.record_http_interaction(http_interaction)
        end
      end

      ::WebMock.after_request do |request, response|
        unless VCR.library_hooks.disabled?(:webmock)
          VCR.configuration.invoke_hook \
            :after_http_request,
            typed_request_for(request, :remove),
            vcr_response_for(response)
        end
      end
    end
  end
end

# @private
module WebMock
  class << self
    # ensure HTTP requests are always allowed; VCR takes care of disallowing
    # them at the appropriate times in its hook
    def net_connect_allowed_with_vcr?(*args)
      VCR.turned_on? ? true : net_connect_allowed_without_vcr?(*args)
    end

    alias net_connect_allowed_without_vcr? net_connect_allowed?
    alias net_connect_allowed? net_connect_allowed_with_vcr?
  end unless respond_to?(:net_connect_allowed_with_vcr?)
end

