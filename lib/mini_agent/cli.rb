# frozen_string_literal: true

require "optparse"
require "net/http"
require "uri"

module MiniAgent
  # Разбор аргументов командной строки и сборка объектов агента.
  class CLI
    EXIT_OK = 0
    EXIT_USAGE = 1
    EXIT_CONNECT = 2
    # Соединение открылось, но запрос к модели провалился и задача не сделана.
    # Отдельно от EXIT_CONNECT: там сервера нет вовсе, здесь он ответил отказом
    # (например, HTTP 400 по переполненному контексту). Без этого кода агент
    # возвращал 0, ничего не выполнив, и скрипт-обёртка считал задачу успешной.
    EXIT_LLM = 3
    # Ходы кончились раньше задачи. Отдельно от EXIT_LLM: там запрос не удался
    # и делать было нечего, здесь всё работало исправно — просто не хватило
    # отведённых ходов, и лечение другое (--max-turns, а не сеть и не модель).
    # Обёртке разница нужна: первое стоит повторить, второе бессмысленно
    # повторять с теми же настройками.
    EXIT_UNFINISHED = 4

    # Исход задачи → код возврата. :ok в таблице нет намеренно: fetch с
    # умолчанием отвечает EXIT_OK и на него, и на любой исход, о котором
    # здесь ещё не знают, — новый признак у агента не должен ронять CLI.
    EXIT_CODES = { failed: EXIT_LLM, unfinished: EXIT_UNFINISHED }.freeze

    # Ошибки открытия соединения: сервер не отвечает, не запущен, недоступен.
    # Ловятся отдельно от ошибок самих запросов (те обрабатывает Agent#request),
    # потому что здесь агент ещё не стартовал и продолжать нечего.
    CONNECT_ERRORS = [
      Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ETIMEDOUT, SocketError
    ].freeze

    # Описание флагов таблицей: [ключ настроек, *аргументы OptionParser#on].
    # Значение флага кладётся в options под указанным ключом.
    FLAGS = [
      [:interactive, "-i", "--interactive", Messages::OPT_INTERACTIVE],
      [:max_turns, "--max-turns N", Integer, Messages::OPT_MAX_TURNS],
      [:max_tokens, "--max-tokens N", Integer, Messages::OPT_MAX_TOKENS],
      [:context_window, "--context-window N", Integer, Messages::OPT_CONTEXT_WINDOW],
      [:llm_timeout, "--llm-timeout N", Float, Messages::OPT_LLM_TIMEOUT],
      [:retry_count, "--retry-count N", Integer, Messages::OPT_RETRY_COUNT],
      [:retry_delay, "--retry-delay N", Float, Messages::OPT_RETRY_DELAY],
      [:base_url, "--base-url URL", Messages::OPT_BASE_URL],
      [:model, "--model NAME", Messages::OPT_MODEL],
      [:stream, "--[no-]stream", Messages::OPT_STREAM],
      [:auto_compact, "--[no-]auto-compact", Messages::OPT_AUTO_COMPACT],
      # Без типа Float намеренно: разбор и проверку диапазона делает Config,
      # и «--compact-at abc» обязано падать одним и тем же ConfigError
      # независимо от того, пришло значение флагом или из AUTO_COMPACT_AT.
      [:compact_at, "--compact-at N", Messages::OPT_COMPACT_AT],
      [:markdown, "--[no-]markdown", Messages::OPT_MARKDOWN],
      # Параметры сэмплинга. Умолчаний у них нет: не задано — не отправляем,
      # решает пресет сервера (см. Sampling).
      [:temperature, "--temperature N", Float, Messages::OPT_TEMPERATURE],
      [:top_p, "--top-p N", Float, Messages::OPT_TOP_P],
      [:top_k, "--top-k N", Integer, Messages::OPT_TOP_K],
      [:min_p, "--min-p N", Float, Messages::OPT_MIN_P],
      [:repeat_penalty, "--repeat-penalty N", Float, Messages::OPT_REPEAT_PENALTY],
      [:presence_penalty, "--presence-penalty N", Float, Messages::OPT_PRESENCE_PENALTY],
      [:frequency_penalty, "--frequency-penalty N", Float, Messages::OPT_FREQUENCY_PENALTY],
      [:seed, "--seed N", Integer, Messages::OPT_SEED],
      [:policy, "--policy NAME", Messages::OPT_POLICY],
      [:plan, "--plan", Messages::OPT_PLAN],
      [:allow_unsafe, "--[no-]allow-unsafe", Messages::OPT_ALLOW_UNSAFE],
      [:list_models, "--list-models", Messages::OPT_LIST_MODELS],
      [:cwd, "--cwd DIR", Messages::OPT_CWD],
      [:log, "--log FILE", Messages::OPT_LOG],
      # Два отдельных флага, а не --[no-]settings: у первого есть аргумент,
      # у второго его быть не может.
      [:settings, "--settings FILE", Messages::OPT_SETTINGS],
      [:no_settings, "--no-settings", Messages::OPT_NO_SETTINGS],
      [:help, "-h", "--help", Messages::OPT_HELP],
      [:version, "-v", "--version", Messages::OPT_VERSION]
    ].freeze

    def self.start(argv, out: $stdout, input: $stdin)
      new(out: out, input: input).start(argv)
    end

    def initialize(out: $stdout, input: $stdin)
      @out = out
      @input = input
    end

    def start(argv)
      options = {}
      @parser = build_parser(options)
      args = @parser.parse(argv.dup)

      return handle(:help, @parser) if options[:help]
      return handle(:version) if options[:version]

      run(options, args, @parser)
    rescue OptionParser::ParseError => e
      @out.puts(e.message)
      @out.puts(@parser)
      EXIT_USAGE
    # Настройки заданы неверно — например, опечатка в --cwd. Это ошибка
    # употребления, а не сбой связи, поэтому код 1, а не 2.
    rescue ConfigError => e
      @out.puts(e.message)
      EXIT_USAGE
    rescue Interrupt
      @out.puts(Messages::INTERRUPTED)
      EXIT_OK
    end

    private

    def run(options, args, parser)
      # Файл настроек читает CLI, а не Config: здесь обработка ConfigError,
      # а у Config тесты не должны начинать читать диск разработчика.
      config = Config.new(options, settings: Settings.from_options(options))
      ui = UI.new(out: @out, markdown: config.markdown?)

      return list_models(config, ui) if options[:list_models]
      return interactive(config, ui) if options[:interactive]

      task = args.join(" ").strip
      return usage(parser) if task.empty?

      with_connection(config, ui) do |agent|
        # Вопроса «выполнять?» при --plan нет намеренно: разовый запуск на то
        # и разовый, а согласие спрашивают в интерактивном режиме, где есть
        # у кого. Через Planner, а не run: план надо ещё сохранить в файл —
        # здесь он единственный продукт запуска и живёт до прокрутки буфера.
        config.plan? ? agent.plan(task, nil, confirm: false) : agent.run(task)
        EXIT_CODES.fetch(agent.outcome, EXIT_OK)
      end
    end

    # Файл настроек читает CLI, а не Config: здесь и флаги, и обработка
    # ConfigError. Оба флага сразу — отказ, а не угадывание: указания
    # противоречат друг другу и ни одно не точнее другого (прецедент
    # --policy asl — падать громко там, где выбор был бы выдуман).
    # Reline получает те же потоки, что и весь остальной ввод-вывод CLI:
    # он сам решит, включать ли себя, по признаку терминала у обоих.
    def interactive(config, ui)
      with_connection(config, ui) do |agent, tools|
        reader = LineReader.new(input: @input, output: @out)
        Repl.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader).run
        # Провал отдельной задачи — не провал сессии: код относится ко всему
        # сеансу, а пользователь ошибку уже увидел и мог продолжить работу.
        EXIT_OK
      end
    end

    # Код возврата приходит из блока: разовая задача отличает провал запроса
    # от успеха, интерактивный режим всегда отдаёт EXIT_OK.
    def with_connection(config, ui, &)
      connecting(config, ui) { with_agent(config, ui, &) }
    end

    # Соединение не открылось — показываем адрес и как его сменить вместо
    # сырого бэктрейса Net::HTTP.
    def connecting(config, ui)
      yield
    rescue *CONNECT_ERRORS => e
      ui.error(format(Messages::CONNECT_FAILED, url: config.base_url))
      ui.puts(format(Messages::CONNECT_REASON, message: e.message))
      ui.puts(Messages::CONNECT_HINT)
      EXIT_CONNECT
    rescue URI::InvalidURIError
      ui.error(format(Messages::INVALID_URL, url: config.base_url))
      ui.puts(Messages::INVALID_URL_HINT)
      EXIT_CONNECT
    end

    def list_models(config, ui)
      connecting(config, ui) { ModelsCommand.new(config: config, ui: ui).call }
    end

    # Сборка агента со всеми зависимостями живёт в AgentBuilder: здесь
    # остаётся командная строка — разбор аргументов и коды возврата.
    def with_agent(config, ui, &)
      AgentBuilder.new(config: config, ui: ui, input: @input, output: @out).call(&)
    end

    def handle(action, parser = nil)
      case action
      when :help then @out.puts(parser)
      when :version then @out.puts(MiniAgent::VERSION)
      end
      EXIT_OK
    end

    def usage(parser)
      @out.puts(format(Messages::HEADER, version: MiniAgent::VERSION))
      @out.puts(Messages::NO_TASK_HINT)
      @out.puts(Messages::NO_TASK_HINT2)
      @out.puts(parser)
      EXIT_USAGE
    end

    def build_parser(options)
      OptionParser.new do |opts|
        opts.banner = Messages::BANNER

        FLAGS.each do |key, *definition|
          opts.on(*definition) { |value| options[key] = value }
        end
      end
    end
  end
end
