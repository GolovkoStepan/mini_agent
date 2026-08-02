# frozen_string_literal: true

module MiniAgent
  # Интерактивный режим: цикл «прочитать строку → выполнить задачу».
  #
  # Отдельно от Agent намеренно. Agent ведёт цикл ходов внутри одной задачи;
  # здесь — цикл задач с историей, командами и чтением ввода. Смешивать их
  # в одном классе значит держать рядом две разные петли с разными условиями
  # выхода.
  class Repl
    def initialize(agent:, config:, tools:, ui:, reader: nil)
      @agent = agent
      @config = config
      @ui = ui
      @reader = reader || LineReader.new
      @commands = SlashCommands.new(config: config, tools: tools, ui: ui)
    end

    # Возвращает историю: последняя Conversation остаётся доступной вызвавшему
    # коду и тестам — так же, как Agent#run возвращает историю, а не текст.
    def run
      greet
      conversation = new_conversation

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
    def handle(task, conversation)
      case @commands.call(task)
      when :exit then :exit
      when :handled then conversation
      when :clear then clear
      else
        @agent.run(task, conversation: conversation)
        conversation
      end
    end

    def new_conversation
      Conversation.new(project_context: @agent.project_context)
    end

    def clear
      @ui.puts(Messages::CMD_CLEARED)
      new_conversation
    end

    def greet
      @ui.assistant(Messages::INTERACTIVE_HEADER)
      @ui.puts(Messages::INTERACTIVE_HINT)
    end
  end
end
