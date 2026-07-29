# frozen_string_literal: true

require "mini_agent"
require "webmock/rspec"
require "stringio"
require "tmpdir"
require "fileutils"

# Ни один тест не должен ходить в сеть: клиент LLM всегда стабится.
WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# Тесты не должны зависеть от переменных окружения разработчика, поэтому
# MiniAgent::Config принимает env: явно — в примерах всегда передаём свой хеш.
