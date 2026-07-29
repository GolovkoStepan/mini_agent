# frozen_string_literal: true

require "json"

module MiniAgent
  # Весь вывод в терминал.
  #
  # Поток вывода и признак TTY внедряются через конструктор: при tty: false
  # раскраска отключается, а спиннер вообще не запускает поток — благодаря
  # этому тесты детерминированы и не спят.
  class UI
    # Сколько строк вывода инструмента показывать пользователю.
    # Это ограничение ТОЛЬКО для читаемости консоли; лимит того, что уходит
    # в модель, живёт отдельно в Agent::MAX_TOOL_OUTPUT.
    PREVIEW_LINES = 10
    PREVIEW_CHARS = 500

    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    SPINNER_INTERVAL = 0.1

    def initialize(out: $stdout, tty: nil, spinner_interval: SPINNER_INTERVAL)
      @out = out
      @tty = tty.nil? ? out.respond_to?(:tty?) && out.tty? : tty
      @spinner_interval = spinner_interval
    end

    def tty? = @tty

    def puts(text = "")
      @out.puts(text)
    end

    def print(text)
      @out.print(text)
      @out.flush if @out.respond_to?(:flush)
    end

    def banner(text)
      width = [text.length + 6, 60].max
      puts("═" * width)
      puts("  #{text}")
      puts("═" * width)
    end

    def assistant(content, label: Messages::ASSISTANT)
      puts("\n🤖 #{paint(label, :bold, :green)}")
      puts("#{content}\n")
    end

    def warn(text)
      puts(paint(text, :yellow))
    end

    def error(text)
      puts(paint(text, :red))
    end

    def success(text)
      puts("✅ #{paint(text, :bold, :green)}")
    end

    def tool_call(name, arguments)
      puts("🔧 #{paint(Messages::TOOL_CALL, :bold, :blue)}#{paint(name, :bold)}")
      if name == Tools::Bash::NAME && arguments["command"]
        puts(format(Messages::COMMAND_LABEL, command: paint(arguments["command"], :yellow)))
      else
        puts(format(Messages::ARGS_LABEL, args: arguments.to_json))
      end
    end

    # Пользователю показываем усечённо — полный текст всё равно уходит модели.
    def tool_result(result)
      puts(paint(Messages::RESULT_LABEL, :bold))
      lines = result.lines
      truncated = result.length > PREVIEW_CHARS || lines.size > PREVIEW_LINES

      puts(paint(truncated ? Messages::OUTPUT_HEADER_TRUNCATED : Messages::OUTPUT_HEADER, :gray))
      lines.take(truncated ? PREVIEW_LINES : lines.size).each { |line| puts("   │ #{line.chomp}") }
      puts(paint(format(Messages::OUTPUT_ELLIPSIS, shown: PREVIEW_LINES, total: lines.size), :gray)) if truncated
      puts(paint(Messages::OUTPUT_FOOTER, :gray))
    end

    # Вне TTY поток не создаётся вообще: в логах и в тестах анимация не нужна,
    # а лишний поток — источник недетерминированности.
    def with_spinner
      return yield unless @tty

      stop = false
      thread = spawn_spinner { stop }
      begin
        yield
      ensure
        stop = true
        thread.join
        print("\r\e[K")
      end
    end

    private

    def spawn_spinner(&stopped)
      Thread.new do
        index = 0
        until stopped.call
          print("\r#{paint("#{Messages::THINKING}#{SPINNER_FRAMES[index % SPINNER_FRAMES.size]}", :bold, :cyan)}")
          index += 1
          sleep(@spinner_interval)
        end
      rescue IOError
        # Поток вывода закрыли — анимация больше не нужна.
        nil
      end
    end

    def paint(text, *styles)
      Color.paint(text, *styles, enabled: @tty)
    end
  end
end
