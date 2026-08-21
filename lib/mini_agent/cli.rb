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

    def self.start(argv, out: $stdout, input: $stdin, reader: nil)
      new(out: out, input: input, reader: reader).start(argv)
    end

    # reader внедряется ради тестов: он отвечает сразу на два вопроса —
    # открывать ли интерактивный режим без задачи и как читать строку, —
    # и подменить признак терминала у настоящих потоков иначе нельзя,
    # не втащив Reline в тесты (см. LineReader).
    def initialize(out: $stdout, input: $stdin, reader: nil)
      @out = out
      @input = input
      @reader = reader
    end

    def start(argv)
      flags = Options.new
      @parser = flags.parser
      args = flags.parse(argv)
      options = flags.values

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

      # Журнал читается до соединения: продолжать нечего — значит и ходить
      # к серверу незачем, а ConfigError отсюда доходит до start и печатает
      # причину без бэктрейса.
      replay = restore(options, config)
      task = args.join(" ").strip
      return interactive(config, ui, replay) if options[:interactive] || conversational?(task)
      return usage(parser) if task.empty?

      single_task(config, ui, replay, task)
    end

    # Задачи нет — открываем диалог, но только на терминале. Безусловный
    # интерактив выглядит удобнее ровно до первого скрипта с `mini_agent
    # "$TASK"`, где переменная по ошибке пуста: REPL стартует, первый же
    # gets возвращает EOF, сессия закрывается — и агент, не сделав ничего,
    # выходит с нулём. Тот же худший исход, ради невозможности которого
    # заведены EXIT_UNFINISHED и отказ пустого --resume: молчаливый успех
    # неотличим от настоящего до тех пор, пока не понадобится результат.
    # Вне терминала остаётся прежний громкий отказ с подсказкой.
    #
    # Явный -i этой проверки не проходит намеренно: он и раньше работал
    # в пайпе, им пользуются скрипты, и отнимать это молча незачем.
    def conversational?(task) = task.empty? && reader.interactive?

    # Один на весь запуск: признак терминала и чтение строк — один и тот же
    # вопрос к одним и тем же потокам, и второй объект разошёлся бы с первым.
    def reader = @reader ||= LineReader.new(input: @input, output: @out)

    # Разовый запуск. Вопроса «выполнять?» при --plan нет намеренно: разовый
    # запуск на то и разовый, а согласие спрашивают в интерактивном режиме,
    # где есть у кого. Через Planner, а не run: план надо ещё сохранить в
    # файл — здесь он единственный продукт запуска и живёт до прокрутки буфера.
    def single_task(config, ui, replay, task)
      with_connection(config, ui, resume: replay&.path) do |agent|
        conversation = resumed(replay, agent, ui)
        config.plan? ? agent.plan(task, conversation, confirm: false) : agent.run(task, conversation: conversation)
        EXIT_CODES.fetch(agent.outcome, EXIT_OK)
      end
    end

    # Журнал продолжаемой сессии либо nil, если --resume не задавали. Файл
    # берётся из --log, а при его отсутствии — последняя сессия каталога.
    #
    # Отсутствие сессии — отказ, а не молчаливый старт с чистого листа:
    # попросили продолжить, и «продолжили пустую историю» неотличимо от
    # «продолжили нужную» ровно до того момента, когда модель ответит
    # не о том (тот же довод, что у --settings с несуществующим файлом).
    def restore(options, config)
      return nil unless options[:resume]

      path = config.log || SessionStore.new.latest(config.cwd || Dir.pwd)
      raise ConfigError, Messages::RESUME_NONE unless path

      replay = Replay.new(path)
      raise ConfigError, format(Messages::RESUME_EMPTY, path: path) if replay.empty?

      replay
    rescue SystemCallError, IOError => e
      raise ConfigError, format(Messages::RESUME_UNREADABLE, path: path, message: e.message)
    end

    # Восстановленная история либо nil. Сообщений в ней столько, сколько
    # осталось после откатов и сворачиваний, — это и печатается: имя файла
    # состоит из даты и каталога, и по нему одному не видно, то ли продолжили.
    def resumed(replay, agent, ui)
      return nil unless replay

      conversation = replay.into(agent.new_conversation)
      count = Plural.with(replay.messages.size, *Messages::MESSAGES_WORD)
      ui.puts(format(Messages::RESUMED, path: replay.path, messages: count))
      ui.warn(format(Messages::RESUME_BROKEN, count: replay.broken)) if replay.broken.positive?
      conversation
    end

    # Файл настроек читает CLI, а не Config: здесь и флаги, и обработка
    # ConfigError. Оба флага сразу — отказ, а не угадывание: указания
    # противоречат друг другу и ни одно не точнее другого (прецедент
    # --policy asl — падать громко там, где выбор был бы выдуман).
    # Reline получает те же потоки, что и весь остальной ввод-вывод CLI:
    # он сам решит, включать ли себя, по признаку терминала у обоих.
    def interactive(config, ui, replay = nil)
      with_connection(config, ui, resume: replay&.path) do |agent, tools|
        Repl.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader,
                 conversation: resumed(replay, agent, ui)).run
        # Провал отдельной задачи — не провал сессии: код относится ко всему
        # сеансу, а пользователь ошибку уже увидел и мог продолжить работу.
        EXIT_OK
      end
    end

    # Код возврата приходит из блока: разовая задача отличает провал запроса
    # от успеха, интерактивный режим всегда отдаёт EXIT_OK.
    def with_connection(config, ui, resume: nil, &)
      connecting(config, ui) { with_agent(config, ui, resume, &) }
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
    # resume — журнал продолжаемой сессии: запись идёт в него же, а не в новый
    # файл. Иначе история копилась бы в одном файле, а продолжение писалось бы
    # в другой, и «последняя сессия каталога» указывала бы то на одну, то на
    # другую половину одного разговора.
    def with_agent(config, ui, resume, &)
      AgentBuilder.new(config: config, ui: ui, input: @input, output: @out, resume: resume).call(&)
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
  end
end
