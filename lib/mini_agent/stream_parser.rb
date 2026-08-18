# frozen_string_literal: true

require "json"

module MiniAgent
  # Накопление ответа из потока SSE (`stream: true`).
  #
  # Парный к ChatResponse и делает ту же работу с другого конца: там готовый
  # ответ разбирается на части, здесь части собираются в ответ. Разделены
  # потому, что разбор целого — это чтение полей, а сборка из кусков — это
  # состояние: незакрытая строка на границе чтения, номера вызовов, порядок
  # прихода. Смешав их, мы получили бы класс, в котором половина полей нужна
  # только в одном из двух режимов.
  #
  # Формат: строки `data: {…}`, разделённые пустой строкой, признак конца —
  # `data: [DONE]`. Всё, что не начинается с `data:` (комментарии `:` для
  # поддержания соединения), пропускается.
  class StreamParser
    DATA_PREFIX = "data:"
    DONE = "[DONE]"

    # Сколько знаков размышлений показывать бегущей строкой.
    TAIL_LIMIT = 400

    def initialize(&on_delta)
      @on_delta = on_delta
      @buffer = +""
      @content = +""
      @reasoning = +""
      @tool_calls = {}
      @usage = nil
      @finish_reason = nil
    end

    attr_reader :usage, :finish_reason

    # Размышления модели целиком (reasoning_content). В историю не уходят
    # никогда — их место в журнале, где по ним разбирают обрыв: сейчас при
    # нём видно только, что текста нет, а не на чём модель его потратила.
    #
    # Копится весь текст, хотя показывается лишь хвост: парсер живёт один
    # запрос и уезжает вместе с ним, так что речь о десятках килобайт на ход,
    # а не о росте через всю сессию.
    attr_reader :reasoning

    # Сколько знаков размышлений уже пришло. По нему видно, на что модель
    # тратит бюджет, когда ответ приходит пустым.
    def reasoning_length = @reasoning.length

    # То, что модель думает прямо сейчас: бегущая строка в спиннере. Объём
    # отвечает на вопрос «занята ли она», а чем именно занята, до этого было
    # не видно вовсе — на длинной задаче это десятки тысяч знаков молчания.
    #
    # Больше ширины терминала показать нельзя в принципе; запас против неё
    # нужен на схлопывание пробелов при отрисовке. Срез по знакам, а не по
    # байтам: по байтам он развалил бы русскую букву надвое — та же ошибка,
    # что ловилась на границе кусков сокета, только с другого конца.
    def reasoning_tail = @reasoning[-TAIL_LIMIT..] || @reasoning

    # Кусок тела как он пришёл из сокета. Границы кусков не совпадают с
    # границами строк, поэтому хвост остаётся в буфере до следующего вызова.
    #
    # Байты приходят в ASCII-8BIT, и многобайтный символ может быть разрезан
    # ровно посередине: у русского текста это каждый второй символ. Поэтому
    # кодировка назначается не куску, а собранной строке — на границе
    # чтения UTF-8 ещё нет.
    def feed(chunk)
      @buffer << chunk.to_s.dup.force_encoding(Encoding::BINARY)

      while (index = @buffer.index("\n"))
        line = @buffer.slice!(0..index)
        handle(line.chomp.force_encoding(Encoding::UTF_8))
      end
    end

    def content = @content.strip

    # Вызовы инструментов в том же виде, в каком их отдаёт обычный ответ:
    # дальше по коду разницы между потоковым и обычным режимом быть не должно.
    # Порядок — по index из дельт, а не по времени прихода.
    def tool_calls
      @tool_calls.keys.sort.map { |index| @tool_calls[index] }
    end

    # Тот же кортеж, что у ChatResponse: Agent разбирает оба одинаково.
    def to_a = [content, tool_calls, usage, finish_reason]

    # Поток не принёс ничего: ни текста, ни вызова, ни причины остановки.
    #
    # Это не «модели нечего сказать», а несостоявшийся ответ: сервер закрыл
    # соединение, прокси отдала 200 с пустым телом, эндпоинт не умеет stream
    # и молча вернул ничего. Различать обязательно — иначе такой случай уходит
    # наверх пустым текстом и агент завершается с кодом 0, ничего не сделав.
    # Ровно тот диагноз-обманка, из-за которого заводилась обработка
    # finish_reason.
    #
    # Причина остановки учитывается наравне с содержимым: ответ из одних
    # вызовов инструментов текста не содержит вовсе, и без неё он выглядел
    # бы пустым.
    def empty?
      content.empty? && tool_calls.empty? && finish_reason.nil?
    end

    private

    def handle(line)
      return unless line.start_with?(DATA_PREFIX)

      payload = line.delete_prefix(DATA_PREFIX).strip
      return if payload.empty? || payload == DONE

      apply(JSON.parse(payload))
    rescue JSON::ParserError
      # Битый кусок не повод ронять весь ответ: остальные придут целыми,
      # а недостача видна по итоговому тексту.
      nil
    end

    # usage приезжает ОТДЕЛЬНЫМ куском с пустым choices — проверено на
    # LM Studio при stream_options.include_usage. Обращение к choices[0]
    # без этой оговорки роняло бы разбор на последнем куске.
    def apply(data)
      @usage = data["usage"] if data["usage"]

      choice = data.dig("choices", 0)
      return unless choice

      @finish_reason = choice["finish_reason"] if choice["finish_reason"]
      delta = choice["delta"]
      accumulate(delta) if delta.is_a?(Hash)
    end

    def accumulate(delta)
      @reasoning << delta["reasoning_content"] if delta["reasoning_content"]

      text = delta["content"]
      if text && !text.empty?
        @content << text
        @on_delta&.call(text)
      end

      merge_tool_calls(delta["tool_calls"])
    end

    # Вызовы приходят кусками: первый несёт id и имя, следующие — куски
    # аргументов, и объединять их надо по index, а не по порядку прихода.
    # При нескольких вызовах разом дельты чередуются, и склейка «по последнему»
    # смешала бы аргументы разных вызовов в один JSON.
    def merge_tool_calls(calls)
      return unless calls.is_a?(Array)

      calls.each do |call|
        index = call["index"] || 0
        target = (@tool_calls[index] ||= new_tool_call)

        target["id"] = call["id"] if call["id"]
        target["type"] = call["type"] if call["type"]
        merge_function(target["function"], call["function"])
      end
    end

    def merge_function(target, source)
      return unless source.is_a?(Hash)

      target["name"] = source["name"] if source["name"]
      target["arguments"] << source["arguments"].to_s if source["arguments"]
    end

    def new_tool_call
      { "id" => nil, "type" => "function", "function" => { "name" => nil, "arguments" => +"" } }
    end
  end
end
