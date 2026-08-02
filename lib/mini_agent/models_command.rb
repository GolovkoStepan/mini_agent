# frozen_string_literal: true

module MiniAgent
  # Команда `--list-models`: показать модели, загруженные на сервере.
  #
  # Нужна потому, что умолчание Config::DEFAULTS[:model] совпадает
  # с загруженной моделью далеко не всегда, а LM Studio на незнакомое имя
  # не отвечает ошибкой — он молча подставляет свою, и подмену нечем заметить.
  #
  # Отдельно от CLI: там разбор аргументов и сборка зависимостей, а здесь своя
  # ветка выполнения со своим выводом и своей обработкой ошибок. Держать её
  # в CLI значило упирать его в Metrics/ClassLength ради одной команды.
  class ModelsCommand
    def initialize(config:, ui:)
      @config = config
      @ui = ui
    end

    # Возвращает код возврата процесса.
    def call
      names = LLMClient.new(config: @config, ui: @ui).start(&:models)

      if names.empty?
        @ui.warn(format(Messages::NO_MODELS, url: @config.base_url))
      else
        @ui.models(names, selected: @config.model, url: @config.base_url)
      end
      CLI::EXIT_OK
    rescue LLMError => e
      @ui.error(e.message)
      CLI::EXIT_CONNECT
    end
  end
end
