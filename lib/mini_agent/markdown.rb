# frozen_string_literal: true

module MiniAgent
  # Разметка ответа модели в терминале: заголовки, списки, код, перенос
  # по ширине окна.
  #
  # Свой рендерер, а не гем. tty-markdown тянет полдюжины зависимостей
  # в проект, где их ноль, и рендерит только документ целиком — то есть
  # со стримингом несовместим в самой основе, а стриминг здесь и есть
  # обычный режим.
  #
  # Инвариант, из которого следует всё остальное: РАЗМЕТКА НИКОГДА
  # НЕ РАЗБИРАЕТСЯ НА КУСКЕ, ТОЛЬКО НА ЦЕЛОЙ СТРОКЕ. Границы кусков сокета
  # не совпадают ни с чем: «**жир» и «ный**» приходят порознь, и разбор
  # по куску увидел бы одинокую звёздочку. В проекте это уже ловилось
  # в StreamParser#feed, только там резало символ пополам, а здесь режет
  # разметку. Отсюда буфер до перевода строки: отрисовывается готовая
  # строка, хвост без \n ждёт flush.
  #
  # Следствие, ради которого заведён тест: потоковый и обычный режим дают
  # на одном тексте один и тот же вывод. render — это feed + flush.
  class Markdown
    # Отступ продолжений. Ровно ширина маркера «● », который UI печатает
    # перед первой строкой ответа: так продолжения выравниваются по тексту,
    # а не по маркеру. Меняя одно, проверьте другое.
    INDENT = "  "

    MARKER = "• "

    FENCE = /\A\s*```/
    HEADING = /\A\s{0,3}(\#{1,6})\s+(.*)\z/
    BULLET = /\A(\s*)[-*+]\s+(.*)\z/
    NUMBERED = /\A(\s*)(\d+[.)])\s+(.*)\z/

    # Разбор строки на куски со стилями. Порядок важен: код разбирается
    # первым, иначе `**` внутри `code` съел бы жирный.
    INLINE = [
      [/`([^`]+)`/, :gray],
      [/\*\*([^*]+)\*\*/, :bold],
      [/__([^_]+)__/, :bold],
      [/(?<![*\w])\*([^*\n]+)\*(?!\*)/, :dim]
    ].freeze

    # paint — раскраска от UI: она знает про TTY, и второй такой выключатель
    # разошёлся бы с первым. width задаётся только в тестах: настоящую ширину
    # спрашиваем у терминала на каждой строке, потому что окно меняют посреди
    # генерации.
    def initialize(paint: nil, width: nil)
      @paint = paint || ->(text, *_styles) { text }
      @wrap = TextWrap.new(paint: @paint, indent: INDENT, width: width)
      reset
    end

    # Кусок потока. Возвращает то, что уже можно печатать: целые строки
    # вместе с переводами. Незаконченная строка остаётся в буфере.
    def feed(chunk)
      @buffer << chunk.to_s
      return "" unless @buffer.include?("\n")

      lines = @buffer.split("\n", -1)
      @buffer = lines.pop.to_s
      lines.filter_map { |line| render_line(line) }.join
    end

    # Хвост без перевода строки плюс сброс состояния. Состояние сбрасывается
    # именно здесь: рендерер живёт всю сессию, а незакрытый ``` из прошлого
    # ответа отдал бы следующий дословно и без разметки.
    def flush
      tail = @buffer.empty? ? "" : render_line(@buffer).to_s.chomp
      reset
      tail
    end

    # Целый текст сразу (непотоковый режим). Через feed и flush, а не своим
    # путём: два способа отрисовать одно разошлись бы, и разошлись бы молча —
    # разница видна только тому, кто сравнил режимы на одном ответе.
    def render(text)
      "#{feed(text)}#{flush}".chomp
    end

    # Разметка выключена: текст проходит насквозь и БЕЗ буферизации.
    # Полиморфизмом, а не проверкой признака в трёх местах, — тем же приёмом,
    # что Prompt::AutoApprove. Буферизация здесь была бы не оптимизацией,
    # а изменением поведения: вывод в файл получил бы другую разбивку строк.
    class Plain
      def feed(chunk) = chunk.to_s
      def flush = ""
      def render(text) = text.to_s
    end

    private

    def reset
      @buffer = +""
      @code = false
      @started = false
    end

    # nil означает «печатать нечего»: так исчезают строки ограды ```.
    # Пустая строка от них отличается — она разделяет абзацы.
    def render_line(line)
      return toggle_code if line.match?(FENCE)
      # Внутри блока кода строка отдаётся дословно: ни разметки, ни переноса.
      # Перенесённая команда выглядит копируемой и таковой не является —
      # именно это и есть цена «красивого» переноса кода.
      return emit(@paint.call(line, :gray)) if @code

      emit(block(line))
    end

    def toggle_code
      @code = !@code
      nil
    end

    # Пустая строка остаётся пустой: отступ на ней дал бы висящие пробелы,
    # видимые при выделении мышью и в перенаправленном выводе.
    def emit(text)
      prefix = @started && !text.empty? ? INDENT : ""
      @started = true
      "#{prefix}#{text}\n"
    end

    def block(line)
      if (match = HEADING.match(line))
        @paint.call(match[2].strip, :bold)
      elsif (match = BULLET.match(line))
        item(match[1], MARKER, match[2])
      elsif (match = NUMBERED.match(line))
        # Номер печатается тот, что написала модель. Пересчёт скрыл бы её
        # же дефект — сбитую нумерацию, — ради борьбы с которым всё
        # и затевалось.
        item(match[1], "#{match[2]} ", match[3])
      else
        @wrap.call(inline(line))
      end
    end

    # Висячий отступ: продолжения пункта встают под его текст, а не под
    # маркер. Иначе второй строкой список неотличим от нового пункта.
    def item(lead, marker, text)
      hang = " " * (lead.length + marker.length)
      "#{lead}#{marker}#{@wrap.call(inline(text), hang: hang)}"
    end

    # Строка режется на пары «текст + стиль» ДО набора по ширине и до
    # раскраски. Обратный порядок — сперва покрасить, потом переносить —
    # даёт ошибку, уже описанную в Spinner#line: ANSI-коды занимают знаки
    # в строке, но не столбцы на экране, и перенос считал бы их за текст.
    def inline(text)
      segments = [[text, nil]]
      INLINE.each do |pattern, style|
        segments = segments.flat_map { |part| part[1] ? [part] : split(part[0], pattern, style) }
      end
      segments.reject { |content, _| content.empty? }
    end

    def split(text, pattern, style)
      result = []
      rest = text
      while (match = pattern.match(rest))
        result << [match.pre_match, nil] << [match[1], style]
        rest = match.post_match
      end
      result << [rest, nil]
    end
  end
end
