# frozen_string_literal: true

require "json"

module MiniAgent
  # Восстановление истории из журнала: обратная сторона Transcript.
  #
  # Читает записи в том порядке, в каком они делались, и повторяет над списком
  # сообщений то, что происходило с историей на самом деле: rollback снимает
  # снятое, compact и plan выбрасывают всё, что было заменено резюме или
  # планом. Без этого продолженная сессия отправила бы модели то, чего в её
  # истории уже не было, — и как раз в тех случаях, ради которых сворачивание
  # и делалось.
  #
  # Отдельный класс, а не метод Transcript: тот пишет и ничего не помнит,
  # этот читает чужой файл, где может лежать что угодно.
  class Replay
    # type и time — служебные поля записи, usage уходил только в журнал
    # (см. Conversation#push) и в сообщение возвращаться не должен.
    DROPPED = %w[type time usage].freeze

    # Записи, после которых история начинается заново: следующим сообщением
    # идёт свежий системный промпт. session здесь по той же причине — в один
    # файл (--log) пишутся несколько запусков подряд, и продолжать надо
    # последний, а не всё вместе.
    RESET = %w[session compact plan].freeze

    def initialize(path)
      @path = path
      @broken = 0
      @messages = parse
    end

    attr_reader :path, :messages, :broken

    def empty? = @messages.empty?

    # Кладёт восстановленные сообщения в историю и возвращает её.
    #
    # История берётся собранная заново, то есть с НЫНЕШНИМ системным
    # промптом: в нём рабочий каталог, система и описание проекта, а всё
    # это со вчерашней сессией могло измениться. Восстановить старый промпт
    # значило бы соврать модели про сегодняшнее окружение — и это при том,
    # что system-сообщение должно быть ровно одно и первое.
    #
    # Сообщения кладутся обычным путём, поэтому уходят и в журнал новой
    # сессии: файл остаётся самодостаточным, и продолжить можно продолженное.
    def into(conversation)
      @messages.each do |message|
        case message[:role]
        when "user" then conversation.user(message[:content])
        when "assistant" then conversation.assistant(message[:content], tool_calls: message[:tool_calls])
        when "tool" then conversation.tool(message[:tool_call_id], message[:content])
        end
      end
      conversation
    end

    private

    def parse
      messages = []
      File.foreach(@path) do |line|
        record = record(line)
        apply(record, messages) if record
      end
      trim(messages.reject { |message| message[:role] == "system" })
    end

    # Оборванная строка — обычное дело: журнал пишется по мере работы, и
    # последнюю запись убитого процесса могло не дописать. Считаем такие
    # строки, чтобы сказать о них при продолжении, но сессию из-за них
    # не бракуем.
    def record(line)
      JSON.parse(line)
    rescue JSON::ParserError
      @broken += 1
      nil
    end

    def apply(record, messages)
      case record["type"]
      when "message" then messages << message(record)
      when *RESET then messages.clear
      when "rollback" then messages.pop(record["removed"].to_i)
      end
    end

    def message(record)
      record.except(*DROPPED).transform_keys(&:to_sym)
    end

    # Хвост из вызовов инструментов, на которые не пришло ответа, остаётся
    # после Ctrl+C и после убитого процесса — то есть ровно после тех
    # сессий, которые и хотят продолжить. Модель ждёт ответа на каждый
    # tool_call_id, и такой хвост валит первый же запрос новой сессии.
    def trim(messages)
      index = messages.rindex { |message| message[:role] == "assistant" && message[:tool_calls] }
      return messages unless index

      answered = messages[(index + 1)..].filter_map { |message| message[:tool_call_id] }
      ids = messages[index][:tool_calls].map { |call| call["id"] || call[:id] }
      (ids - answered).empty? ? messages : messages[0, index]
    end
  end
end
