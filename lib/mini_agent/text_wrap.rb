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

      lines = fill(words(segments), width - @indent.length - hang.length)
      lines.map { |line| paint_parts(merge(line_parts(line))) }
           .join("\n#{@indent}#{hang}")
    end

    private

    def width = @width || Terminal.width

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
