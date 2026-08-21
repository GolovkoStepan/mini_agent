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
    # Потолок символов результата инструмента, уходящих В МОДЕЛЬ.
    # Ограничение защищает контекстное окно и не связано с усечением,
    # которое UI применяет для читаемости консоли (UI::PREVIEW_LINES).
    #
    # Потолок остаётся потолком и при огромном окне: «слишком много для
    # одного вывода команды» и «не влезает в окно» — разные вещи. Тот же
    # довод, что у ProjectContext::MAX_CHARS и у Config#max_tokens.
    MAX_TOOL_OUTPUT = 10_000

    # Какую долю окна вправе занять один результат инструмента.
    #
    # Одно число не может быть верным и при окне 8192, и при 50176. Половину
    # окна уже забронировал ответ модели (Window::SHARE), от второй
    # половины половину вправе взять описание проекта (ProjectContext::SHARE) —
    # значит на диалог остаётся четверть окна, и отдавать её целиком одному
    # выводу команды нельзя. Отсюда восьмая часть: половина того, что вообще
    # достаётся работе. При окне 8192 это 1024 токена, то есть около 2560
    # знаков вместо прежних 10 000, которые там съедали весь остаток окна
    # за один вызов ls.
    #
    # Считается от Window::SHARE, а не задано числом, по той же причине, что
    # и SHARE у описания проекта: вырастет резерв под ответ — обязан ужаться
    # и вывод, иначе они вдвоём вытеснят диалог.
    SHARE = (1 - Window::SHARE) / 4

    # Сколько раз подряд один и тот же вызов терпится. Одиночный повтор
    # бывает осмысленным — перечитать файл после записи, повторить команду,
    # упавшую от чужой причины, — поэтому уровня два: на втором подряд
    # команда не выполняется и модели возвращается прежний результат
    # с припиской, на третьем задача обрывается.
    REPEAT_LIMIT = 2
    LOOP_LIMIT = 3

    # config необязателен: без него остаётся один потолок в знаках — ровно
    # то же, что при неизвестном размере окна.
    def initialize(tools:, ui:, config: nil)
      @tools = tools
      @ui = ui
      @config = config
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

    # Все вызовы одного хода. Живёт здесь, а не в цикле Agent, потому что
    # здесь же держится обещание «на каждый tool_call_id придёт ответ», а оно
    # и решает, когда обход можно оборвать, а когда нет.
    #
    # Обход не прерывается на первом же :loop: брошенный без ответа вызов
    # оставил бы в истории дыру, от которой валится следующий запрос — ровно
    # то, ради чего заведён rollback. Обрыв откладывается до конца обхода.
    #
    # Ctrl+C ту же дыру оставлял, и это воспроизведено пробой: три вызова
    # в ходу, прерывание на втором — assistant объявляет все три, а ответ
    # есть только у первого. В разовом запуске безвредно (агент выходит),
    # в интерактивном режиме — нет: история остаётся и уходит со следующей
    # задачей. Откатом это не лечится, в отличие от провалившегося запроса:
    # первый инструмент уже отработал и мог изменить файлы, а Ctrl+C значит
    # «останови», а не «сделай вид, что ничего не было».
    def call_all(conversation, tool_calls)
      answered = 0
      statuses = tool_calls.map do |tool_call|
        status = call(conversation, tool_call)
        answered += 1
        status
      end
      statuses.include?(:loop) ? :loop : :ok
    rescue Interrupt
      abandon(conversation, tool_calls.drop(answered))
      raise
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

    # Первый недошедший вызов — тот, на котором пришёл Ctrl+C: он выполнялся
    # и был убит на полпути. Остальные не начинались вовсе, и это известно
    # точно — потому и ответы разные.
    def abandon(conversation, pending)
      pending.each_with_index do |tool_call, index|
        text = index.zero? ? Messages::Tool::INTERRUPTED : Messages::Tool::NOT_RUN
        conversation.tool(Conversation.tool_call_id(tool_call), text)
      end
    end

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
      return text if text.length <= limit

      text[0, limit] + Messages::TRUNCATED_SUFFIX
    end

    # Спрашивается на каждом усечении, а не запоминается в конструкторе:
    # размер окна узнаётся у сервера при старте соединения, то есть уже
    # после сборки агента. Та же причина, по которой Config#max_tokens —
    # вычисление, а не поле.
    def limit
      window = @config&.context_window
      return MAX_TOOL_OUTPUT unless window

      [(window * SHARE * Window::CHARS_PER_TOKEN).to_i, MAX_TOOL_OUTPUT].min
    end
  end
end
