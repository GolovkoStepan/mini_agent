# frozen_string_literal: true

module MiniAgent
  # Набор размеченной строки по ширине терминала.
  #
  # Выделено из Markdown порогом Metrics/ClassLength — в девятый раз он указал
  # верно. Разбор разметки отвечает на вопрос «что это за кусок текста», набор —
  # «где кончается строка»; общего у них только тип данных на границе.
  #
  # На вход идут сегменты — пары «текст, стиль», уже разобранные Markdown.
  # Раскраска накладывается в самом конце: ANSI-коды занимают знаки в строке,
  # но не столбцы на экране, и покрасить раньше значит посчитать их за текст
  # (ошибка, уже описанная в Spinner#line).
  class TextWrap
    # Уже ниже этого переносить нечего: строка из двух слов читается хуже
    # неперенесённой. Отказ от переноса честнее обрубка.
    MIN_WIDTH = 40

    # indent — отступ продолжений, hang — дополнительный отступ под висячий
    # список. width задаётся только в тестах: настоящую ширину спрашиваем
    # у терминала на каждой строке, потому что окно меняют посреди генерации.
    def initialize(paint:, indent:, width: nil)
      @paint = paint
      @indent = indent
      @width = width
    end

    def call(segments, hang: "")
      # Сравнивается ширина терминала, а не остаток после отступов: остаток
      # у пункта списка на 40 колонках сам по себе меньше сорока, и проверка
      # по нему отключала бы перенос ровно там, где он нужнее всего.
      return paint_parts(segments) if width < MIN_WIDTH

      lines(segments, width - @indent.length - hang.length)
        .map(&:first)
        .join("\n#{@indent}#{hang}")
    end

    # Разбитые по ширине строки: пары «раскрашенный текст, длина без раскраски».
    # Длина отдаётся вместе с текстом, потому что по готовой строке её уже
    # не измерить — ANSI-коды занимают знаки, но не столбцы. Нужна тому, кто
    # выравнивает колонки (Table): подкладка пробелами считается по столбцам.
    #
    # hard — рвать ли слово, которое длиннее лимита. В прозе не рвём (см. fill),
    # в ячейке таблицы рвём: вылезшее слово сдвигает всю строку, и колонки
    # перестают быть колонками, то есть пропадает единственное, ради чего
    # таблица и рисуется.
    def lines(segments, limit, hard: false)
      items = words(segments)
      items = items.flat_map { |word| chop(word, limit) } if hard
      fill(items, limit).map do |line|
        parts = merge(line_parts(line))
        [paint_parts(parts), parts.sum { |content, _| content.length }]
      end
    end

    def width = @width || Terminal.width

    private

    # Слова, каждое — список своих кусков со стилями. Слово, а не кусок,
    # потому что разметка кончается посреди слова: `код`, — это «код» и «,»
    # разными сегментами, и набор по кускам вставил бы между ними пробел.
    # Выравнивание пробелами внутри строки теряется — для прозы это неважно,
    # а код и так не переносится.
    def words(segments)
      result = []
      current = nil
      segments.each do |content, style|
        content.split(/(\s+)/).reject(&:empty?).each do |part|
          if part.match?(/\A\s+\z/)
            current = nil
          elsif current
            current << [part, style]
          else
            result << (current = [[part, style]])
          end
        end
      end
      result
    end

    # Длинное слово (URL, путь) не рвём: разорванный путь нельзя ни
    # скопировать, ни прочитать. Пусть вылезает за край — это честнее.
    def fill(words, limit)
      lines = [[]]
      length = 0
      words.each do |word|
        size = word.sum { |content, _| content.length }
        if lines.last.any? && length + 1 + size > limit
          lines << []
          length = 0
        end
        length += lines.last.any? ? size + 1 : size
        lines.last << word
      end
      lines.reject(&:empty?)
    end

    # Слово, разрезанное по лимиту, — несколько слов. Режется по кускам,
    # а не по готовой строке: раскраска накладывается позже, и разрез
    # по ней пришёлся бы на середину ANSI-кода.
    def chop(word, limit)
      return [word] if limit < 1 || word.sum { |content, _| content.length } <= limit

      pieces = [[]]
      room = limit
      word.each { |part| room = cut(pieces, part, room, limit) }
      pieces.reject(&:empty?)
    end

    # Кусок укладывается в остаток строки, что не влезло — переносится
    # в следующую. Отдаёт новый остаток.
    def cut(pieces, part, room, limit)
      text, style = part
      until text.empty?
        take = text[0, room]
        pieces.last << [take, style]
        text = text[take.length..]
        room -= take.length
        next unless room.zero?

        pieces << []
        room = limit
      end
      room
    end

    # Строка обратно из слов, с пробелами между ними. Пробел получает стиль
    # соседей, когда он у них общий: иначе `make spec` разъехался бы на два
    # раскрашенных куска с бесцветной дыркой посередине.
    def line_parts(words)
      words.each_with_object([]) do |word, parts|
        parts << [" ", gap_style(parts.last, word.first)] if parts.any?
        parts.concat(word)
      end
    end

    def gap_style(previous, following)
      previous && following && previous[1] == following[1] ? previous[1] : nil
    end

    # Соседние куски одного стиля склеиваются до раскраски: иначе каждое
    # слово внутри `команды с пробелами` получило бы свою пару ANSI-кодов.
    def merge(parts)
      parts.each_with_object([]) do |(content, style), result|
        if result.any? && result.last[1] == style
          result.last[0] << content
        else
          result << [+content, style]
        end
      end
    end

    def paint_parts(parts)
      parts.map { |content, style| style ? @paint.call(content, style) : content }.join
    end
  end
end
