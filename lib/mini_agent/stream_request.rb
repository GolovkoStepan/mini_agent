# frozen_string_literal: true

module MiniAgent
  # Запрос с потоковым чтением ответа.
  #
  # Отдельно от LLMClient по той же причине, что и ModelsRequest: там диалог
  # с повторами, здесь одно чтение тела по кускам. Слив их воедино, LLMClient
  # снова перерос бы Metrics/ClassLength — а порог в этом проекте четырежды
  # оказывался верным указанием на чужую задачу.
  #
  # Возвращает [response, parser]: ответ нужен для разбора кода HTTP, разбор
  # тела — забота StreamParser. Ошибочный ответ тоже вычитывается, но целиком:
  # тело у него обычный JSON, а не поток, и ErrorResponse ждёт именно строку.
  class StreamRequest
    # visible: false — ответ на служебный запрос, который пользователю не
    # показывают. Такой есть ровно один: резюме для /compact — оно замещает
    # историю, а не адресовано человеку, и отчёт «свёрнут: N → M» рассчитан
    # на то, что самого резюме на экране нет. Найдено живой проверкой:
    # /compact вываливал в терминал весь пересказ диалога, а следом — строку
    # о том, что сворачивать было нечего.
    #
    # Поток при этом всё равно потоковый: usage приходит тем же куском, а
    # ожидание считается от последнего полученного, а не от начала запроса.
    # Гасится ровно печать текста — ход размышлений в спиннере остаётся,
    # иначе долгое сворачивание выглядело бы зависанием.
    def initialize(http:, ui: nil, visible: true)
      @http = http
      @ui = ui
      @visible = visible
    end

    def call(request)
      parser = StreamParser.new { |text| @ui&.stream_chunk(text) if @visible }
      response = with_spinner { @http.request(request) { |result| read(result, parser) } }

      [response, parser]
    ensure
      # Спиннер гасится и здесь: если ответ пришёл без единого куска текста
      # (только вызов инструмента), гасить его было некому.
      @ui&.stop_spinner
      @ui&.stream_finish
    end

    private

    # Обёртка обязана выполнять блок и без UI: `@ui&.with_spinner { ... }`
    # выглядит безобидно, но при @ui == nil не выполняет блок вовсе — запрос
    # просто не уходит, а наружу возвращается nil вместо ответа.
    def with_spinner(&)
      return yield unless @ui

      @ui.with_spinner(&)
    end

    def read(response, parser)
      unless response.is_a?(Net::HTTPSuccess)
        response.read_body
        return
      end

      response.read_body { |chunk| consume(parser, chunk) }
    end

    # Размышления показываются счётчиком, а не текстом.
    #
    # Без этого стриминг на рассуждающей модели не даёт почти ничего:
    # измерено на qwen3.6 — 187 токенов размышлений против 3 токенов ответа,
    # то есть 79 секунд неподвижного спиннера и лишь потом текст. Печатать
    # сами размышления незачем (см. ROADMAP), а вот видеть, что модель занята
    # и чем именно, — ровно то, ради чего стриминг и заводился.
    def consume(parser, chunk)
      parser.feed(chunk)
      return unless parser.reasoning_length.positive?

      @ui&.progress = format(Messages::REASONING_PROGRESS,
                             count: Plural.with(parser.reasoning_length, *Messages::CHARS))
    end
  end
end
