# frozen_string_literal: true

require "json"

module MiniAgent
  # Неуспешный HTTP-ответ LLM-сервера, разобранный до трёх вопросов: имеет ли
  # смысл повтор, сколько ждать и что показать человеку.
  #
  # Вынесено из LLMClient отдельным объектом: разбор чужого формата ошибок —
  # это своя задача со своими краевыми случаями (три разных вида тела, кодировка
  # без charset, Retry-After в двух форматах), и в клиенте она тонула среди
  # логики повторов.
  class ErrorResponse
    # Коды, при которых повтор осмыслен: сервер занят или просит подождать.
    # Прочие 4xx — ошибка самого запроса (нет такой модели, неверный ключ,
    # битая история), и повтор вернёт тот же ответ, заплатив retry_delay
    # за каждую попытку.
    RETRIABLE_STATUS = [408, 429].freeze

    # Потолок для Retry-After: сервер вправе попросить и час, но агент
    # интерактивный, и молчаливое ожидание неотличимо от зависания.
    MAX_RETRY_AFTER = 60

    def initialize(response)
      @response = response
    end

    def code = @response.code

    def retriable?
      status = code.to_i
      status >= 500 || RETRIABLE_STATUS.include?(status)
    end

    def to_s = "HTTP #{code}: #{text}"

    # nil, если сервер ничего не просил — тогда действует настроенная задержка.
    #
    # Поддерживается только числовая форма: HTTP-дата в Retry-After допустима
    # спецификацией, но локальные серверы её не шлют, а разбор дат тянул бы
    # зависимость от текущего времени в тесты.
    def retry_after
      seconds = @response["retry-after"].to_s.strip
      return nil unless seconds.match?(/\A\d+(\.\d+)?\z/)

      [seconds.to_f, MAX_RETRY_AFTER].min
    end

    # Тело ошибки OpenAI-совместимых серверов — {"error": {"message": "…"}},
    # но встречается и {"error": "строка"}, и просто текст. Показываем самое
    # внятное из доступного: сырой JSON в консоли читать невозможно.
    def text
      parsed = JSON.parse(body)
      error = parsed["error"]

      case error
      when Hash then error["message"] || body
      when String then error
      else body
      end
    rescue JSON::ParserError
      body
    end

    private

    # Net::HTTP отдаёт тело как ASCII-8BIT, если сервер не прислал charset.
    # Склейка такой строки с русским текстом сообщения роняет всё
    # с Encoding::CompatibilityError — причём вместо самой ошибки от сервера.
    def body
      @body ||= @response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
