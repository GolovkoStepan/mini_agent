# frozen_string_literal: true

module MiniAgent
  # Команды интерактивного режима: /help, /clear, /model, /tools.
  #
  # Всё, что не распознано как команда, уходит модели обычной задачей —
  # решение принимается здесь, а Repl только исполняет вердикт.
  class SlashCommands
    # Команда — это одно слово со слэшем и ничего больше. Путь командой
    # не считается: задача «покажи, что лежит в /usr/bin» иначе превратилась
    # бы в сообщение о неизвестной команде вместо работы.
    #
    # [[:word:]], а не \w: тот в Ruby ограничен ASCII, и опечатка кириллицей
    # («/помощь») уходила бы модели задачей вместо подсказки про /help.
    PATTERN = %r{\A/([[:word:]]+)\z}

    # Выход без слэша поддержан отдельно: до появления команд это был
    # единственный способ выйти, и он наверняка остался в пальцах.
    BARE_EXIT = %w[exit quit].freeze

    # Список для /help. Разбор идёт case-ом ниже, и рассинхронизацию этих
    # двух мест ловит тест: каждое имя отсюда должно распознаваться.
    COMMANDS = {
      "help" => Messages::CMD_HELP,
      "clear" => Messages::CMD_CLEAR,
      "model" => Messages::CMD_MODEL,
      "tools" => Messages::CMD_TOOLS,
      "exit" => Messages::CMD_EXIT
    }.freeze

    def initialize(config:, tools:, ui:)
      @config = config
      @tools = tools
      @ui = ui
    end

    # Возвращает, что делать вызывающему: :task — отдать модели,
    # :handled — команда уже отработала, :clear — начать историю заново,
    # :exit — выйти из режима.
    def call(line)
      text = line.to_s.strip
      return :exit if BARE_EXIT.include?(text.downcase)

      match = PATTERN.match(text)
      return :task unless match

      dispatch(match[1].downcase)
    end

    private

    def dispatch(name)
      case name
      when "help" then help
      when "clear" then :clear
      when "model" then model
      when "tools" then tools
      when "exit", "quit" then :exit
      else unknown(name)
      end
    end

    def help
      @ui.puts(Messages::CMD_HELP_HEADER)
      COMMANDS.each { |name, summary| @ui.puts(format(Messages::CMD_HELP_LINE, name: name, summary: summary)) }
      :handled
    end

    # Показывается и каталог: с --cwd агент работает не там, откуда запущен,
    # и это ровно то, что забывается за время диалога. Журнал — по той же
    # причине: строка о нём печатается один раз при запуске и уезжает вверх,
    # а пишется он всю сессию.
    def model
      @ui.puts(format(Messages::CMD_MODEL_LINE, model: @config.model))
      @ui.puts(format(Messages::CMD_SERVER_LINE, url: @config.base_url))
      @ui.puts(format(Messages::CMD_CWD_LINE, path: @config.cwd || Dir.pwd))
      @ui.puts(format(Messages::LOG_STARTED, path: @config.log)) if @config.log
      :handled
    end

    def tools
      @ui.puts(Messages::CMD_TOOLS_HEADER)
      @tools.names.each { |name| @ui.puts(format(Messages::CMD_TOOL_LINE, name: name)) }
      :handled
    end

    def unknown(name)
      @ui.warn(format(Messages::CMD_UNKNOWN, name: name))
      :handled
    end
  end
end
