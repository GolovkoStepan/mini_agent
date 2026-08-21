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
    # resume — журнал продолжаемой сессии либо nil. Запись идёт в него же:
    # новый файл развёл бы один разговор по двум сессиям каталога.
    def initialize(config:, ui:, input: $stdin, output: $stdout, resume: nil)
      @config = config
      @ui = ui
      @input = input
      @output = output
      @resume = resume
    end

    # Отдаёт блоку собранного агента и реестр инструментов. Соединение с LLM
    # и файл журнала живут ровно столько, сколько выполняется блок.
    def call
      log = transcript
      detect_window
      # Журнал уходит и клиенту: размышления модели приходят в ответе и
      # в историю не попадают, так что записать их больше неоткуда.
      client = LLMClient.new(config: @config, ui: @ui, transcript: log)
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
      # Каталог тот же, что уходит в chdir: ProcessRunner (см. build_tools):
      # промпт обязан называть место, где команды выполняются на самом деле,
      # иначе он врёт убедительнее, чем молчит.
      history = History.new(project_context: project_context, transcript: log, cwd: @config.cwd || Dir.pwd)
      Agent.new(config: @config, client: client, tools: tools, ui: @ui, history: history, prompt: prompt,
                plan_mode: plan_mode)
    end

    def prompt
      @prompt ||= Prompt.new(input: @input, output: @output)
    end

    # Один объект на агента, охрану команд и Repl. Держать по своему у каждого
    # значило бы включённый режим, о котором не знает охрана: /plan переключал
    # бы одно состояние, а команды проверялись бы по другому — и планирование
    # молча выполняло бы всё подряд.
    def plan_mode
      @plan_mode ||= PlanMode.new(enabled: @config.plan?)
    end

    # О включённом журнале сообщаем строкой в выводе — по той же причине, что
    # и о подхваченном AGENTS.md: в файл уходят задачи и содержимое всего, что
    # агент прочитал, и молчать о том, что запись идёт, нельзя.
    #
    # Названный файл перебивает сохранение сессии: писать одно и то же
    # в два места незачем, а --resume читает любой журнал одинаково.
    def transcript
      return open_log(@config.log, Messages::LOG_STARTED) if @config.log
      return nil unless @config.session?

      session_log
    end

    # Сессия сохраняется сама, поэтому её неудача не должна ронять запуск:
    # ни каталог без прав, ни полный диск не повод не начинать задачу.
    # С названным файлом наоборот — там ConfigError из Transcript доходит
    # до CLI, потому что о файле просили явно (прецедент --settings).
    def session_log
      # Молча: продолжаемый файл CLI назовёт строкой «Продолжаем сессию»,
      # и вторая строка про тот же путь была бы шумом. Умолчать о записи
      # это не даёт — путь на экране всё равно есть.
      return open_log(@resume, nil) if @resume

      store = SessionStore.new
      path = store.path(@config.cwd || Dir.pwd)
      return warn_session(store.error) unless path

      open_log(path, Messages::SESSION_STARTED)
    rescue ConfigError => e
      warn_session(e.message)
    end

    def warn_session(message)
      @ui.warn(format(Messages::SESSION_FAILED, message: message))
      nil
    end

    def open_log(path, announcement)
      log = Transcript.new(path, ui: @ui)
      log.session(@config)
      @ui.puts(format(announcement, path: path)) if announcement
      log
    end

    # О подхваченном описании проекта сообщаем: молчаливое изменение поведения
    # агента хуже лишней строки в выводе — иначе непонятно, откуда он вдруг
    # знает про принятые в проекте команды.
    # Описание ищется в рабочем каталоге агента, а не в том, откуда его
    # запустили: с --cwd это разные места, и читать описание одного проекта,
    # работая в другом, — худшее из возможных поведений.
    #
    # Размер окна к этому времени уже спрошен у сервера (detect_window выше
    # по коду call) — порядок обязателен: описание, урезанное по одному лишь
    # потолку в знаках, всё ещё способно не влезть в маленькое окно.
    def project_context
      loader = ProjectContext.new(@config.cwd || Dir.pwd, window: @config.context_window)
      content = loader.load
      return content unless content

      @ui.puts(format(Messages::CONTEXT_LOADED, name: loader.filename))
      warn_truncated(loader)
      content
    end

    # Урезанное описание — это молчаливая потеря знаний о проекте: агент
    # просто не упомянет того, чего не читал, и понять это по его поведению
    # нельзя. Лечение называется тут же, потому что оно неочевидно, и берётся
    # по причине обрезки: окно и потолок лечатся по-разному (см. Messages).
    def warn_truncated(loader)
      return unless loader.truncated?

      text = loader.limited_by == :window ? Messages::CONTEXT_CUT_WINDOW : Messages::CONTEXT_CUT_CEILING
      @ui.warn(format(text, kept: loader.kept, total: Plural.with(loader.total, *Messages::CHARS)))
    end

    # Охрана одна на все инструменты, и каталог у файловых тот же, что уходит
    # в chdir: ProcessRunner. Разойдись они — `ls` показывал бы один каталог,
    # а read_file читал бы из другого, и заметить это можно было бы только
    # по содержимому файлов.
    def build_tools
      guard = CommandGuard.new(policy: @config.policy, prompt: prompt, ui: @ui, plan_mode: plan_mode)
      runner = ProcessRunner.new(timeout: @config.timeout, cwd: @config.cwd)
      cwd = @config.cwd || Dir.pwd
      ToolRegistry.new([Tools::Bash.new(guard: guard, runner: runner),
                        Tools::ReadFile.new(guard: guard, cwd: cwd),
                        Tools::WriteFile.new(guard: guard, cwd: cwd),
                        Tools::EditFile.new(guard: guard, cwd: cwd)])
    end
  end
end
