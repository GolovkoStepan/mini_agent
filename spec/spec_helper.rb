# frozen_string_literal: true

require "mini_agent"

# Оценочные задачи (evals/) в гем не входят и своим путём загрузки с lib/
# не связаны. Путь добавляется здесь, чтобы их спеки шли тем же `make spec`:
# отдельный прогон завёл бы вторую команду проверки, о которой забывают.
$LOAD_PATH.unshift(File.expand_path("../evals/lib", __dir__))
require "evals"

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

  # Настоящий ~/.mini_agent/settings.json не участвует в тестах: CLI читает
  # его сам, и на машине, где файл есть, полсотни примеров cli_spec молча
  # работали бы с чужой моделью и чужой политикой. Тот же довод, по которому
  # Config принимает env: явно, — только окружение можно передать, а путь
  # файла зашит в константу. Примеры, которым файл нужен, называют его сами.
  config.before do
    stub_const("MiniAgent::Settings::PATH", File.join(Dir.tmpdir, "mini_agent_нет_настроек.json"))
  end
end

# Тесты не должны зависеть от переменных окружения разработчика, поэтому
# MiniAgent::Config принимает env: явно — в примерах всегда передаём свой хеш.
