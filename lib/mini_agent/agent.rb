# frozen_string_literal: true

require "json"

module MiniAgent
  # Цикл агента: запрос к модели → выполнение инструментов → повтор.
  class Agent
    # Максимум символов результата инструмента, уходящих В МОДЕЛЬ.
    # Ограничение защищает контекстное окно и не связано с усечением,
    # которое UI применяет для читаемости консоли (UI::PREVIEW_LINES).
    MAX_TOOL_OUTPUT = 10_000

    def initialize(config:, client:, tools:, ui:, history: History.new)
      @config = config
      @client = client
      @tools = tools
      @ui = ui
      @history = history
      @usage = Usage.new
    end

    # Расход токенов за сессию: живёт у агента, а не у клиента, потому что
    # соединение может подниматься заново, а счёт идёт по всей работе.
    attr_reader :usage

    # Пустая история со всем, что агенту для неё нужно. Repl зовёт этот же
    # метод по /clear: команда начинает диалог заново, и без общей точки
    # сборки каждое новое поле (описание проекта, журнал) пришлось бы
    # добавлять и там — молча теряясь при первой же очистке.
    def new_conversation = @history.build

    # Возвращает Conversation целиком, а не текст последнего ответа: именно
    # это позволяет интерактивному режиму продолжать диалог с накопленной
    # историей, передавая её обратно через conversation:.
    def run(user_message = nil, conversation: nil)
      # Сбрасывается на каждой задаче: в интерактивном режиме провал одной
      # не должен помечать всю сессию до самого выхода.
      @failed = false
      conversation ||= new_conversation
      mark = conversation.mark
      conversation.user(user_message) if user_message

      interrupted(conversation) { turns(conversation, mark) }
    end

    # Последняя задача провалилась — запрос к модели не удался. По этому
    # признаку CLI отличает невыполненную задачу от выполненной: без него
    # агент возвращал 0 даже когда не сделал ничего.
    def failed?
      @failed
    end

    private

    def turns(conversation, mark)
      @config.max_turns.times do |index|
        # Номер хода виден только в спиннере и стирается вместе с ним:
        # в логе работы эта бухгалтерия не нужна.
        @ui.status = format(Messages::TURN, number: index + 1, total: @config.max_turns)

        content, tool_calls, usage = request(conversation)
        return recover(conversation, mark) if content.nil?

        @ui.assistant(content) unless content.empty?

        return finish(conversation, content, usage) if tool_calls.empty?

        conversation.assistant(content, tool_calls: tool_calls, usage: usage)
        tool_calls.each { |tool_call| handle_tool_call(conversation, tool_call) }
      end

      summarize(conversation, mark)
    end

    # Учёт токенов стоит здесь, а не в цикле ходов: через этот метод проходят
    # оба вида запросов — и обычный ход, и суммирующий из summarize, — а тот
    # оплачен ровно так же.
    def request(conversation, tool_choice: "auto")
      content, tool_calls, usage = @client.chat(
        conversation.to_a, tools: @tools.schemas, tool_choice: tool_choice
      )
      @usage.add(usage)
      [content, tool_calls, usage]
    rescue StandardError => e
      @failed = true
      @ui.error(format(Messages::LLM_CONNECTION_FAILED, message: e.message))
      nil
    end

    # Запрос не удался — снимаем с истории всё, что успела добавить эта задача.
    # Иначе в ней остаётся мусор, который валит и следующий запрос: висящее
    # user-сообщение без ответа, а при упоре в контекстное окно — ещё и не
    # влезший туда результат инструмента. Без отката сессия оставалась мёртвой
    # до /clear: проверено живьём, следующий вопрос до модели уже не доходил.
    def recover(conversation, mark)
      @ui.warn(Messages::TURN_ROLLED_BACK) if conversation.rollback(mark).positive?
      conversation
    end

    # Ctrl+C во время ожидания модели или выполнения команды прерывает задачу,
    # но не сессию: история остаётся, и в интерактивном режиме можно
    # продолжить. Interrupt не StandardError, поэтому rescue выше его не
    # перехватывают и он доходит сюда.
    #
    # Ловится вокруг всего цикла, а не вокруг одного запроса: прервать
    # полагается задачу целиком, иначе агент пошёл бы на следующий ход как
    # ни в чём не бывало.
    def interrupted(conversation)
      yield
    rescue Interrupt
      @ui.warn(Messages::TASK_INTERRUPTED)
      conversation
    end

    # Отдельного «готово» не печатаем: финальный ответ модели уже показан
    # выше и сам по себе означает завершение.
    def finish(conversation, content, usage = nil)
      if content.empty?
        @ui.warn(Messages::EMPTY_RESPONSE)
      else
        conversation.assistant(content, usage: usage)
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
    def summarize(conversation, mark)
      @ui.warn(format(Messages::MAX_TURNS_REACHED, count: @config.max_turns))
      conversation.user(Messages::STOP_MAX_TURNS)

      content, = request(conversation, tool_choice: "none")
      if content.nil?
        @ui.error(format(Messages::SUMMARY_FAILED, message: ""))
        return recover(conversation, mark)
      end

      unless content.empty?
        @ui.assistant(content)
        conversation.assistant(content)
      end
      conversation
    end
  end
end
