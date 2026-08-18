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

    # transcript — журнал, и попадает он сюда, а не только в Conversation,
    # ради размышлений модели: те приходят в ответе, но в историю не идут
    # никогда, так что другого места, где их видно, попросту нет.
    def initialize(config:, ui: nil, sleeper: method(:sleep), transcript: nil)
      @config = config
      @ui = ui
      @sleeper = sleeper
      @transcript = transcript
      @http = nil
      @retry_after = nil
      @stream = nil
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
    #
    # visible: false — ответ служебный и на экран при стриминге не идёт
    # (см. StreamRequest). Отдельным признаком, а не выводом из
    # tool_choice: совпадение этих двух условий сегодня случайно, и первый
    # же служебный запрос с инструментами развёл бы их молча.
    def chat(messages, tools: [], tool_choice: "auto", visible: true)
      @visible = visible
      body = ChatPayload.new(config: @config, messages: messages, tools: tools, tool_choice: tool_choice).to_json

      attempts(body)
    end

    # Список моделей, загруженных на сервере: массив имён. Сам запрос живёт
    # в ModelsRequest — это справочная команда без повторов, а не диалог.
    def models
      ModelsRequest.new(config: @config, http: connection).call
    end

    private

    # Цикл повторов. Отделён от chat не ради метрики, а потому, что это
    # разные вещи: там — что именно спросить у сервера, здесь — сколько раз
    # и с какими паузами пытаться.
    def attempts(body)
      last_error = nil

      @config.retry_count.times do |attempt|
        response = perform(body)
      rescue *RETRIABLE => e
        timed_out if e.is_a?(Net::ReadTimeout)
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

    # Единственная ошибка из RETRIABLE, которую повторять незачем: модель
    # не успела, и ещё два таких же ожидания дадут то же самое — при лимите
    # в 600 с это полчаса молчания. Про формулировку см. TIMEOUT_ERROR.
    def timed_out
      raise LLMError, format(Messages::TIMEOUT_ERROR, limit: @config.llm_timeout)
    end

    # Запрос создаётся заново на каждой попытке: переиспользовать один объект
    # Net::HTTP::Post между повторами нельзя — после отправки он несёт в себе
    # состояние, и повтор может уйти с некорректным телом.
    def perform(body)
      request = Net::HTTP::Post.new(@config.chat_uri.path, headers)
      request.body = body

      return stream(request) if @config.stream?

      @stream = nil
      with_spinner { connection.request(request) }
    end

    # Потоковый ответ разбирается по мере чтения, поэтому к моменту возврата
    # он уже собран: interpret возьмёт его из @stream вместо разбора тела.
    # Ответ всё равно возвращается — по нему определяется код HTTP, и ветка
    # ошибок остаётся общей для обоих режимов.
    def stream(request)
      response, parser = StreamRequest.new(http: connection, ui: @ui, visible: @visible).call(request)
      @stream = parser
      response
    end

    def headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@config.api_key}"
      }
    end

    # nil означает «попытка неудачна, нужен повтор»; причина кладётся
    # в @last_reason, чтобы не плодить возвращаемых значений.
    #
    # Неповторяемый HTTP-код бросает LLMError прямо отсюда: возвращать nil
    # значило бы отправить запрос на повтор, а именно этого делать нельзя.
    def interpret(response, attempt)
      return handle_http_error(response, attempt) unless response.is_a?(Net::HTTPSuccess)
      # Поток уже разобран по мере чтения — тела для повторного разбора нет.
      return interpret_stream if @stream

      parsed, reason = ChatResponse.parse(response.body)
      if parsed
        @transcript&.reasoning(parsed.reasoning)
        return parsed.to_a
      end

      @ui&.error(reason)
      @last_reason = reason
      nil
    end

    # Пустой поток — не пустой ответ модели, а несостоявшийся; что это
    # значит и почему их нельзя путать, см. StreamParser#empty?. Здесь
    # остаётся решение: такую попытку следует повторить.
    def interpret_stream
      # Размышления пишутся и у несостоявшегося потока: там их не бывает,
      # но проверять это здесь значило бы знать, чего не бывает у сервера.
      @transcript&.reasoning(@stream.reasoning)
      return @stream.to_a unless @stream.empty?

      @ui&.error(Messages::EMPTY_STREAM)
      @last_reason = Messages::EMPTY_STREAM
      nil
    end

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

    # Соединение поднимается лениво: в исходном скрипте вызов run без
    # предварительного start_http падал с NoMethodError на nil.
    def connection
      @http ||= build_http(@config.chat_uri) # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = @config.use_ssl?
      http.open_timeout = OPEN_TIMEOUT
      # Ожидание ответа настраивается, а открытие соединения — нет: сервер
      # либо отзывается сразу, либо его нет, и десяти секунд на это хватает
      # при любой скорости модели. Медленной бывает генерация, а не TCP.
      http.read_timeout = @config.llm_timeout
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
