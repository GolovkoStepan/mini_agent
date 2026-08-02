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
      allow_unsafe: false,
      timeout: 120,
      # nil, а не Dir.pwd: умолчания замораживаются при загрузке файла, а
      # текущий каталог к моменту создания Config может быть уже другим.
      cwd: nil
    }.freeze

    ENV_KEYS = {
      base_url: "LLM_BASE_URL",
      api_key: "LLM_API_KEY",
      model: "LLM_MODEL",
      max_turns: "MAX_TURNS",
      retry_count: "RETRY_COUNT",
      retry_delay: "RETRY_DELAY",
      max_tokens: "MAX_TOKENS",
      allow_unsafe: "ALLOW_UNSAFE",
      timeout: "COMMAND_TIMEOUT",
      cwd: "AGENT_CWD"
    }.freeze

    attr_reader :base_url, :api_key, :model, :max_turns,
                :retry_count, :retry_delay, :max_tokens, :timeout, :cwd

    def initialize(options = {}, env: ENV)
      @options = options
      @env = env

      read_connection
      read_limits
      @allow_unsafe = to_bool(fetch(:allow_unsafe))
      @cwd = expand_cwd(fetch(:cwd))
    end

    def allow_unsafe?
      @allow_unsafe
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

    def to_bool(value)
      case value
      when true, false then value
      else %w[true 1 yes].include?(value.to_s.strip.downcase)
      end
    end
  end
end
