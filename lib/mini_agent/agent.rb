# frozen_string_literal: true

require "json"

module MiniAgent
  # Цикл агента: запрос к модели → выполнение инструментов → повтор.
  class Agent
    # Максимум символов результата инструмента, уходящих В МОДЕЛЬ.
    # Ограничение защищает контекстное окно и не связано с усечением,
    # которое UI применяет для читаемости консоли (UI::PREVIEW_LINES).
    MAX_TOOL_OUTPUT = 10_000

    # Нужен Repl: команда /clear начинает историю заново, и описание проекта
    # должно попасть в новую Conversation — иначе после очистки агент забывал бы
    # про AGENTS.md до конца сессии.
    attr_reader :project_context

    def initialize(config:, client:, tools:, ui:, project_context: nil)
      @config = config
      @client = client
      @tools = tools
      @ui = ui
      @project_context = project_context
    end

    # Возвращает Conversation целиком, а не текст последнего ответа: именно
    # это позволяет интерактивному режиму продолжать диалог с накопленной
    # историей, передавая её обратно через conversation:.
    def run(user_message = nil, conversation: nil)
      conversation ||= Conversation.new(project_context: @project_context)
      conversation.user(user_message) if user_message

      @config.max_turns.times do |index|
        # Номер хода виден только в спиннере и стирается вместе с ним:
        # в логе работы эта бухгалтерия не нужна.
        @ui.status = format(Messages::TURN, number: index + 1, total: @config.max_turns)

        content, tool_calls = request(conversation)
        return conversation if content.nil? # сетевая ошибка, история сохранена

        @ui.assistant(content) unless content.empty?

        return finish(conversation, content) if tool_calls.empty?

        conversation.assistant(content, tool_calls: tool_calls)
        tool_calls.each { |tool_call| handle_tool_call(conversation, tool_call) }
      end

      summarize(conversation)
    end

    private

    def request(conversation, tool_choice: "auto")
      @client.chat(conversation.to_a, tools: @tools.schemas, tool_choice: tool_choice)
    rescue StandardError => e
      @ui.error(format(Messages::LLM_CONNECTION_FAILED, message: e.message))
      nil
    end

    # Отдельного «готово» не печатаем: финальный ответ модели уже показан
    # выше и сам по себе означает завершение.
    def finish(conversation, content)
      if content.empty?
        @ui.warn(Messages::EMPTY_RESPONSE)
      else
        conversation.assistant(content)
      end
      conversation
    end

    def handle_tool_call(conversation, tool_call)
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

    # Достигнут лимит ходов: просим модель подвести итог.
    # tool_choice: "none" — иначе она вернёт очередной вызов инструмента,
    # выполнять который уже негде, и он потеряется молча.
    #
    # Просьба идёт ролью user, а не system: шаблоны чата ряда моделей
    # (Qwen и другие) требуют, чтобы system-сообщение было только первым,
    # и отвечают HTTP 400 на system в середине истории.
    def summarize(conversation)
      @ui.warn(format(Messages::MAX_TURNS_REACHED, count: @config.max_turns))
      conversation.user(Messages::STOP_MAX_TURNS)

      content, = request(conversation, tool_choice: "none")
      if content.nil?
        @ui.error(format(Messages::SUMMARY_FAILED, message: ""))
        return conversation
      end

      unless content.empty?
        @ui.assistant(content)
        conversation.assistant(content)
      end
      conversation
    end
  end
end
