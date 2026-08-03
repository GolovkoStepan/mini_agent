# frozen_string_literal: true

require "net/http"
require "json"

module MiniAgent
  # Попытка узнать у сервера размер контекстного окна загруженной модели.
  #
  # Само число агенту нужно постоянно: в него упирается и рост истории, и
  # max_tokens, и потолок описания проекта. Но OpenAI-совместимый протокол
  # его не сообщает — ни в /models, ни в ответе на запрос. Единственное,
  # что приходит от сервера, — prompt_tokens в usage, то есть где мы сейчас,
  # без ответа на вопрос «из скольких».
  #
  # У LM Studio значение есть в /api/v0/models (loaded_context_length) — это
  # его собственное расширение, не часть протокола. Отсюда весь характер
  # класса: он ПРОБУЕТ спросить и молча отступает при любой неудаче. Чужой
  # сервер ответит 404 или чем угодно ещё, и это не ошибка — просто узнать
  # не вышло. Ошибкой было бы шуметь про необязательный запрос, которого
  # пользователь не заказывал.
  #
  # Значение из --context-window сюда не попадает вовсе: заданное человеком
  # перебивает угаданное, и спрашивать сервер тогда незачем (см. вызов
  # в AgentBuilder).
  class WindowProbe
    PATH = "/api/v0/models"

    # Проба идёт вне очереди на старте, когда человек ждёт первого ответа.
    # Секунда — потолок ожидания необязательной справки: не ответили быстро,
    # значит работаем без неё.
    TIMEOUT = 1

    def initialize(config:)
      @config = config
    end

    # Возвращает размер окна загруженной модели или nil. Не бросает ничего:
    # неудача пробы не должна мешать работе, ради которой агент запущен.
    def call
      response = fetch
      return nil unless response.is_a?(Net::HTTPSuccess)

      window(JSON.parse(response.body))
    rescue StandardError
      # Сеть, разбор, неожиданный формат — всё это здесь одно и то же:
      # спросить не удалось. Список исключений тут был бы длиннее пользы.
      nil
    end

    private

    def fetch
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.request(Net::HTTP::Get.new(uri.path, headers))
    end

    # Путь строится от корня сервера, а не от base_url: /api/v0 — сосед /v1,
    # а не его потомок. Порт и схему берём из адреса, которым и так пользуемся.
    def uri
      @uri ||= URI.parse(@config.base_url).tap do |parsed|
        parsed.path = PATH
        parsed.query = nil
      end
    end

    def headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@config.api_key}"
      }
    end

    # Ищем ЗАГРУЖЕННУЮ модель, а не выбранную по имени: работает та, что в
    # памяти. LM Studio на незнакомое имя молча подставляет загруженную (это
    # уже ловилось в --list-models), поэтому совпадение имён ничего не
    # гарантирует, а state: "loaded" — гарантирует.
    #
    # max_context_length сознательно не берётся запасным вариантом: у той же
    # модели это 262144 против загруженных 8192. Ошибиться в тридцать раз
    # в бо́льшую сторону хуже, чем не знать: агент считал бы, что места полно,
    # ровно там, где оно кончилось.
    def window(parsed)
      # LM Studio отвечает 200 с полем error в теле на неверный путь —
      # та же ловушка, что и в ModelsRequest. Без этой проверки поле data
      # искалось бы в объекте ошибки.
      return nil if parsed["error"]

      models = parsed["data"]
      return nil unless models.is_a?(Array)

      loaded = models.find { |model| model["state"] == "loaded" }
      size = loaded && loaded["loaded_context_length"]
      size if size.is_a?(Integer) && size.positive?
    end
  end
end
