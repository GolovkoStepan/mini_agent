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
    DEFAULTS = {
      base_url: "http://192.168.1.70:1234/v1",
      api_key: "lm-studio",
      model: "qwen/qwen3.6-35b-a3b",
      max_turns: 10,
      retry_count: 3,
      retry_delay: 2,
      max_tokens: 4096,
      allow_unsafe: false,
      timeout: 120
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
      timeout: "COMMAND_TIMEOUT"
    }.freeze

    attr_reader :base_url, :api_key, :model, :max_turns,
                :retry_count, :retry_delay, :max_tokens, :timeout

    def initialize(options = {}, env: ENV)
      @options = options
      @env = env

      @base_url = fetch(:base_url).to_s.sub(%r{/+\z}, "")
      @api_key = fetch(:api_key).to_s
      @model = fetch(:model).to_s
      @max_turns = fetch(:max_turns).to_i
      @retry_count = fetch(:retry_count).to_i
      @retry_delay = fetch(:retry_delay).to_f
      @max_tokens = fetch(:max_tokens).to_i
      @timeout = fetch(:timeout).to_f
      @allow_unsafe = to_bool(fetch(:allow_unsafe))
    end

    def allow_unsafe?
      @allow_unsafe
    end

    def chat_uri
      URI.parse("#{@base_url}/chat/completions")
    end

    def use_ssl?
      chat_uri.scheme == "https"
    end

    private

    # options.key? вместо проверки на истинность: иначе явное false
    # (флаг --no-allow-unsafe) не смогло бы перебить ALLOW_UNSAFE=true.
    def fetch(key)
      return @options[key] if @options.key?(key) && !@options[key].nil?

      env_value = @env[ENV_KEYS.fetch(key)]
      return env_value unless env_value.nil? || env_value.empty?

      DEFAULTS.fetch(key)
    end

    def to_bool(value)
      case value
      when true, false then value
      else %w[true 1 yes].include?(value.to_s.strip.downcase)
      end
    end
  end
end
