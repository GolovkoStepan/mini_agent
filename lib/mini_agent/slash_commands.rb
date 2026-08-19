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

    # Команды, меняющие состояние сессии: здесь они не выполняются, а только
    # называются. Историей и выходом владеет Repl, а сворачивание вдобавок
    # идёт к модели — ни клиента, ни History у команд нет и заводить их тут
    # незачем.
    #
    # Таблицей, а не ветками case: эти команды объединяет то, что тело у них
    # пустое, и case из одних `then :symbol` — просто менее удобный способ
    # написать хеш. Печатающие команды остались в report ниже: там у каждой
    # есть что делать.
    VERDICTS = {
      "clear" => :clear,
      "compact" => :compact,
      "init" => :init,
      "plan" => :plan,
      "exit" => :exit,
      "quit" => :exit
    }.freeze

    # Список для /help. Разбор идёт case-ом ниже, и рассинхронизацию этих
    # двух мест ловит тест: каждое имя отсюда должно распознаваться.
    COMMANDS = {
      "help" => Messages::CMD_HELP,
      "clear" => Messages::CMD_CLEAR,
      "context" => Messages::CMD_CONTEXT,
      "compact" => Messages::CMD_COMPACT,
      "init" => Messages::CMD_INIT,
      "plan" => Messages::CMD_PLAN,
      "model" => Messages::CMD_MODEL,
      "tools" => Messages::CMD_TOOLS,
      "usage" => Messages::CMD_USAGE,
      "exit" => Messages::CMD_EXIT
    }.freeze

    # usage приходит извне (от Agent), а не заводится здесь: счётчик живёт
    # всю сессию, а команды пересоздаются вместе с Repl. По умолчанию пустой,
    # чтобы класс оставался самостоятельным в тестах.
    def initialize(config:, tools:, ui:, usage: Usage.new)
      @config = config
      @tools = tools
      @ui = ui
      @usage = usage
    end

    # Возвращает, что делать вызывающему: :task — отдать модели,
    # :handled — команда уже отработала, :clear — начать историю заново,
    # :compact — свернуть диалог, :init — описать проект, :plan — переключить
    # режим планирования, :exit — выйти из режима.
    #
    # conversation нужна тем командам, которые смотрят на историю (/context).
    # Передаётся аргументом, а не хранится в поле: владеет ею Repl, и она
    # там меняется — по /clear и /compact заводится новая. Поле пришлось бы
    # синхронизировать, и первый же пропущенный случай дал бы отчёт
    # по устаревшей истории, причём молча.
    def call(line, conversation: nil)
      text = line.to_s.strip
      return :exit if BARE_EXIT.include?(text.downcase)

      match = PATTERN.match(text)
      return :task unless match

      dispatch(match[1].downcase, conversation)
    end

    private

    def dispatch(name, conversation)
      VERDICTS[name] || report(name, conversation)
    end

    # Печатающие команды: всё, что они делают, происходит здесь и сейчас.
    def report(name, conversation)
      case name
      when "help" then help
      when "context" then context(conversation)
      when "model" then model
      when "tools" then tools
      when "usage" then usage
      else unknown(name)
      end
    end

    def context(conversation)
      return empty_context if conversation.nil?

      @ui.context(ContextReport.new(conversation, usage: @usage, config: @config))
      :handled
    end

    def empty_context
      @ui.puts(Messages::CMD_CONTEXT_EMPTY)
      :handled
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
      model_lines.each { |line| @ui.puts(line) }
      :handled
    end

    # Строки собираются списком, а не печатаются по одной: печать вперемешку
    # с шестью вызовами format перевалила порог Metrics/AbcSize, и делить
    # тут по смыслу нечего — это одна справка об одном запуске.
    def model_lines
      lines = [
        format(Messages::CMD_MODEL_LINE, model: @config.model),
        format(Messages::CMD_SERVER_LINE, url: @config.base_url),
        format(Messages::CMD_WINDOW_LINE, size: window_size),
        format(Messages::CMD_CWD_LINE, path: @config.cwd || Dir.pwd),
        format(Messages::CMD_POLICY_LINE, name: Messages::POLICY_NAMES.fetch(@config.policy)),
        format(Messages::CMD_SAMPLING_LINE, params: sampling)
      ]
      lines + optional_lines
    end

    # То, чего может не быть вовсе. Отдельно от обязательных строк не ради
    # порядка: два условия в общем списке перевалили Metrics/AbcSize.
    #
    # Файл настроек показывается только прочитанный: строка «настроек нет»
    # сообщала бы об отсутствии того, о чём не спрашивали. Зато прочитанный
    # назвать необходимо — значения из файла ничем не выдают своего
    # происхождения, и вопрос «почему модель не та» остаётся без ответа.
    def optional_lines
      lines = []
      lines << format(Messages::CMD_SETTINGS_LINE, path: @config.settings_path) if @config.settings_path
      lines << format(Messages::LOG_STARTED, path: @config.log) if @config.log
      lines
    end

    # Пустой сэмплинг — штатное состояние, а не отсутствие данных: агент
    # не задаёт ничего, и всё решает пресет сервера. Так и говорится, потому
    # что вопрос «а какая тогда температура» возникает сразу.
    def sampling
      params = @config.sampling
      return Messages::CMD_SAMPLING_SERVER if params.empty?

      params.map { |name, value| format(Messages::CMD_SAMPLING_PAIR, name: name, value: value) }.join(", ")
    end

    # Окно показывается рядом с моделью, а не только в /context: это её
    # свойство, заданное при загрузке, и спрашивают о нём тогда же, когда
    # о самой модели. Прочерк вместо числа — тот же принцип, что и везде:
    # незнание не выдаётся за ноль.
    def window_size
      size = @config.context_window
      size ? format(Messages::CMD_WINDOW_KNOWN, size: size) : Messages::CMD_WINDOW_UNKNOWN
    end

    def tools
      @ui.puts(Messages::CMD_TOOLS_HEADER)
      @tools.names.each { |name| @ui.puts(format(Messages::CMD_TOOL_LINE, name: name)) }
      :handled
    end

    # Нули до первого запроса выглядят как «модель ничего не потратила», хотя
    # на деле её ещё не спрашивали, — поэтому пустой счётчик говорит об этом
    # прямо, а не печатает три нуля.
    def usage
      return empty_usage if @usage.empty?

      @ui.puts(Messages::CMD_USAGE_HEADER)
      @ui.puts(format(Messages::CMD_USAGE_SENT, count: @usage.sent))
      @ui.puts(format(Messages::CMD_USAGE_GENERATED, count: @usage.generated))
      @ui.puts(format(Messages::CMD_USAGE_CONTEXT, count: @usage.context, requests: @usage.requests))
      :handled
    end

    def empty_usage
      @ui.puts(Messages::CMD_USAGE_EMPTY)
      :handled
    end

    def unknown(name)
      @ui.warn(format(Messages::CMD_UNKNOWN, name: name))
      :handled
    end
  end
end
