# frozen_string_literal: true

module LiveKitRealtime
  class Error < StandardError; end
  class TimeoutError < Error; end
  class ConnectionError < Error; end

  class HTTPError < Error
    attr_reader :status

    def initialize(status:, message:)
      @status = status
      super(message)
    end
  end

  class BadRequestError < HTTPError; end
  class AuthError < HTTPError; end
  class NotFoundError < HTTPError; end
  class AdapterError < HTTPError; end
end
