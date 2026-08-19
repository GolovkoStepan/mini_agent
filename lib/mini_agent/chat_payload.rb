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
    def initialize(config:, messages:, tools: [], tool_choice: "auto")
      @config = config
      @messages = messages
      @tools = tools
      @tool_choice = tool_choice
    end

    def to_json(*)
      body = base
      add_sampling(body)
      add_stream(body)
      add_tools(body)
      body.to_json
    end

    private

    def base
      {
        model: @config.model,
        messages: @messages,
        max_tokens: @config.max_tokens
      }
    end

    # Параметров сэмплинга здесь нет ни одного, пока их не задал человек, —
    # и это главное свойство тела запроса, а не мелочь оформления.
    #
    # Раньше тут стояла константа TEMPERATURE = 0.1, уходившая в каждый
    # запрос. Поле в теле перебивает пресет, загруженный на сервере, поэтому
    # выставленная там температура не применялась никогда, а понять это по
    # поведению было нельзя: агент работал, просто иначе, чем просили.
    # Что не названо явно — решает сервер; см. Sampling.
    def add_sampling(body) = body.merge!(@config.sampling)

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
