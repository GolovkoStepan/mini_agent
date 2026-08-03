# frozen_string_literal: true

require "net/http"
require "json"

module MiniAgent
  # Клиент OpenAI-совместимого эндпоинта chat/completions.
  class LLMClient
    # Ошибки сети, при которых имеет смысл повторить запрос.
    RETRIABLE = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError,
      IOError, EOFError
    ].freeze

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120

    def initialize(config:, ui: nil, sleeper: method(:sleep))
      @config = config
      @ui = ui
      @sleeper = sleeper
      @http = nil
      @retry_after = nil
    end

    # Держит одно соединение на всё время работы блока.
    def start
      uri = @config.chat_uri
      http = build_http(uri)
      http.start unless http.started?
      @http = http
      yield self
    ensure
      @http&.finish if @http&.started?
      @http = nil
    end

    # Возвращает [content, tool_calls, usage, finish_reason].
    #
    # usage — сырой хеш из ответа (`prompt_tokens`, `completion_tokens`) либо
    # nil: спецификация его не требует, и не всякий сервер присылает. Здесь он
    # не разбирается — учётом занимается Usage, клиенту это чужая забота.
    #
    # finish_reason отдаётся сырой строкой по той же причине: клиент сообщает
    # факт, а решает по нему Agent — обрыв на пустом ответе и обрыв на готовом
    # тексте требуют разного.
    #
    # tool_choice: "none" нужен для финального суммирующего запроса — иначе
    # модель может вернуть очередной вызов инструмента, который уже некуда
    # применить, и он будет молча потерян.
    def chat(messages, tools: [], tool_choice: "auto")
      body = payload(messages, tools, tool_choice).to_json
      last_error = nil

      @config.retry_count.times do |attempt|
        response = perform(body)
      rescue *RETRIABLE => e
        last_error = format(Messages::NETWORK_ERROR, message: e.message)
        pause
      rescue StandardError => e
        last_error = format(Messages::UNKNOWN_ERROR, message: e.message)
        pause
      else
        result = interpret(response, attempt)
        return result if result

        last_error = @last_reason
        pause
      end

      raise LLMError, format(Messages::LLM_FAILED, count: @config.retry_count, error: last_error)
    end

    # Список моделей, загруженных на сервере: массив имён. Сам запрос живёт
    # в ModelsRequest — это справочная команда без повторов, а не диалог.
    def models
      ModelsRequest.new(config: @config, http: connection).call
    end

    private

    # Запрос создаётся заново на каждой попытке: переиспользовать один объект
    # Net::HTTP::Post между повторами нельзя — после отправки он несёт в себе
    # состояние, и повтор может уйти с некорректным телом.
    def perform(body)
      request = Net::HTTP::Post.new(@config.chat_uri.path, headers)
      request.body = body

      with_spinner { connection.request(request) }
    end

    def headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@config.api_key}"
      }
    end

    def payload(messages, tools, tool_choice)
      body = {
        model: @config.model,
        messages: messages,
        temperature: 0.1,
        max_tokens: @config.max_tokens
      }
      unless tools.empty?
        body[:tools] = tools
        body[:tool_choice] = tool_choice
      end
      body
    end

    # nil означает «попытка неудачна, нужен повтор»; причина кладётся
    # в @last_reason, чтобы не плодить возвращаемых значений.
    #
    # Неповторяемый HTTP-код бросает LLMError прямо отсюда: возвращать nil
    # значило бы отправить запрос на повтор, а именно этого делать нельзя.
    def interpret(response, attempt)
      return handle_http_error(response, attempt) unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      message = extract_message(data)
      message && result(data, message)
    rescue JSON::ParserError => e
      @ui&.error(format(Messages::INVALID_JSON, message: e.message))
      @last_reason = format(Messages::INVALID_JSON, message: e.message)
      nil
    end

    def result(data, message) = ChatResponse.new(data, message).to_a

    # Повторяемый код — nil и обычный цикл повторов; неповторяемый — сразу
    # LLMError, чтобы не ждать retry_delay ради заведомо того же ответа.
    def handle_http_error(response, attempt)
      error = ErrorResponse.new(response)

      unless error.retriable?
        @ui&.error(format(Messages::HTTP_FATAL, code: error.code))
        raise LLMError, error.to_s
      end

      @ui&.error(format(Messages::HTTP_ERROR, code: error.code, attempt: attempt + 1))
      @last_reason = error.to_s
      @retry_after = error.retry_after
      nil
    end

    def extract_message(data)
      choices = data["choices"]
      unless choices.is_a?(Array) && !choices.empty?
        @ui&.error(Messages::INVALID_CHOICES)
        @last_reason = Messages::INVALID_CHOICES
        return nil
      end

      message = choices[0]["message"]
      unless message.is_a?(Hash)
        @ui&.error(Messages::EMPTY_MESSAGE)
        @last_reason = Messages::EMPTY_MESSAGE
        return nil
      end

      message
    end

    # Соединение поднимается лениво: в исходном скрипте вызов run без
    # предварительного start_http падал с NoMethodError на nil.
    def connection
      @http ||= build_http(@config.chat_uri) # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = @config.use_ssl?
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end

    def with_spinner(&)
      return yield unless @ui

      @ui.with_spinner(&)
    end

    # Retry-After от сервера перебивает настроенную задержку: он знает, когда
    # освободится, а мы только гадаем. Значение одноразовое — иначе задержка
    # от давнего 429 тянулась бы через все последующие повторы.
    def pause
      delay = @retry_after || @config.retry_delay
      @retry_after = nil
      @sleeper.call(delay) if delay.positive?
    end
  end
end
