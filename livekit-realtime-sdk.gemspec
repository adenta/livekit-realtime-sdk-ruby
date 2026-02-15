# frozen_string_literal: true

require_relative "lib/livekit_realtime_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "livekit-realtime-sdk"
  spec.version = LiveKitRealtime::VERSION
  spec.authors = ["Midwest Dads"]
  spec.email = ["dev@midwestdads.dev"]

  spec.summary = "Ruby client for the LiveKit Realtime Go adapter"
  spec.description = "Thin Ruby SDK for session lifecycle and realtime data using a local Go adapter service."
  spec.homepage = "https://github.com/midwest-dads/livekit-realtime-sdk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob("{lib,test}/**/*") + %w[README.md livekit-realtime-sdk.gemspec]
  spec.require_paths = ["lib"]
end
