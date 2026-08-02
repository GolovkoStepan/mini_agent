# frozen_string_literal: true

require "reline"

module MiniAgent
  # Чтение строки от пользователя в интерактивном режиме.
  #
  # На настоящем терминале работает Reline из stdlib: стрелка вверх поднимает
  # прошлые задачи, строку можно править по месту, а не только стирать целиком.
  # Вне терминала (пайп, StringIO в тестах) — обычный IO#gets: Reline там
  # бесполезен, а в тестах ещё и недетерминирован.
  #
  # Признак терминала проверяется у обоих потоков: Reline читает ввод и рисует
  # приглашение сам, и при выводе в файл он бы засорил его управляющими
  # последовательностями.
  class LineReader
    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
    end

    def interactive?
      tty?(@input) && tty?(@output)
    end

    # nil означает конец ввода (Ctrl+D) — как и у IO#gets, чтобы вызывающий
    # код не разбирался, каким из двух способов строка была прочитана.
    def gets(prompt)
      return read_plain(prompt) unless interactive?

      read_line(prompt)
    end

    private

    def read_line(prompt)
      Reline.input = @input
      Reline.output = @output

      line = Reline.readline(prompt, false)
      remember(line)
      line
    end

    # История ведётся вручную (readline(..., true) добавляет всё подряд):
    # пустые строки и повтор предыдущей задачи занимали бы место в истории,
    # ничего не добавляя, — до нужного пришлось бы жать стрелку лишние разы.
    def remember(line)
      text = line.to_s.strip
      return if text.empty? || Reline::HISTORY.last == text

      Reline::HISTORY.push(text)
    end

    def read_plain(prompt)
      @output.print(prompt)
      @output.flush if @output.respond_to?(:flush)
      @input.gets
    end

    def tty?(io)
      io.respond_to?(:tty?) && io.tty?
    end
  end
end
