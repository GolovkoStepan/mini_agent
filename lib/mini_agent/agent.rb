# frozen_string_literal: true

require "json"

module MiniAgent
  # Цикл агента: запрос к модели → выполнение инструментов → повтор.
  class Agent
    # Максимум символов результата инструмента, уходящих В МОДЕЛЬ.
    # Ограничение защищает контекстное окно и не связано с усечением,
    # которое UI применяет для читаемости консоли (UI::PREVIEW_LINES).
    MAX_TOOL_OUTPUT = 10_000

    def initialize(config:, client:, tools:, ui:, history: History.new, prompt: nil)
      @config = config
      @client = client
      @tools = tools
      @ui = ui
      @history = history
      @prompt = prompt
    end

    # Расход токенов за сессию. Хранится в History, а не здесь: там же
    # заводится всякая новая история, а начало новой истории обнуляет
    # «контекст сейчас». Разведи их — и сброс уходил бы в один объект,
    # а /context показывал бы другой.
    def usage = @history.usage

    # Пустая история со всем, что агенту для неё нужно. Repl зовёт этот же
    # метод по /clear: команда начинает диалог заново, и без общей точки
    # сборки каждое новое поле (описание проекта, журнал) пришлось бы
    # добавлять и там — молча теряясь при первой же очистке.
    def new_conversation = @history.build

    # Свернуть диалог в резюме (/compact). Возвращает новую историю либо
    # прежнюю, если свернуть не удалось.
    #
    # Живёт у агента, а не у Repl, только ради доступа к клиенту, History
    # и счётчику токенов: собирать их в Repl заново значило бы продублировать
    # половину AgentBuilder. Сама работа — в Compactor; здесь один вызов.
    def compact(conversation)
      Compactor.new(client: @client, history: @history, ui: @ui, usage: usage).call(conversation)
    end

    # Описать проект в AGENTS.md (/init). Возвращает историю: команда ведёт
    # обычный диалог, и его сообщения в ней остаются.
    #
    # Живёт здесь по той же причине, что и compact, но работает иначе: там
    # один запрос, здесь полный цикл ходов — прочитать проект без bash нельзя.
    # Отсюда и передача self: Initializer зовёт run, а не client напрямую.
    #
    # Новое описание кладётся в History сразу, но текущий диалог им не
    # переписывается: оно попадает в системный промпт при сборке истории,
    # то есть на ближайшем /clear или /compact. Применить его к текущей
    # истории значило бы её выбросить — скрытый /clear там, где о нём
    # не просили.
    def init(conversation)
      result = Initializer.new(agent: self, config: @config, ui: @ui, prompt: @prompt).call(conversation)
      @history.project_context = ProjectContext.load(@config.cwd || Dir.pwd)
      result
    end

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

        content, tool_calls, usage, finish_reason = request(conversation)
        return recover(conversation, mark) if content.nil?

        @ui.assistant(content) unless content.empty?

        return finish(conversation, content, usage, finish_reason) if tool_calls.empty?

        run_tools(conversation, content, tool_calls, usage, finish_reason)
      end

      summarize(conversation, mark)
    end

    def run_tools(conversation, content, tool_calls, usage, finish_reason)
      # Обрыв по лимиту посреди вызова инструмента: аргументы пришли
      # обрезанными, и parse_arguments объявит их «битым JSON от модели» —
      # диагноз, уводящий от настоящей причины. Говорим её сразу.
      @ui.warn(format(Messages::TRUNCATED_TOOL_CALL, limit: @config.max_tokens)) if truncated?(finish_reason)

      conversation.assistant(content, tool_calls: tool_calls, usage: usage)
      tool_calls.each { |tool_call| handle_tool_call(conversation, tool_call) }
    end

    # Учёт токенов стоит здесь, а не в цикле ходов: через этот метод проходят
    # оба вида запросов — и обычный ход, и суммирующий из summarize, — а тот
    # оплачен ровно так же.
    def request(conversation, tool_choice: "auto")
      content, tool_calls, usage, finish_reason = @client.chat(
        conversation.to_a, tools: @tools.schemas, tool_choice: tool_choice
      )
      @history.usage.add(usage)
      [content, tool_calls, usage, finish_reason]
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
    def finish(conversation, content, usage = nil, finish_reason = nil)
      if content.empty?
        empty_answer(finish_reason)
      else
        # Текст есть, но модель не договорила: ответ показан, дальше решает
        # человек. Задача при этом выполненной не считается только в первом
        # случае — здесь есть что читать.
        @ui.warn(format(Messages::TRUNCATED_ANSWER, limit: @config.max_tokens)) if truncated?(finish_reason)
        conversation.assistant(content, usage: usage)
      end
      conversation
    end

    # Пустой content — не всегда «модели нечего сказать». У рассуждающих
    # моделей размышления идут отдельным полем (reasoning_content), но тратят
    # тот же бюджет max_tokens: выбрав его, они не оставляют места ответу,
    # и до content очередь не доходит. Сервер сообщает это через
    # finish_reason: "length" — единственный способ отличить один случай
    # от другого. Найдено живой проверкой: при max_tokens=150 модель выдавала
    # 638 знаков рассуждений и пустой ответ, а агент рапортовал «пустой
    # ответ» и выходил с кодом 0.
    def empty_answer(finish_reason)
      unless truncated?(finish_reason)
        @ui.warn(Messages::EMPTY_RESPONSE)
        return
      end

      @failed = true
      @ui.error(format(Messages::TRUNCATED_EMPTY, limit: @config.max_tokens))
      @ui.puts(truncated_hint)
    end

    # Лечение выбирается по происхождению лимита, а не печатается одно
    # на все случаи. Прежний текст всегда советовал поднять --max-tokens,
    # и при лимите, выведенном из окна, это ложный след: замер на окне 8192
    # дал обрыв на 8156 токенах, то есть упор был в окно, а не в лимит, —
    # флаг там не добавляет ни одного токена.
    def truncated_hint
      return Messages::TRUNCATED_HINT_LIMIT unless @config.max_tokens_derived?

      format(Messages::TRUNCATED_HINT_WINDOW, window: @config.context_window)
    end

    def truncated?(finish_reason) = finish_reason == ChatResponse::TRUNCATED

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
