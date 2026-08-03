# frozen_string_literal: true

module MiniAgent
  # Сворачивание истории: диалог заменяется его пересказом.
  #
  # Работает НА УПРЕЖДЕНИЕ и переполненный контекст не лечит. Чтобы получить
  # резюме, историю надо отправить модели целиком — то есть сделать ровно тот
  # запрос, который при упоре в окно уже не проходит. Звать /compact нужно до
  # того, как стало тесно, а не после.
  #
  # Отдельно от Agent намеренно, по той же причине, по которой отделён Repl:
  # у Agent есть цикл ходов с инструментами, здесь — один запрос без них и
  # пересборка истории. Общего между ними только клиент.
  class Compactor
    def initialize(client:, history:, ui:, usage: nil)
      @client = client
      @history = history
      @ui = ui
      @usage = usage
    end

    # Возвращает новую свёрнутую историю либо исходную, если свернуть
    # не удалось. Отказ — это не ошибка сессии: продолжать можно с тем,
    # что есть.
    def call(conversation)
      if nothing_to_compact?(conversation)
        refuse(Messages::COMPACT_NOTHING)
        return conversation
      end

      summary = request_summary(conversation)
      return conversation if summary.nil?

      rebuild(conversation, summary)
    end

    private

    # Сворачивать пустой диалог незачем: останется ровно то же самое,
    # но за деньги и с потерей формулировок.
    def nothing_to_compact?(conversation)
      ContextReport.new(conversation).compactable.zero?
    end

    # tool_choice: "none" — тот же приём, что в Agent#summarize. Без него
    # модель на просьбу подвести итог возвращает очередной вызов
    # инструмента, применить который негде, и он теряется молча.
    #
    # Просьба идёт ролью user, а не system: шаблоны чата ряда моделей
    # требуют, чтобы system-сообщение было ровно одно и первое, и отвечают
    # HTTP 400 на system в середине истории.
    def request_summary(conversation)
      messages = conversation.to_a + [{ role: "user", content: Messages::COMPACT_REQUEST }]

      @ui.status = Messages::COMPACT_RUNNING
      content, _tool_calls, usage = @ui.with_spinner { @client.chat(messages, tool_choice: "none") }
      # Расход на сворачивание в счёт входит: запрос сделан и оплачен.
      # Тот же принцип, что у провалившегося хода, — счётчик показывает,
      # что произошло, а не то, что осталось в истории.
      @usage&.add(usage)

      return refuse(Messages::COMPACT_EMPTY) if content.nil? || content.strip.empty?

      content
    # Сеть отвалилась или модель отказала — история остаётся прежней.
    # Потерять диалог, не получив взамен резюме, худший из исходов.
    rescue StandardError => e
      refuse(format(Messages::COMPACT_FAILED, message: e.message))
    # Interrupt не наследник StandardError и до rescue выше не доходит.
    # Ловится здесь, а не в Repl: там отказ от сворачивания неотличим
    # от выхода, и Ctrl+C по долгому запросу вынес бы сессию целиком.
    rescue Interrupt
      refuse(Messages::COMPACT_INTERRUPTED)
    ensure
      @ui.status = nil
    end

    # Новая история собирается через History, а не правкой старой: только там
    # знают, из чего она состоит. Описание проекта этот путь уже проходило —
    # после /clear агент забывал про AGENTS.md, потому что история заводилась
    # мимо общей точки сборки.
    #
    # Отсюда же следует то, о чём надо предупреждать вслух: системный промпт
    # и описание проекта возвращаются В ПОЛНОМ ОБЪЁМЕ. Если место занято ими,
    # сворачивание почти ничего не даст.
    def rebuild(conversation, summary)
      before = ContextReport.new(conversation)
      # Отметка идёт ДО сборки новой истории, и порядок здесь вынужденный:
      # History#build пишет системный промпт в журнал сразу из конструктора
      # Conversation, так что запись после сборки оказалась бы уже внутри
      # новой истории. Отсюда и одно число вместо пары «до/после» — размер
      # свёрнутой истории на этот момент ещё не существует, а придумывать
      # поле, которого нет, ради симметрии не стоит: новые размеры видны
      # по сообщениям, идущим следом.
      @history.transcript&.compact(before: before.total)
      compacted = @history.build
      compacted.user(format(Messages::COMPACT_SUMMARY, content: summary.strip))

      after = ContextReport.new(compacted)
      report(before, after)
      compacted
    end

    # Сворачивание короткого диалога его УВЕЛИЧИВАЕТ: резюме плюс обёртка
    # вокруг него оказываются длиннее пары реплик, которые они заменили.
    # Рапортовать в этом случае «свёрнут» — врать в мелочи, которую видно
    # тут же по числам; поэтому случай назван своим именем.
    def report(before, after)
      message = after.total < before.total ? Messages::COMPACT_DONE : Messages::COMPACT_GREW
      @ui.puts(format(message, before: Plural.with(before.total, *Messages::CHARS), after: after.total))
      @ui.warn(Messages::COMPACT_PROJECT_DOMINATES) if after.project_dominates?
    end

    def refuse(message)
      @ui.warn(message)
      nil
    end
  end
end
