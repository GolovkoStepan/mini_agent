# frozen_string_literal: true

module MiniAgent
  # Цикл агента: запрос к модели → выполнение инструментов → повтор.
  class Agent
    def initialize(config:, client:, tools:, ui:, history: History.new, prompt: nil, auto_compactor: nil,
                   plan_mode: PlanMode.new)
      @config = config
      @client = client
      @tools = tools
      @ui = ui
      @history = history
      @prompt = prompt
      @plan_mode = plan_mode
      @tool_runner = ToolCallRunner.new(tools: tools, ui: ui)
      # Подменяем в тестах: иначе проверка цикла ходов требовала бы настоящего
      # переполнения окна, то есть настоящего сервера с настоящим usage.
      @auto_compactor = auto_compactor || AutoCompactor.new(
        compactor: compactor, config: config, ui: ui, usage: history.usage
      )
    end

    # Расход токенов за сессию. Хранится в History, а не здесь: там же
    # заводится всякая новая история, а начало новой истории обнуляет
    # «контекст сейчас». Разведи их — и сброс уходил бы в один объект,
    # а /context показывал бы другой.
    def usage = @history.usage

    # Режим планирования. Открыт наружу ради Repl — по той же причине, по
    # которой ему открыт new_conversation: тот же объект нужен и агенту
    # (он подставляет инструкцию в задачу), и CommandGuard (он отвергает
    # по нему команды), и самому Repl (/plan его переключает). Второй такой
    # объект означал бы включённый режим, о котором не знает охрана команд.
    attr_reader :plan_mode

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
    def compact(conversation) = compactor.call(conversation)

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
      @history.project_context = ProjectContext.load(@config.cwd || Dir.pwd, window: @config.context_window)
      result
    end

    # Задача в режиме планирования: изучить, показать план и спросить, надо ли
    # его выполнять. Живёт здесь по той же причине, что и init: работа идёт
    # обычным циклом ходов, а Prompt у агента уже есть. Сам разговор — в
    # Planner.
    def plan(task, conversation)
      Planner.new(agent: self, plan_mode: @plan_mode, ui: @ui, prompt: @prompt).call(task, conversation)
    end

    # Возвращает Conversation целиком, а не текст последнего ответа: именно
    # это позволяет интерактивному режиму продолжать диалог с накопленной
    # историей, передавая её обратно через conversation:.
    # Возвращённый объект может оказаться НЕ ТЕМ, что передали: автоматическое
    # сворачивание заменяет историю новой посреди задачи. Вызывающий обязан
    # брать историю из возврата, а не продолжать пользоваться своей — иначе
    # свёрнутое молча теряется на следующей задаче.
    def run(user_message = nil, conversation: nil)
      # Сбрасывается на каждой задаче: в интерактивном режиме провал одной
      # не должен помечать всю сессию до самого выхода.
      @outcome = :ok
      # По той же причине: ответ относится к задаче. Без сброса Planner
      # принял бы за план прошлый ответ, если новая задача его не дала.
      @answer = nil
      # По той же причине, что и outcome: счёт повторов относится к задаче,
      # а не к сессии, и без сброса «покажи файлы» дважды подряд разными
      # задачами выглядело бы зацикливанием.
      @tool_runner.reset
      conversation ||= new_conversation
      # Сворачивание стоит ПЕРЕД тем, как задача попадёт в историю: резюме
      # пересказывает всё, что в ней лежит, и свежая задача превратилась бы
      # в часть пересказа — то есть в сделанное, а не в поручение. Найдено
      # живой проверкой: вторая задача сессии («посчитай файлы») ушла в
      # резюме, и модель ответила, что не понимает, чего от неё хотят.
      # Отметка отката берётся после: свернувшись, история сменила объект.
      conversation = @auto_compactor.call(conversation)
      mark = conversation.mark
      # Инструкция режима идёт отдельным сообщением перед задачей и повторяется
      # с каждой: системный промпт собран на старте, а режим включают посреди
      # сессии — переписать его на месте значило бы выбросить историю (тот же
      # довод, что у /init и описания проекта). Повтор вдобавок переживает
      # сворачивание, после которого в истории от инструкции ничего не остаётся.
      conversation.user(Messages::PLAN_INSTRUCTION) if user_message && @plan_mode.on?
      conversation.user(user_message) if user_message

      turns(conversation, mark)
    end

    # Чем кончилась последняя задача: :ok, :failed (запрос к модели не удался)
    # или :unfinished (кончились ходы). По этому признаку CLI выбирает код
    # возврата: без него агент возвращал 0 даже когда не сделал ничего.
    attr_reader :outcome

    # Последний ответ модели текстом, nil — если задача до него не дошла.
    # Заводится ради Planner: план и есть ответ, а доставать его из истории
    # значило бы доставать то, что автоматическое сворачивание могло уже
    # заменить резюме. Итог по исчерпанным ходам сюда не попадает намеренно
    # (см. summarize): там модель подводит черту под сделанным, и выдать это
    # за план значило бы предложить к выполнению отчёт.
    attr_reader :answer

    def failed? = @outcome == :failed

    private

    # Один на всю сессию, а не по объекту на вызов: тем же занята автоматика,
    # и два экземпляра означали бы два разных счёта одних и тех же токенов.
    def compactor
      @compactor ||= Compactor.new(client: @client, history: @history, ui: @ui, usage: usage)
    end

    def turns(conversation, mark)
      @config.max_turns.times do |index|
        # Перед выставлением номера хода, а не после: Compactor гасит строку
        # состояния в своём ensure, и поставленный раньше номер исчез бы
        # с экрана вместе с ней. Первый ход пропускается: про него уже
        # спросили в run, до того как задача попала в историю.
        conversation, mark = compacted(conversation, mark) unless index.zero?

        # Номер хода виден только в спиннере и стирается вместе с ним:
        # в логе работы эта бухгалтерия не нужна.
        @ui.status = format(Messages::TURN, number: index + 1, total: @config.max_turns)

        content, tool_calls, usage, finish_reason = request(conversation)
        return recover(conversation, mark) if content.nil?

        @ui.assistant(content) unless content.empty?

        return finish(conversation, content, usage, finish_reason) if tool_calls.empty?

        return looped(conversation) if run_tools(conversation, content, tool_calls, usage, finish_reason) == :loop
      end

      summarize(conversation, mark)

    # Ctrl+C во время ожидания модели или выполнения команды прерывает задачу,
    # но не сессию: история остаётся, и в интерактивном режиме можно
    # продолжить. Interrupt не StandardError, поэтому rescue выше его не
    # перехватывают и он доходит сюда.
    #
    # Ловится вокруг всего цикла, а не вокруг одного запроса: прервать
    # полагается задачу целиком, иначе агент пошёл бы на следующий ход как
    # ни в чём не бывало.
    #
    # Стоит именно здесь, а не в обёртке вокруг turns, куда напрашивается:
    # обёртка возвращала бы историю, захваченную ДО сворачивания, и Ctrl+C
    # сразу после него молча выбрасывал бы свежее резюме вместе с диалогом.
    # Здесь conversation — та же переменная, которую цикл переприсваивает.
    rescue Interrupt
      @ui.warn(Messages::TASK_INTERRUPTED)
      conversation
    end

    # Свернуть диалог, если окно кончается. Отметка отката берётся заново:
    # прежняя указывает в историю, которой больше нет, и rollback по ней
    # молча ничего бы не снял (число снятого вышло бы отрицательным).
    def compacted(conversation, mark)
      fresh = @auto_compactor.call(conversation)
      return [conversation, mark] if fresh.equal?(conversation)

      [fresh, fresh.mark]
    end

    def run_tools(conversation, content, tool_calls, usage, finish_reason)
      # Обрыв по лимиту посреди вызова инструмента: аргументы пришли
      # обрезанными, и parse_arguments объявит их «битым JSON от модели» —
      # диагноз, уводящий от настоящей причины. Говорим её сразу.
      @ui.warn(format(Messages::TRUNCATED_TOOL_CALL, limit: @config.max_tokens)) if truncated?(finish_reason)

      conversation.assistant(content, tool_calls: tool_calls, usage: usage)
      # Обход не прерывается на первом же :loop: модель ждёт ответа на каждый
      # tool_call_id, и брошенный без ответа вызов оставил бы в истории дыру,
      # от которой валится следующий запрос — ровно то, ради чего заведён
      # rollback. Обрыв откладывается до конца обхода.
      statuses = tool_calls.map { |tool_call| @tool_runner.call(conversation, tool_call) }
      statuses.include?(:loop) ? :loop : :ok
    end

    # Модель третий раз подряд просит одно и то же. Ходы не кончились, но и
    # двигаться некуда — исход тот же, что при исчерпанном лимите: задача
    # не доделана, код возврата 4. Итог у модели не спрашиваем, в отличие
    # от summarize: зациклившаяся модель за тот же запрос вернёт ту же
    # петлю. Предупреждение уже напечатал ToolCallRunner — он и знает
    # подробности, а второе сообщение объявляло бы то же событие дважды.
    def looped(conversation)
      @outcome = :unfinished
      conversation
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
      @outcome = :failed
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
        @answer = content
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

      @outcome = :failed
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

    # Достигнут лимит ходов: просим модель подвести итог.
    # tool_choice: "none" — иначе она вернёт очередной вызов инструмента,
    # выполнять который уже негде, и он потеряется молча.
    #
    # Просьба идёт ролью user, а не system: шаблоны чата ряда моделей
    # (Qwen и другие) требуют, чтобы system-сообщение было только первым,
    # и отвечают HTTP 400 на system в середине истории.
    def summarize(conversation, mark)
      # Ходы кончились — задача не доделана, чем бы ни кончился итоговый
      # запрос. Раньше признака здесь не было вовсе, и агент возвращал 0:
      # модель по просьбе подводила итог, отчёт выглядел как «готово»,
      # а сделана задача была наполовину. Ставится ДО запроса, чтобы
      # неудача последнего перебила это на :failed.
      @outcome = :unfinished
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
