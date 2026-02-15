# frozen_string_literal: true

require "minitest/autorun"
require "timeout"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require_relative "support/env_file"
require "livekit_realtime_sdk"
require_relative "support/fake_adapter"

EnvFile.load(File.expand_path("../.env", __dir__))
