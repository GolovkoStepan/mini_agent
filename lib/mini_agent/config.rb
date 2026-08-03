# frozen_string_literal: true

require "uri"

module MiniAgent
  # Настройки агента.
  #
  # Единое правило приоритета: options (CLI) → ENV → значение по умолчанию.
  # В исходном скрипте правило было непоследовательным: base_url/api_key/model
  # читались только из ENV и молча игнорировали переданные опции, а max_turns и
  # соседние — учитывали оба источника.
  class Config
    # Умолчание указывает на имя llm-server, а не на localhost: сервер часто
    # стоит на отдельной машине. Имя разрешается через /etc/hosts — см. README,
    # раздел «Установка». Односоставное имя без домена выбрано намеренно:
    # зону .local на macOS перехватывает mDNSResponder, и записи в /etc/hosts
    # там срабатывают ненадёжно.
    DEFAULTS = {
      base_url: "http://llm-server:1234/v1",
      api_key: "lm-studio",
      model: "qwen/qwen3.6-35b-a3b",
      max_turns: 10,
      retry_count: 3,
      retry_delay: 2,
      max_tokens: 4096,
      # nil, а не число: размер контекстного окна задаётся при загрузке модели
      # на сервере, OpenAI-совместимый протокол его не сообщает, и любое
      # умолчание здесь было бы выдумкой. Не знаем — так и говорим; спросить
      # сервер пробует WindowProbe.
      context_window: nil,
      # Политика подтверждений. Умолчание — :deny (спрашивать только по
      # денилисту): агента зовут работать, и на задаче вида «запусти тесты»
      # строгая политика превращает её в череду подтверждений. Строгую
      # включают осознанно, а не получают по умолчанию.
      policy: :deny,
      allow_unsafe: false,
      timeout: 120,
      # Ожидание ответа модели. 120 секунд не хватало: на bonsai-27b (Q1_0,
      # рассуждающая) «17*23» заняло 347 секунд, а вопрос на три абзаца —
      # 176 при скорости ~5,7 токена/с. Агент падал с Net::ReadTimeout, хотя
      # модель работала и почти успевала. Замерено, а не взято с запасом:
      # на такой скорости 600 секунд — это ~3400 токенов, то есть меньше
      # умолчания max_tokens, и на длинной задаче лимит упрётся снова.
      #
      # Отдельно от timeout — тот про команды bash. Одно число на две разные
      # вещи означало бы, что правка ради медленной модели молча продлевает
      # и ожидание зависшей команды.
      llm_timeout: 600,
      # nil, а не Dir.pwd: умолчания замораживаются при загрузке файла, а
      # текущий каталог к моменту создания Config может быть уже другим.
      cwd: nil,
      # Журнал по умолчанию выключен: в нём оседают и задачи, и содержимое
      # файлов, которые агент читал. Включать такое молча нельзя.
      log: nil
    }.freeze

    ENV_KEYS = {
      base_url: "LLM_BASE_URL",
      api_key: "LLM_API_KEY",
      model: "LLM_MODEL",
      max_turns: "MAX_TURNS",
      retry_count: "RETRY_COUNT",
      retry_delay: "RETRY_DELAY",
      max_tokens: "MAX_TOKENS",
      context_window: "CONTEXT_WINDOW",
      llm_timeout: "LLM_TIMEOUT",
      policy: "AGENT_POLICY",
      allow_unsafe: "ALLOW_UNSAFE",
      timeout: "COMMAND_TIMEOUT",
      cwd: "AGENT_CWD",
      log: "AGENT_LOG"
    }.freeze

    attr_reader :base_url, :api_key, :model, :max_turns,
                :retry_count, :retry_delay, :max_tokens, :timeout, :llm_timeout, :policy, :cwd, :log

    # Размер контекстного окна: число или nil, если он неизвестен.
    #
    # Записываемо намеренно — значение может прийти от сервера уже после
    # создания настроек (WindowProbe спрашивает его при старте соединения).
    # Держать «узнанное» отдельным полем в третьем месте значило бы завести
    # два источника одного и того же числа.
    attr_accessor :context_window

    def initialize(options = {}, env: ENV)
      @options = options
      @env = env

      read_connection
      read_limits
      @policy = read_policy
      @cwd = expand_cwd(fetch(:cwd))
      @log = expand_log(fetch(:log))
    end

    # Отдельного поля под этот признак нет: он и есть одна из политик.
    # Держать рядом булев флаг и политику значило бы завести два источника
    # одного решения — и первое же расхождение («allow_unsafe: true, но
    # policy: :ask») пришлось бы разрешать угадыванием.
    def allow_unsafe?
      @policy == :unsafe
    end

    def chat_uri
      URI.parse("#{@base_url}/chat/completions")
    end

    def models_uri
      URI.parse("#{@base_url}/models")
    end

    def use_ssl?
      chat_uri.scheme == "https"
    end

    private

    # Адрес и учётные данные сервера.
    def read_connection
      @base_url = fetch(:base_url).to_s.sub(%r{/+\z}, "")
      @api_key = fetch(:api_key).to_s
      @model = fetch(:model).to_s
    end

    # Числовые ограничения: ходы, повторы, токены, таймаут.
    def read_limits
      @max_turns = fetch(:max_turns).to_i
      @retry_count = fetch(:retry_count).to_i
      @retry_delay = fetch(:retry_delay).to_f
      @max_tokens = fetch(:max_tokens).to_i
      @timeout = fetch(:timeout).to_f
      @llm_timeout = fetch(:llm_timeout).to_f
      @context_window = positive_or_nil(fetch(:context_window))
    end

    # Ноль и мусор («--context-window abc») означают то же, что и отсутствие
    # значения: размер окна неизвестен. Превращать их в 0 нельзя — тогда
    # «неизвестно» стало бы неотличимо от «окно нулевого размера», и всё,
    # что считает доли от окна, поделило бы на ноль.
    def positive_or_nil(value)
      return nil if value.nil?

      number = value.to_i
      number.positive? ? number : nil
    end

    # Политика подтверждений с учётом старого флага --allow-unsafe.
    #
    # Тот оставлен работать: он описан в README, живёт в чужих скриптах и
    # означает ровно одну из политик. Явно названная политика его перебивает —
    # иначе `--policy ask --allow-unsafe` разрешалось бы угадыванием, а из
    # двух указаний верить надо более точному.
    def read_policy
      return :unsafe if to_bool(fetch(:allow_unsafe)) && !given?(:policy)

      value = fetch(:policy).to_s.strip.downcase.to_sym
      return value if CommandGuard::POLICIES.include?(value)

      raise ConfigError, format(Messages::UNKNOWN_POLICY, value: fetch(:policy),
                                                          known: CommandGuard::POLICIES.join(", "))
    end

    # Значение задано человеком, а не взято из умолчаний. Отличать нужно
    # только политике: она сталкивается со вторым указанием того же смысла.
    def given?(key)
      return true if @options.key?(key) && !@options[key].nil?

      value = @env[ENV_KEYS.fetch(key)]
      !(value.nil? || value.empty?)
    end

    # options.key? вместо проверки на истинность: иначе явное false
    # (флаг --no-allow-unsafe) не смогло бы перебить ALLOW_UNSAFE=true.
    def fetch(key)
      return @options[key] if @options.key?(key) && !@options[key].nil?

      env_value = @env[ENV_KEYS.fetch(key)]
      return env_value unless env_value.nil? || env_value.empty?

      DEFAULTS.fetch(key)
    end

    # Каталог проверяется здесь, а не при первом запуске команды: иначе опечатка
    # в пути всплывёт посреди работы невнятной ошибкой от Open3, уже после
    # запроса к модели. Развёрнутый путь — чтобы `--cwd .` и `~/проект`
    # попадали в вывод в понятном человеку виде.
    def expand_cwd(value)
      return nil if value.nil? || value.to_s.empty?

      path = File.expand_path(value.to_s)
      raise ConfigError, format(Messages::CWD_NOT_FOUND, path: path) unless File.directory?(path)

      path
    end

    # Путь журнала разворачивается относительно каталога запуска, а не --cwd:
    # `--log session.jsonl` человек пишет там, где стоит сам, и искать файл
    # он пойдёт туда же, даже если команды агента выполняются в другом месте.
    #
    # Каталог проверяется здесь по той же причине, что и для --cwd: иначе
    # опечатка в пути всплывёт после первого же запроса к модели, когда
    # писать станет некуда, а платить за запрос уже пришлось.
    def expand_log(value)
      return nil if value.nil? || value.to_s.empty?

      path = File.expand_path(value.to_s)
      dir = File.dirname(path)
      raise ConfigError, format(Messages::LOG_DIR_NOT_FOUND, path: dir) unless File.directory?(dir)

      path
    end

    def to_bool(value)
      case value
      when true, false then value
      else %w[true 1 yes].include?(value.to_s.strip.downcase)
      end
    end
  end
end
