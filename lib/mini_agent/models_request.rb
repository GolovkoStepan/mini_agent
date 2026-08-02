# frozen_string_literal: true

require "net/http"
require "json"

module MiniAgent
  # Запрос списка моделей, загруженных на сервере (GET /models).
  #
  # Живёт отдельно от LLMClient намеренно: тот ведёт диалог — держит соединение
  # на всю сессию, повторяет запросы, разбирает choices и tool_calls. Здесь же
  # разовая справочная команда без повторов. Общего у них только адрес сервера
  # и заголовки, и слияние двух этих задач в один класс уже упирало его
  # в Metrics/ClassLength.
  #
  # Повторов нет намеренно: команду запускает человек, который смотрит
  # в терминал, и молчаливое ожидание перед показом ошибки хуже самой ошибки.
  class ModelsRequest
    INVALID_DATA = "Некорректный ответ: поле data отсутствует или не является списком"

    def initialize(config:, http:)
      @config = config
      @http = http
    end

    # Возвращает отсортированный массив имён. Бросает LLMError, если сервер
    # ответил ошибкой или прислал что-то неразбираемое.
    def call
      response = @http.request(Net::HTTP::Get.new(@config.models_uri.path, headers))
      raise LLMError, ErrorResponse.new(response).to_s unless response.is_a?(Net::HTTPSuccess)

      extract(response)
    end

    private

    def extract(response)
      parsed = JSON.parse(response.body)
      # LM Studio отвечает 200 с полем error в теле, если путь не тот
      # (например, base_url без /v1). Без этой ветки пользователь получил бы
      # «поле data отсутствует» — формально верно и совершенно бесполезно.
      raise LLMError, ErrorResponse.new(response).text if parsed["error"]

      data = parsed["data"]
      raise LLMError, INVALID_DATA unless data.is_a?(Array)

      data.filter_map { |model| model["id"] }.sort
    rescue JSON::ParserError => e
      raise LLMError, format(Messages::INVALID_JSON, message: e.message)
    end

    def headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@config.api_key}"
      }
    end
  end
end
