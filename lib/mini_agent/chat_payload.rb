# frozen_string_literal: true

module MiniAgent
  # Тело запроса к /chat/completions.
  #
  # Отдельно от LLMClient потому, что это знание о ФОРМАТЕ протокола, а не о
  # диалоге с сервером: какие поля кладутся, какие условны, что означает
  # stream_options. Клиент остался тем, чем был, — отправкой, повторами и
  # разбором результата. Порог Metrics/ClassLength указал на это в шестой раз
  # (до того из клиента так выделились ErrorResponse и ChatResponse).
  class ChatPayload
    TEMPERATURE = 0.1

    def initialize(config:, messages:, tools: [], tool_choice: "auto")
      @config = config
      @messages = messages
      @tools = tools
      @tool_choice = tool_choice
    end

    def to_json(*)
      body = base
      add_stream(body)
      add_tools(body)
      body.to_json
    end

    private

    def base
      {
        model: @config.model,
        messages: @messages,
        temperature: TEMPERATURE,
        max_tokens: @config.max_tokens
      }
    end

    # include_usage обязателен: без него сервер не присылает usage в потоке
    # вовсе (проверено на LM Studio — ни одного куска с этим полем), и
    # /usage с /context в потоковом режиме молча показывали бы нули.
    def add_stream(body)
      return unless @config.stream?

      body[:stream] = true
      body[:stream_options] = { include_usage: true }
    end

    # tool_choice: "none" нужен для финального суммирующего запроса — иначе
    # модель возвращает очередной вызов, применить который уже негде.
    def add_tools(body)
      return if @tools.empty?

      body[:tools] = @tools
      body[:tool_choice] = @tool_choice
    end
  end
end
