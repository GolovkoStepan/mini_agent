# frozen_string_literal: true

module MiniAgent
  # Успешный ответ /chat/completions, разобранный до того, что нужно агенту:
  # текст, вызовы инструментов, расход токенов и причина остановки.
  #
  # Парная к ErrorResponse и вынесена по той же причине: поля лежат на трёх
  # разных уровнях ответа — content и tool_calls внутри message, finish_reason
  # рядом с ним в choices[0], usage в корне, — и знание этой раскладки
  # к повторам запросов отношения не имеет.
  class ChatResponse
    # Модель не закончила, а упёрлась в max_tokens. Единственный способ
    # отличить обрезанный ответ от полного: у рассуждающих моделей
    # размышления идут отдельным полем, но тратят тот же бюджет, и, выбрав
    # его, они возвращают пустой content — неотличимый от «нечего сказать».
    TRUNCATED = "length"

    def initialize(data, message)
      @data = data
      @message = message
    end

    def content = (@message["content"] || "").strip
    def tool_calls = @message["tool_calls"] || []
    def usage = @data["usage"]
    def finish_reason = @data.dig("choices", 0, "finish_reason")
    def truncated? = finish_reason == TRUNCATED

    # Кортеж, а не объект: у chat уже есть сложившийся вид возвращаемого
    # значения, и десятки стабов в тестах разбирают именно его.
    def to_a = [content, tool_calls, usage, finish_reason]
  end
end
