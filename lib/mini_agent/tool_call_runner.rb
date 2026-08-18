# frozen_string_literal: true

require "json"

module MiniAgent
  # Выполнение одного вызова инструмента: разбор аргументов, диспетчеризация,
  # усечение результата перед возвратом модели.
  #
  # Отделено от Agent по тому же признаку, что ChatResponse от LLMClient:
  # цикл ходов решает, что делать дальше, а здесь — как выполнить один вызов.
  # Общего состояния между ними нет, кроме истории, которая приходит
  # аргументом.
  class ToolCallRunner
    # Максимум символов результата инструмента, уходящих В МОДЕЛЬ.
    # Ограничение защищает контекстное окно и не связано с усечением,
    # которое UI применяет для читаемости консоли (UI::PREVIEW_LINES).
    MAX_TOOL_OUTPUT = 10_000

    # Сколько раз подряд один и тот же вызов терпится. Одиночный повтор
    # бывает осмысленным — перечитать файл после записи, повторить команду,
    # упавшую от чужой причины, — поэтому уровня два: на втором подряд
    # команда не выполняется и модели возвращается прежний результат
    # с припиской, на третьем задача обрывается.
    REPEAT_LIMIT = 2
    LOOP_LIMIT = 3

    def initialize(tools:, ui:)
      @tools = tools
      @ui = ui
      reset
    end

    # Счёт повторов ведётся внутри одной задачи, а не через всю сессию.
    # Объект один на агента, и без сброса первая же команда новой задачи,
    # совпавшая с последней командой прошлой, получила бы вместо выполнения
    # чужой результат — тем более обидно, что «покажи файлы» после «покажи
    # файлы» в интерактивном режиме дело обычное.
    def reset
      @last_key = nil
      @last_result = nil
      @repeats = 0
    end

    # Результат кладётся в историю здесь, а не возвращается наружу: у вызова
    # два исхода (ответ инструмента и жалоба на битые аргументы), и оба обязаны
    # попасть в историю — модель ждёт ответа на каждый tool_call_id, иначе
    # следующий запрос уходит с дырой.
    #
    # Наружу возвращается только исход: :ok или :loop. Второй означает, что
    # задачу пора обрывать, — решает это Agent, здесь для этого нет ни
    # признака выполненности, ни кода возврата.
    def call(conversation, tool_call)
      function = tool_call["function"] || {}
      name = function["name"].to_s
      tool_call_id = Conversation.tool_call_id(tool_call)

      arguments = parse_arguments(function["arguments"])
      unless arguments
        conversation.tool(tool_call_id, @last_parse_error)
        return :ok
      end

      count_repeat(name, arguments)
      return repeated(conversation, tool_call_id, name, arguments) if @repeats >= REPEAT_LIMIT

      execute(conversation, tool_call_id, name, arguments)
    end

    private

    # Сравнение дословное: имя и аргументы как есть, без нормализации.
    # Нормализация завела бы третью пару «формат и его разбор» (первые две —
    # EXIT_CODE/EXIT_CODE_PATTERN и разрез строки в CommandGuard), и разошлась
    # бы при первой правке. Ошибка дословного сравнения — пропустить повтор
    # с переставленным пробелом, то есть недосработать, а не оборвать
    # живую задачу.
    #
    # Считаются только вызовы подряд: чередование A, B, A, B здесь не ловится.
    # Окно из нескольких вызовов заводить не стали, пока такое чередование
    # не встретится живьём — замеченный случай был именно подряд идущим.
    def count_repeat(name, arguments)
      key = [name, arguments]
      @repeats = key == @last_key ? @repeats + 1 : 1
      @last_key = key
    end

    def execute(conversation, tool_call_id, name, arguments)
      @ui.tool_call(name, arguments)
      result = @tools.dispatch(name, arguments)
      @ui.tool_result(result)

      @last_result = truncate(result)
      conversation.tool(tool_call_id, @last_result)
      :ok
    end

    # Команда показывается на экране и при повторе: без неё ход выглядел бы
    # пропущенным, а понять, что агент топчется на месте, было бы не по чему.
    def repeated(conversation, tool_call_id, name, arguments)
      @ui.tool_call(name, arguments)

      if @repeats >= LOOP_LIMIT
        @ui.warn(Messages::LOOP_ABORTED)
        conversation.tool(tool_call_id, Messages::Tool::LOOPED)
        return :loop
      end

      @ui.warn(Messages::REPEATED_CALL)
      conversation.tool(tool_call_id, truncate(format(Messages::Tool::REPEATED, result: @last_result)))
      :ok
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
  end
end
