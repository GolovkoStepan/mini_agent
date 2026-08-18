# frozen_string_literal: true

require "json"

module MiniAgent
  # Выполнение одного вызова инструмента: разбор аргументов, диспетчеризация,
  # усечение результата перед возвратом модели.
  #
  # Отделено от Agent по тому же признаку, что ChatResponse от LLMClient:
  # цикл ходов решает, что делать дальше, а здесь — как выполнить один вызов.
  # Общего состояния между ними нет, кроме истории, которая приходит
  # аргументом.
  class ToolCallRunner
    # Максимум символов результата инструмента, уходящих В МОДЕЛЬ.
    # Ограничение защищает контекстное окно и не связано с усечением,
    # которое UI применяет для читаемости консоли (UI::PREVIEW_LINES).
    MAX_TOOL_OUTPUT = 10_000

    def initialize(tools:, ui:)
      @tools = tools
      @ui = ui
    end

    # Результат кладётся в историю здесь, а не возвращается наружу: у вызова
    # два исхода (ответ инструмента и жалоба на битые аргументы), и оба обязаны
    # попасть в историю — модель ждёт ответа на каждый tool_call_id, иначе
    # следующий запрос уходит с дырой.
    def call(conversation, tool_call)
      function = tool_call["function"] || {}
      name = function["name"].to_s
      tool_call_id = Conversation.tool_call_id(tool_call)

      arguments = parse_arguments(function["arguments"])
      unless arguments
        conversation.tool(tool_call_id, @last_parse_error)
        return
      end

      @ui.tool_call(name, arguments)
      result = @tools.dispatch(name, arguments)
      @ui.tool_result(result)

      conversation.tool(tool_call_id, truncate(result))
    end

    private

    # Битый JSON в аргументах — не повод ронять цикл: сообщаем об этом
    # модели, и она может исправиться на следующем ходу.
    def parse_arguments(raw)
      parsed = JSON.parse(raw.to_s.empty? ? "{}" : raw)
      return parsed if parsed.is_a?(Hash)

      @last_parse_error = format(Messages::ARGS_PARSE_ERROR, message: "ожидался объект", raw: raw.to_s[0, 200])
      nil
    rescue JSON::ParserError => e
      @last_parse_error = format(Messages::ARGS_PARSE_ERROR, message: e.message, raw: raw.to_s[0, 200])
      @ui.error(@last_parse_error)
      nil
    end

    def truncate(text)
      return text if text.length <= MAX_TOOL_OUTPUT

      text[0, MAX_TOOL_OUTPUT] + Messages::TRUNCATED_SUFFIX
    end
  end
end
