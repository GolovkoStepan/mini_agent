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
      [:policy, "--policy NAME", Messages::OPT_POLICY],
      [:allow_unsafe, "--[no-]allow-unsafe", Messages::OPT_ALLOW_UNSAFE],
      [:list_models, "--list-models", Messages::OPT_LIST_MODELS],
      [:cwd, "--cwd DIR", Messages::OPT_CWD],
      [:log, "--log FILE", Messages::OPT_LOG],
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
      config = Config.new(options)
      ui = UI.new(out: @out)

      return list_models(config, ui) if options[:list_models]
      return interactive(config, ui) if options[:interactive]

      task = args.join(" ").strip
      return usage(parser) if task.empty?

      with_connection(config, ui) do |agent|
        agent.run(task)
        EXIT_CODES.fetch(agent.outcome, EXIT_OK)
      end
    end

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
      @out.puts(format(Messages::NO_TASK_HEADER, version: MiniAgent::VERSION))
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
