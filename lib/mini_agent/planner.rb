# frozen_string_literal: true

module MiniAgent
  # Задача в режиме планирования: изучить, сохранить план, спросить человека
  # и — если он согласен — выполнить его уже без ограничений.
  #
  # Отдельно от Repl по той же причине, по которой отдельно Initializer:
  # там цикл задач и чтение ввода, здесь один разговор из трёх частей.
  # Отдельно от Agent — потому что здесь спрашивают человека, а разовый
  # запуск (--plan) обязан обойтись без вопросов и просто напечатать план.
  class Planner
    # Ответы на вопрос «выполнять?». Заведены таблицей, а не разбором строки
    # по месту: буквы названы в самом вопросе (PLAN_CONFIRM), и два списка
    # разошлись бы при первой правке текста.
    APPROVE = "y"
    EDIT = "e"

    def initialize(agent:, plan_mode:, ui:, prompt: nil, store: nil, config: nil, editor: nil)
      @agent = agent
      @plan_mode = plan_mode
      @ui = ui
      @prompt = prompt || Prompt.new
      @store = store || PlanStore.new
      @config = config
      @editor = editor || PlanEditor.new(ui: ui)
    end

    # Возвращает историю — ту, что вернул run, а не ту, что передали:
    # изучение проекта длинное, окно на нём кончается чаще всего, и после
    # автоматического сворачивания прежняя история уже не история сессии.
    #
    # confirm: false — разовый запуск (--plan): план сохраняется и печатается,
    # вопроса нет и выполнения нет. Вопрос задают там, где есть у кого.
    def call(task, conversation, confirm: true)
      conversation = @agent.run(task, conversation: conversation)
      plan = @agent.answer
      return no_plan(conversation) if plan.nil? || plan.strip.empty?

      @plan_mode.plan = plan
      path = save(plan, task)
      return one_shot(conversation) unless confirm

      decide(conversation, path)
    end

    private

    # После правки вопрос задаётся снова, а не считается согласием: открыть
    # план в редакторе — не то же самое, что одобрить его, и «поправил, глянул,
    # передумал» обязано остаться возможным. Цикл заодно переживает отказы
    # самой правки (не задан EDITOR, файл не записался): план прежний, вопрос
    # прежний, повторять его дешевле, чем терять уже составленный план.
    def decide(conversation, path)
      loop do
        case @prompt.ask(Messages::PLAN_CONFIRM)
        when APPROVE then return execute(conversation, path)
        when EDIT then return keep(conversation) if edit(path) == :empty
        else return keep(conversation)
        end
      end
    end

    # nil от редактора — «план прежний»: спрашиваем заново, ничего не трогая.
    # Пустой файл после правки — отказ, а не план из ничего: очистить буфер,
    # чтобы передумать, — то же соглашение, что у git commit.
    def edit(path)
      text = @editor.call(path)
      return :again if text.nil?

      if text.strip.empty?
        @ui.puts(Messages::PLAN_EDIT_EMPTY)
        return :empty
      end

      @plan_mode.plan = text
      @ui.puts(Messages::PLAN_EDITED)
      :again
    end

    # Файл пишется ДО вопроса, а не после согласия: «нет» означает «не
    # выполнять», а не «выбросить». Уточняют план обычно как раз тогда, когда
    # ответили «нет», и сравнить его с предыдущим можно только по файлу.
    def save(plan, task)
      path = @store.save(plan, task: task, config: @config)
      if path
        @ui.puts(format(Messages::PLAN_SAVED, path: path))
      else
        @ui.warn(format(Messages::PLAN_SAVE_FAILED, message: @store.error))
      end
      path
    end

    # Плана нет: модель ответила вызовом инструмента до последнего хода,
    # запрос провалился или задачу прервали. Спрашивать «выполнять ли»
    # в таком случае не о чем — вопрос без плана перед ним выглядит как
    # предложение выполнить неизвестно что.
    def no_plan(conversation)
      @ui.warn(Messages::PLAN_MISSING)
      conversation
    end

    # Про невыполненный план говорится прямо: ответ модели — это план, и без
    # строки под ним он читается как отчёт о сделанном.
    def one_shot(conversation)
      @ui.puts(Messages::PLAN_ONE_SHOT)
      conversation
    end

    def keep(conversation)
      @ui.puts(Messages::PLAN_KEPT)
      conversation
    end

    # Режим выключается до запуска, а не после: выполнение идёт обычным
    # ходом агента, и оставленный включённым режим отверг бы первую же
    # команду из только что одобренного плана.
    #
    # Обратно он сам не включается. План одобрен — работа продолжается
    # обычной; кому нужен следующий план, тот скажет /plan.
    #
    # История исследования при этом ВЫБРАСЫВАЕТСЯ, а не продолжается. План
    # и есть резюме исследования — структурированное и одобренное человеком,
    # то самое, ради чего иначе пришлось бы звать /compact. Сворачивание
    # моделью стоило бы целого хода и дало бы ей ещё один повод нафантазировать,
    # а десятки выводов ls и cat, на которых план уже построен, дальше только
    # занимают окно — то есть ровно то, из-за чего небольшая сеть и портится.
    # new_conversation (History#build) собирает промпт, описание проекта, cwd
    # и журнал заново и обнуляет «контекст сейчас»; сам план переживает это
    # в PlanMode#plan, для того он там и хранится.
    def execute(conversation, path)
      @plan_mode.disable
      @ui.puts(Messages::PLAN_APPROVED)
      @agent.run(format(Messages::PLAN_EXECUTE, plan: @plan_mode.plan), conversation: reset(conversation, path))
    end

    # Отметка в журнал ставится ПЕРЕД сборкой новой истории — иначе окажется
    # внутри неё. Тот же вынужденный порядок, что у Transcript#compact,
    # и та же причина: молчаливый сброс развёл бы журнал с реальностью,
    # и по логу выглядело бы, будто модель ни с того ни с сего забыла
    # всё, что только что изучила.
    def reset(conversation, path)
      size = conversation.size
      @agent.transcript&.plan(before: size, path: path)
      @ui.puts(format(Messages::PLAN_CONTEXT_RESET, before: Plural.with(size, *Messages::MESSAGES_WORD)))
      @agent.new_conversation
    end
  end
end
