# frozen_string_literal: true

module EnvFile
  module_function

  def load(path)
    return unless File.exist?(path)

    File.readlines(path, chomp: true).each do |line|
      raw = line.strip
      next if raw.empty? || raw.start_with?("#")

      key, value = raw.split("=", 2)
      next if key.nil? || value.nil?

      ENV[key] = value if ENV[key].nil? || ENV[key].empty?
    end
  end
end
