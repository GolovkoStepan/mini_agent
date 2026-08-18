# frozen_string_literal: true

module MiniAgent
  # Задача в режиме планирования: изучить, показать план, спросить человека
  # и — если он согласен — выполнить его уже без ограничений.
  #
  # Отдельно от Repl по той же причине, по которой отдельно Initializer:
  # там цикл задач и чтение ввода, здесь один разговор из трёх частей.
  # Отдельно от Agent — потому что здесь спрашивают человека, а разовый
  # запуск (--plan) обязан обойтись без вопросов и просто напечатать план.
  class Planner
    def initialize(agent:, plan_mode:, ui:, prompt: nil)
      @agent = agent
      @plan_mode = plan_mode
      @ui = ui
      @prompt = prompt || Prompt.new
    end

    # Возвращает историю — ту, что вернул run, а не ту, что передали:
    # изучение проекта длинное, окно на нём кончается чаще всего, и после
    # автоматического сворачивания прежняя история уже не история сессии.
    def call(task, conversation)
      conversation = @agent.run(task, conversation: conversation)
      plan = @agent.answer
      return no_plan(conversation) if plan.nil? || plan.strip.empty?

      @plan_mode.plan = plan
      return keep(conversation) unless @prompt.confirm?(Messages::PLAN_CONFIRM)

      execute(conversation)
    end

    private

    # Плана нет: модель ответила вызовом инструмента до последнего хода,
    # запрос провалился или задачу прервали. Спрашивать «выполнять ли»
    # в таком случае не о чем — вопрос без плана перед ним выглядит как
    # предложение выполнить неизвестно что.
    def no_plan(conversation)
      @ui.warn(Messages::PLAN_MISSING)
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
    def execute(conversation)
      @plan_mode.disable
      @ui.puts(Messages::PLAN_APPROVED)
      @agent.run(format(Messages::PLAN_EXECUTE, plan: @plan_mode.plan), conversation: conversation)
    end
  end
end
