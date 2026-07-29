# frozen_string_literal: true

module MiniAgent
  # Реестр доступных модели инструментов.
  #
  # В исходном скрипте инструмент был ровно один и диспетчеризация сводилась
  # к сравнению имени со строкой "bash". Реестр позволяет добавить второй
  # инструмент, не трогая цикл агента.
  class ToolRegistry
    def initialize(tools = [])
      @tools = {}
      tools.each { |tool| register(tool) }
    end

    def register(tool)
      @tools[tool.name] = tool
      self
    end

    def schemas
      @tools.values.map(&:schema)
    end

    def names
      @tools.keys
    end

    def empty?
      @tools.empty?
    end

    # Никогда не бросает исключение: неизвестный инструмент — это сообщение
    # модели о её ошибке, а не аварийная остановка агента.
    def dispatch(name, arguments)
      tool = @tools[name.to_s]
      return format(Messages::UNKNOWN_TOOL, name: name) unless tool

      begin
        tool.call(arguments)
      rescue StandardError => e
        format(Messages::TOOL_FAILED, name: name, message: e.message)
      end
    end
  end
end
