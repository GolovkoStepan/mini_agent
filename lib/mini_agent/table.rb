# frozen_string_literal: true

module MiniAgent
  # Раскладка таблицы markdown: на входе сырые строки блока, на выходе готовые
  # строки без отступа — отступ ставит Markdown#emit, как и всем прочим.
  #
  # Отдельным классом по тому же сигналу, что развёл Markdown с TextWrap:
  # порог Metrics/ClassLength. Разбор строки отвечает «что это за кусок текста»,
  # набор — «где кончается строка», а здесь решается третье: сколько столбцов
  # отдать каждой колонке.
  #
  # Рамок нет намеренно: два пробела между колонками и тонкая линия под
  # заголовком. Вертикали и уголки съедают по три знака на границу — ту самую
  # ширину, которой не хватает ровно там, где таблица и разъезжается.
  class Table
    # Зазор между колонками. Два пробела, а не один: колонка, кончающаяся
    # пробелом внутри ячейки, иначе слипается со следующей.
    GAP = "  "

    RULE = "─"

    # Уже этого колонку не ужимаем: на пяти знаках перенос даёт лесенку
    # по букве, и это хуже вылезшей за край таблицы. Тот же отказ, что
    # у TextWrap::MIN_WIDTH.
    MIN_CELL = 6

    ROW = /\A\s*\|/

    # Экранированная `\|` — часть ячейки, а не граница. Без этого одна
    # такая ячейка сдвигала бы всю строку на колонку влево.
    PIPE = /(?<!\\)\|/

    DIVIDER = /\A:?-+:?\z/

    def self.row?(line) = ROW.match?(line)

    def self.divider?(line)
      return false unless row?(line)

      marks = cells(line)
      marks.any? && marks.all? { |mark| DIVIDER.match?(mark) }
    end

    # Блок с `|`, но без строки разделителя, таблицей не является: это обычный
    # текст, и печатать его надо как есть. Заголовок без ячеек (одинокая `|`)
    # — тот же случай: колонок нет, и рисовать нечего, а промолчать значило бы
    # съесть строку молча.
    def self.table?(rows) = rows.length > 1 && divider?(rows[1]) && cells(rows.first).any?

    def self.cells(line)
      parts = line.strip.split(PIPE, -1)
      parts.shift if parts.first.to_s.strip.empty?
      parts.pop if parts.any? && parts.last.to_s.strip.empty?
      parts.map { |cell| cell.strip.gsub("\\|", "|") }
    end

    # inline — разметка ячейки, метод Markdown#inline (приём тот же, что
    # у paint в UI). wrap — общий с абзацами укладчик: второй такой разошёлся
    # бы с первым при первой правке.
    def initialize(inline:, wrap:, indent: "")
      @inline = inline
      @wrap = wrap
      @indent = indent
    end

    def call(rows)
      columns = self.class.cells(rows.first).length
      grid = grid(rows, columns)
      draw(grid, widths(grid, columns), alignments(rows[1], columns))
    end

    private

    # Число колонок задаёт заголовок: короткая строка добивается пустыми,
    # длинная режется. Так же поступает GFM, а рваные строки у модели — дело
    # обычное, и разъехавшаяся на одной строке таблица хуже потерянной ячейки.
    def grid(rows, columns)
      head = segments(rows.first, columns, style: :bold)
      rows.drop(2).each_with_object([head]) do |row, result|
        result << segments(row, columns, style: nil)
      end
    end

    # Заголовок жирный: стиль подставляется только тем кускам, у которых своего
    # нет, — `код` в заголовке остаётся серым.
    def segments(row, columns, style:)
      cells = self.class.cells(row)
      Array.new(columns) do |index|
        parts = @inline.call(cells[index].to_s)
        next parts unless style

        parts.map { |content, own| [content, own.empty? ? [style] : own] }
      end
    end

    def widths(grid, columns)
      fit(Array.new(columns) { |index| grid.map { |row| measure(row[index]) }.max })
    end

    def measure(cell) = cell.sum { |content, _| content.length }

    # Место отнимается у самой широкой колонки, а не поровну: короткий «Статус»
    # терял бы столько же, сколько длинный путь, и первым перестал бы читаться.
    # Ширина всей таблицы: колонки плюс зазоры между ними.
    def span(widths) = widths.sum + (GAP.length * (widths.length - 1))

    def fit(widths)
      limit = @wrap.width - @indent.length - (GAP.length * (widths.length - 1))
      result = widths.dup
      while result.sum > limit
        widest = result.each_index.max_by { |index| [result[index], -index] }
        break if result[widest] <= MIN_CELL

        result[widest] -= 1
      end
      result
    end

    def alignments(divider, columns)
      marks = self.class.cells(divider.to_s)
      Array.new(columns) { |index| alignment(marks[index].to_s) }
    end

    def alignment(mark)
      return :center if mark.start_with?(":") && mark.end_with?(":")
      return :right if mark.end_with?(":")

      :left
    end

    def draw(grid, widths, alignments)
      head, *body = grid
      lines = row_lines(head, widths, alignments)
      lines << (RULE * span(widths))
      body.each { |row| lines.concat(row_lines(row, widths, alignments)) }
      lines
    end

    # Строка таблицы высотой в самую высокую свою ячейку; недостающие строки
    # у соседей пустые.
    def row_lines(row, widths, alignments)
      wrapped = row.each_with_index.map { |cell, index| wrap_cell(cell, widths[index]) }
      Array.new(wrapped.map(&:length).max) do |line|
        wrapped.each_with_index
               .map { |cell, index| pad(cell[line], widths[index], alignments[index]) }
               .join(GAP).rstrip
      end
    end

    # Пустая ячейка — это одна пустая строка, а не ноль строк: иначе строка
    # таблицы, где пусто всё, исчезла бы вовсе.
    def wrap_cell(cell, width)
      lines = @wrap.lines(cell, width, hard: true)
      lines.empty? ? [["", 0]] : lines
    end

    # Подкладка считается по длине без раскраски — ANSI-коды занимают знаки,
    # но не столбцы (ошибка, уже описанная в Spinner#line).
    def pad(piece, width, alignment)
      text, length = piece || ["", 0]
      space = [width - length, 0].max
      case alignment
      when :right then "#{" " * space}#{text}"
      when :center then "#{" " * (space / 2)}#{text}#{" " * (space - (space / 2))}"
      else "#{text}#{" " * space}"
      end
    end
  end
end
