# frozen_string_literal: true

module MiniAgent
  # Сборка агента со всеми его зависимостями на время одного запуска.
  #
  # Отдельно от CLI намеренно: там осталось то, что связано с командной
  # строкой, — разбор аргументов, коды возврата, справка. Здесь другое:
  # какие объекты нужны агенту и в каком порядке их создавать. CLI перерос
  # Metrics/ClassLength ровно тогда, когда к сборке добавился журнал, и
  # это оказалось верным сигналом — задача действительно чужая.
  class AgentBuilder
    def initialize(config:, ui:, input: $stdin, output: $stdout)
      @config = config
      @ui = ui
      @input = input
      @output = output
    end

    # Отдаёт блоку собранного агента и реестр инструментов. Соединение с LLM
    # и файл журнала живут ровно столько, сколько выполняется блок.
    def call
      log = transcript
      detect_window
      client = LLMClient.new(config: @config, ui: @ui)
      tools = build_tools

      client.start do |connected|
        yield build_agent(connected, tools, log), tools
      end
    ensure
      log&.close
    end

    private

    # Размер контекстного окна: спрашиваем сервер, если человек не указал его
    # сам. Заданное явно не перепроверяется — оно перебивает угаданное, и
    # лишний запрос тут ничего бы не решил, только задержал старт.
    #
    # Молча: проба необязательна, а её неудача — обычное дело на любом
    # сервере, кроме LM Studio. Узнанное видно в /context и /usage, там же
    # видно и незнание — строкой о том, что размер окна неизвестен.
    def detect_window
      return if @config.context_window

      @config.context_window = WindowProbe.new(config: @config).call
    end

    # Подтверждение перезаписи в /init спрашивается тем же объектом, что и
    # согласие на опасную команду: два разных Prompt на одних и тех же
    # потоках разошлись бы при первой же подмене ввода в тестах.
    def build_agent(client, tools, log)
      history = History.new(project_context: project_context, transcript: log)
      Agent.new(config: @config, client: client, tools: tools, ui: @ui, history: history, prompt: prompt)
    end

    def prompt
      @prompt ||= Prompt.new(input: @input, output: @output)
    end

    # О включённом журнале сообщаем строкой в выводе — по той же причине, что
    # и о подхваченном AGENTS.md: в файл уходят задачи и содержимое всего, что
    # агент прочитал, и молчать о том, что запись идёт, нельзя.
    def transcript
      return nil unless @config.log

      log = Transcript.new(@config.log, ui: @ui)
      log.session(@config)
      @ui.puts(format(Messages::LOG_STARTED, path: @config.log))
      log
    end

    # О подхваченном описании проекта сообщаем: молчаливое изменение поведения
    # агента хуже лишней строки в выводе — иначе непонятно, откуда он вдруг
    # знает про принятые в проекте команды.
    # Описание ищется в рабочем каталоге агента, а не в том, откуда его
    # запустили: с --cwd это разные места, и читать описание одного проекта,
    # работая в другом, — худшее из возможных поведений.
    def project_context
      loader = ProjectContext.new(@config.cwd || Dir.pwd)
      content = loader.load
      @ui.puts(format(Messages::CONTEXT_LOADED, name: loader.filename)) if content

      content
    end

    def build_tools
      guard = CommandGuard.new(
        allow_unsafe: @config.allow_unsafe?,
        prompt: prompt,
        ui: @ui
      )
      runner = ProcessRunner.new(timeout: @config.timeout, cwd: @config.cwd)
      ToolRegistry.new([Tools::Bash.new(guard: guard, runner: runner)])
    end
  end
end
