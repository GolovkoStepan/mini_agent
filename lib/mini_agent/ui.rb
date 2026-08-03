# frozen_string_literal: true

require "json"

module MiniAgent
  # Весь вывод в терминал.
  #
  # Иерархия держится на маркере, отступе и цвете, а не на рамках: каждое
  # событие начинается с BULLET, вывод инструмента уходит под BRANCH с
  # отступом. Рамки и баннеры не используются намеренно — они занимают
  # больше места, чем несут смысла, и разъезжаются на узком терминале.
  #
  # Поток вывода и признак TTY внедряются через конструктор: при tty: false
  # раскраска отключается, а спиннер вообще не запускает поток — благодаря
  # этому тесты детерминированы и не спят.
  class UI
    # Сколько строк вывода инструмента показывать пользователю.
    # Это ограничение ТОЛЬКО для читаемости консоли; лимит того, что уходит
    # в модель, живёт отдельно в Agent::MAX_TOOL_OUTPUT.
    PREVIEW_LINES = 5
    PREVIEW_CHARS = 500

    BULLET = "●"
    BRANCH = "⎿"
    INDENT = "    "

    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    SPINNER_INTERVAL = 0.1

    # Строка состояния для спиннера (например, «ход 2/10»). Меняется на
    # каждой итерации цикла, поэтому передаётся присваиванием, а не через
    # конструктор: объект UI один на всю сессию.
    attr_writer :status

    def initialize(out: $stdout, tty: nil, spinner_interval: SPINNER_INTERVAL)
      @out = out
      @tty = tty.nil? ? out.respond_to?(:tty?) && out.tty? : tty
      @spinner_interval = spinner_interval
      @status = nil
    end

    def tty? = @tty

    def puts(text = "")
      @out.puts(text)
    end

    def print(text)
      @out.print(text)
      @out.flush if @out.respond_to?(:flush)
    end

    def assistant(content)
      puts("\n#{paint(BULLET, :green)} #{content}")
    end

    def warn(text)
      puts("#{paint(BULLET, :yellow)} #{text}")
    end

    def error(text)
      puts("#{paint(BULLET, :red)} #{text}")
    end

    # Заголовок вида «● Bash(ls -la lib)»: имя инструмента с заглавной,
    # аргумент в скобках. Для bash в скобках сама команда, для прочих —
    # компактный JSON.
    def tool_call(name, arguments)
      argument = if name == Tools::Bash::NAME && arguments["command"]
                   arguments["command"]
                 else
                   arguments.to_json
                 end

      puts("\n#{paint(BULLET, :blue)} #{paint(name.capitalize, :bold)}(#{argument})")
    end

    # Пользователю показываем усечённо — полный текст всё равно уходит модели.
    def tool_result(result)
      code, body = split_exit_code(result)
      # Пустой stdout при непустом stderr оставляет ведущий перевод строки:
      # для модели это разделитель секций, а на экране — пустая строка.
      # Режем только переводы строк: пробелы в начале несут выравнивание
      # колонок (вывод wc, ls), и strip его бы поломал.
      lines = body.gsub(/\A\n+|\n+\z/, "").lines
      shown = preview(lines)

      puts("  #{paint(BRANCH, :gray)} #{exit_code_label(code)}") if code&.positive?
      shown.each_with_index { |line, index| puts(prefix(index, code) + paint(line.chomp, :gray)) }
      print_ellipsis(lines.size - shown.size)
    end

    # Разбивка контекста по категориям (/context).
    #
    # Знаки и токены разделены пустой строкой намеренно: первые посчитаны
    # здесь и точны, второе — то, что сообщил сервер. Смешивать измеренное
    # с полученным извне в одной таблице значит выдавать их за однородные.
    def context(report)
      return puts(Messages::CMD_CONTEXT_EMPTY) if report.empty?

      puts(format(Messages::CMD_CONTEXT_HEADER, count: Plural.with(report.messages, *Messages::MESSAGES_WORD)))
      puts("")
      report.sizes.each { |name, size| context_line(name, size, report.share(name)) }
      puts(Messages::CMD_CONTEXT_RULE)
      puts(format(Messages::CMD_CONTEXT_TOTAL, name: Messages::CMD_CONTEXT_TOTAL_NAME, size: chars(report.total)))
      puts("")
      context_tokens(report)
      warn(Messages::CMD_CONTEXT_FIXED) if report.project_dominates?
    end

    # Список моделей сервера с пометкой выбранной: ради этого сравнения
    # команду обычно и запускают.
    def models(names, selected:, url:)
      puts(format(Messages::MODELS_HEADER, url: url))
      names.each do |name|
        marker = name == selected ? Messages::MODEL_SELECTED : Messages::MODEL_PLAIN
        puts(format(marker, name: name))
      end
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

    def context_line(name, size, share)
      label = Messages::CMD_CONTEXT_NAMES.fetch(name, name.to_s)
      puts(format(Messages::CMD_CONTEXT_LINE, name: label, size: chars(size), share: share))
    end

    def chars(count) = Plural.with(count, *Messages::CHARS)

    # Отсутствие числа и ноль — разные вещи: сервер мог не прислать usage
    # вовсе, и промолчать об этом честнее, чем показать «0 токенов».
    def context_tokens(report)
      tokens = report.tokens
      return puts(paint(Messages::CMD_CONTEXT_NO_TOKENS, :gray)) if tokens.nil?

      text = format(Messages::CMD_CONTEXT_TOKENS, count: Plural.with(tokens, *Messages::TOKENS))
      puts(paint(text, :gray))
    end

    # Первая строка результата — «Код выхода: N» от Tools::Bash. Человеку
    # она нужна только когда команда упала, поэтому отрезаем её от тела и
    # показываем отдельной пометкой лишь при ненулевом коде.
    def split_exit_code(result)
      match = Messages::EXIT_CODE_PATTERN.match(result)
      return [nil, result] unless match

      [match[1].to_i, match.post_match]
    end

    def print_ellipsis(hidden)
      return unless hidden.positive?

      text = format(Messages::OUTPUT_ELLIPSIS, count: Plural.with(hidden, *Messages::LINES))
      puts(INDENT + paint(text, :gray))
    end

    def exit_code_label(code)
      paint(format(Messages::EXIT_CODE_LABEL, code: code), :red)
    end

    def preview(lines)
      return lines unless lines.sum(&:length) > PREVIEW_CHARS || lines.size > PREVIEW_LINES

      lines.take(PREVIEW_LINES)
    end

    # Ветка BRANCH ставится один раз — у первой строки блока. Если пометка
    # кода выхода уже её заняла, тело идёт ровным отступом.
    def prefix(index, code)
      return INDENT unless index.zero? && !code&.positive?

      "  #{paint(BRANCH, :gray)} "
    end

    def spawn_spinner(&stopped)
      Thread.new do
        index = 0
        until stopped.call
          print("\r#{paint("#{SPINNER_FRAMES[index % SPINNER_FRAMES.size]} #{spinner_text}", :cyan)}")
          index += 1
          sleep(@spinner_interval)
        end
      rescue IOError
        # Поток вывода закрыли — анимация больше не нужна.
        nil
      end
    end

    def spinner_text
      [Messages::THINKING, @status].compact.join(" ")
    end

    def paint(text, *styles)
      Color.paint(text, *styles, enabled: @tty)
    end
  end
end
