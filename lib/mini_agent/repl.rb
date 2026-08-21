# frozen_string_literal: true

module MiniAgent
  # Интерактивный режим: цикл «прочитать строку → выполнить задачу».
  #
  # Отдельно от Agent намеренно. Agent ведёт цикл ходов внутри одной задачи;
  # здесь — цикл задач с историей, командами и чтением ввода. Смешивать их
  # в одном классе значит держать рядом две разные петли с разными условиями
  # выхода.
  class Repl
    # conversation — восстановленная история (--resume) либо nil. Заводить
    # свою пустую здесь нельзя: она собирается агентом (описание проекта,
    # журнал, каталог), и второе место сборки уже расходилось с первым.
    # Действует один раз: /clear на то и очистка, чтобы начать с чистого
    # листа, а не перечитать продолженную сессию заново.
    def initialize(agent:, config:, tools:, ui:, reader: nil, conversation: nil)
      @agent = agent
      @config = config
      @ui = ui
      @resumed = conversation
      @reader = reader || LineReader.new
      # Тот же объект, что у агента и у охраны команд: свой означал бы
      # включённый режим, о котором не знает ни один из них.
      @plan_mode = agent.plan_mode
      @commands = SlashCommands.new(config: config, tools: tools, ui: ui, usage: agent.usage)
    end

    # Возвращает историю: последняя Conversation остаётся доступной вызвавшему
    # коду и тестам — так же, как Agent#run возвращает историю, а не текст.
    def run
      greet
      conversation = @resumed || new_conversation

      loop do
        line = read_line
        break if line == :exit
        next if line == :retry
        break if line.nil? # Ctrl+D

        task = line.chomp
        next if task.strip.empty?

        result = handle(task, conversation)
        break if result == :exit

        conversation = result
      end

      @ui.puts(Messages::GOODBYE)
      conversation
    end

    private

    # Ctrl+C на приглашении: первый раз бросает набранную строку и печатает
    # подсказку, второй подряд — выходит. Одиночный Ctrl+C выходом не делаем
    # намеренно: в интерактивном режиме им обычно отменяют начатую мысль,
    # и потерять из-за этого всю историю диалога — не то, чего ждут.
    #
    # Счётчик сбрасывается любой другой строкой: два Ctrl+C, разделённые
    # работой, — это две разные отмены, а не намерение выйти.
    # Пустая строка печатается отдельно, а не входит в приглашение: Reline
    # считает промпт одной строкой и рисует "\n" литералом («\n> »).
    def read_line
      @ui.puts("")
      line = @reader.gets(Messages::PROMPT_SIGN)
      @interrupts = 0
      line
    rescue Interrupt
      @interrupts = @interrupts.to_i + 1
      return :exit if @interrupts >= 2

      @ui.puts("")
      @ui.warn(Messages::INTERRUPT_HINT)
      :retry
    end

    # Возвращает историю для следующей итерации либо :exit.
    #
    # Ветки :clear и :compact обе отдают НОВУЮ историю, и возвращаемое
    # значение здесь не формальность: именно оно уезжает в следующую
    # итерацию цикла. Вернуть conversation вместо результата — значит
    # продолжить работу со старой историей, ничего при этом не сломав
    # заметно.
    #
    # По той же причине берётся и результат run: обычная задача историю
    # тоже подменяет, если по ходу дела сработало автоматическое
    # сворачивание. Прежде здесь стояло `@agent.run(...); conversation`,
    # и это было безобидно ровно до тех пор, пока новую историю заводили
    # только команды.
    def handle(task, conversation)
      case @commands.call(task, conversation: conversation)
      when :exit then :exit
      when :handled then conversation
      when :clear then clear
      when :compact then @agent.compact(conversation)
      when :init then init(conversation)
      when :plan then toggle_plan(conversation)
      else run_task(task, conversation)
      end
    end

    # В режиме планирования задача идёт через Planner: тот доводит её до плана
    # и спрашивает, выполнять ли. Ветвление здесь, а не внутри Agent#run,
    # потому что вопрос человеку задавать можно не всегда: разовый запуск
    # с --plan печатает план и выходит.
    def run_task(text, conversation)
      return @agent.plan(text, conversation) if @plan_mode.on?

      @agent.run(text, conversation: conversation)
    end

    # /init пишет файл — то самое, чего режим планирования не делает. Отказ
    # стоит здесь, а не приходит отказом инструмента: иначе агент потратил бы
    # полдюжины ходов на изучение проекта и не смог бы записать результат.
    def init(conversation)
      return @agent.init(conversation) unless @plan_mode.on?

      @ui.warn(Messages::PLAN_INIT_BLOCKED)
      conversation
    end

    # Переключатель, а не две команды: включённый режим виден по строке при
    # включении и по отказам в работе, а /plan набирают, когда хотят сменить
    # положение — какое именно, человек и так знает.
    def toggle_plan(conversation)
      if @plan_mode.on?
        @plan_mode.disable
        @ui.puts(Messages::PLAN_OFF)
      else
        @plan_mode.enable
        @ui.puts(Messages::PLAN_ON)
      end
      conversation
    end

    def new_conversation
      @agent.new_conversation
    end

    def clear
      @ui.puts(Messages::CMD_CLEARED)
      new_conversation
    end

    def greet
      @ui.assistant(format(Messages::INTERACTIVE_HEADER, version: MiniAgent::VERSION))
      @ui.puts(Messages::INTERACTIVE_HINT)
    end
  end
end
