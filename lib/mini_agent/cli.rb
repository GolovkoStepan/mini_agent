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
      [:retry_count, "--retry-count N", Integer, Messages::OPT_RETRY_COUNT],
      [:retry_delay, "--retry-delay N", Float, Messages::OPT_RETRY_DELAY],
      [:base_url, "--base-url URL", Messages::OPT_BASE_URL],
      [:model, "--model NAME", Messages::OPT_MODEL],
      [:allow_unsafe, "--[no-]allow-unsafe", Messages::OPT_ALLOW_UNSAFE],
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
    rescue Interrupt
      @out.puts(Messages::INTERRUPTED)
      EXIT_OK
    end

    private

    def run(options, args, parser)
      config = Config.new(options)
      ui = UI.new(out: @out)

      return with_connection(config, ui) { |agent| agent.interactive(input: @input) } if options[:interactive]

      task = args.join(" ").strip
      return usage(parser) if task.empty?

      with_connection(config, ui) { |agent| agent.run(task) }
    end

    # Соединение не открылось — показываем адрес и как его сменить вместо
    # сырого бэктрейса Net::HTTP.
    def with_connection(config, ui, &)
      with_agent(config, ui, &)
      EXIT_OK
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

    # Соединение с LLM живёт ровно столько, сколько работает агент.
    def with_agent(config, ui)
      client = LLMClient.new(config: config, ui: ui)
      tools = build_tools(config, ui)

      client.start do |connected|
        yield Agent.new(config: config, client: connected, tools: tools, ui: ui)
      end
    end

    def build_tools(config, ui)
      guard = CommandGuard.new(
        allow_unsafe: config.allow_unsafe?,
        prompt: Prompt.new(input: @input, output: @out),
        ui: ui
      )
      runner = ProcessRunner.new(timeout: config.timeout)
      ToolRegistry.new([Tools::Bash.new(guard: guard, runner: runner)])
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
