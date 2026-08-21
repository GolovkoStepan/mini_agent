# frozen_string_literal: true

require "shellwords"

module MiniAgent
  # Правка плана в $EDITOR перед одобрением.
  #
  # Третий ответ на вопрос «выполнять?»: план почти всегда верен на три
  # четверти, и до сих пор оставалось либо согласиться целиком, либо
  # отказаться и переписывать задачу словами, надеясь, что модель поправит
  # именно тот пункт. Правка снимает и то и другое: файл уже написан
  # (PlanStore пишет его ДО вопроса), редактор открывается на нём.
  #
  # ФАЙЛ — ИСТОЧНИК ИСТИНЫ, а не PlanMode#plan. После редактора план
  # перечитывается с диска целиком, а не сравнивается с прежним текстом:
  # человек мог поправить один знак, а мог переписать всё. Обратное — взять
  # исходный текст и «применить к нему правки» — означало бы второй источник
  # одного плана, и разошлись бы они на первом же несохранённом буфере.
  class PlanEditor
    # VISUAL раньше EDITOR: первый означает полноэкранный редактор, второй
    # исторически мог быть строчным (ed). Порядок тот же, что у git.
    ENV_KEYS = %w[VISUAL EDITOR].freeze

    # runner инъектируется ради тестов: настоящий редактор захватил бы
    # терминал и подвесил прогон. Команда передаётся строкой, а не списком,
    # намеренно — в EDITOR кладут и «code -w», и «emacsclient -nw».
    def initialize(ui:, env: ENV, runner: nil)
      @ui = ui
      @env = env
      @runner = runner || ->(command) { system(command) }
    end

    # Возвращает новый текст плана либо nil, если править не вышло.
    # nil значит «план прежний» — вызывающий спросит заново.
    def call(path)
      return warn(Messages::PLAN_EDIT_NO_FILE) if path.nil?

      editor = chosen
      return warn(Messages::PLAN_EDIT_NO_EDITOR) if editor.nil?

      @ui.puts(format(Messages::PLAN_EDIT_OPEN, editor: editor, path: path))
      # Код возврата редактора не отменяет чтения: файл мог быть сохранён
      # до сбоя, и он всё равно вернее нашей памяти о прежнем тексте.
      @ui.warn(Messages::PLAN_EDIT_FAILED) unless @runner.call("#{editor} #{Shellwords.escape(path)}")
      read(path)
    end

    private

    # Пустое значение переменной — это «не задано», а не редактор с пустым
    # именем: `EDITOR= mini_agent` иначе запускал бы оболочку от пустой строки.
    def chosen
      @env.values_at(*ENV_KEYS).compact.map(&:strip).reject(&:empty?).first
    end

    def read(path)
      PlanStore.body(path)
    rescue SystemCallError, IOError => e
      warn(format(Messages::PLAN_EDIT_READ_FAILED, message: e.message))
    end

    # Возвращает nil заодно с предупреждением: у всех отказов здесь один
    # исход — план остаётся прежним, и вопрос задаётся снова.
    def warn(message)
      @ui.warn(message)
      nil
    end
  end
end
