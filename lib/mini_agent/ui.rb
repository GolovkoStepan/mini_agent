# frozen_string_literal: true

require "json"

module MiniAgent
  # Весь вывод в терминал.
  #
  # Иерархия держится на маркере, отступе и цвете, а не на рамках: каждое
  # событие начинается с BULLET, вывод инструмента уходит под BRANCH с
  # отступом. Рамки и баннеры не используются намеренно — они занимают
  # больше места, чем несут смысла, и разъезжаются на узком терминале.
  #
  # Поток вывода и признак TTY внедряются через конструктор: при tty: false
  # раскраска отключается, а спиннер вообще не запускает поток — благодаря
  # этому тесты детерминированы и не спят.
  class UI
    # Сколько строк вывода инструмента показывать пользователю.
    # Это ограничение ТОЛЬКО для читаемости консоли; лимит того, что уходит
    # в модель, живёт отдельно в ToolCallRunner::MAX_TOOL_OUTPUT.
    PREVIEW_LINES = 5
    PREVIEW_CHARS = 500

    # Сколько строк команды показывать в заголовке вызова.
    #
    # Отдельно от PREVIEW_LINES: тот про вывод команды, этот про саму
    # команду. Ограничения у результата не было вовсе, и запись файла через
    # heredoc печатала весь файл в скобках — 30 строк содержимого давали
    # 33 строки заголовка. Асимметрия была непреднамеренной.
    #
    # Три строки, а не пять: у команды информативно начало (что запускаем),
    # а у вывода — весь показанный кусок.
    COMMAND_LINES = 3
    COMMAND_CHARS = 200

    BULLET = "●"
    BRANCH = "⎿"
    INDENT = "    "

    SPINNER_INTERVAL = Spinner::INTERVAL

    # width задаётся только в тестах — тем же приёмом, что и spinner_interval:
    # настоящую ширину спрашивают у терминала, и она разная на каждой машине,
    # а по ней режется и бегущая строка, и разметка. Параметр один на обоих
    # потребителей: два способа узнать одно число разошлись бы при первой правке.
    #
    # Разметка выключается и флагом, и отсутствием терминала. Вне TTY она
    # не просто не нужна — она вредна: буферизация до перевода строки поменяла
    # бы разбивку перенаправленного в файл вывода. Тот же порядок, что
    # у Color.paint: терминал перебивает флаг.
    def initialize(out: $stdout, tty: nil, spinner_interval: SPINNER_INTERVAL, width: nil, markdown: true)
      @out = out
      @tty = tty.nil? ? out.respond_to?(:tty?) && out.tty? : tty
      @spinner = Spinner.new(ui: self, enabled: @tty, interval: spinner_interval, width: width)
      @markdown = if markdown && @tty
                    Markdown.new(paint: method(:paint), width: width)
                  else
                    Markdown::Plain.new
                  end
      @streaming = false
      @streamed = false
      @line_open = false
    end

    # Строка состояния (например, «ход 2/10») и ход генерации. Передаются
    # присваиванием, а не через конструктор: значения меняются на каждой
    # итерации, а объект UI один на всю сессию.
    def status=(text)
      @spinner.status = text
    end

    def progress=(text)
      @spinner.progress = text
    end

    def ticker=(text)
      @spinner.ticker = text.nil? ? nil : Color.escape(text)
    end

    def tty? = @tty

    def puts(text = "")
      @out.puts(text)
    end

    def print(text)
      @out.print(text)
      @out.flush if @out.respond_to?(:flush)
    end

    # Текст модели экранируется на входе в терминал — здесь, в stream_chunk
    # и в ticker=, то есть во всех трёх местах, где он на экран попадает.
    # Управляющая последовательность в ответе способна перекрасить вывод,
    # стереть строку или сдвинуть курсор, а значит подделать сообщения самого
    # агента: предупреждение охраны выглядит такой же строкой, как любая
    # другая, и «Продолжить выполнение?» можно нарисовать поверх чужого текста.
    #
    # Вывод команд при этом НЕ экранируется намеренно: `ls --color` и
    # `git diff` печатают ANSI законно, и подчистив их, агент испортил бы
    # то, ради чего команду и запускали. Граница проходит по источнику —
    # текст модели против вывода машины, — а не по опасности знаков.
    #
    # Ответ модели. При стриминге текст уже напечатан по кускам, и печатать
    # его второй раз нельзя — признак снимается здесь, а не проверяется
    # в Agent: тот про способ доставки знать не обязан, у него один вызов
    # на оба режима.
    def assistant(content)
      return @streamed = false if @streamed

      puts("\n#{paint(BULLET, :green)} #{@markdown.render(Color.escape(content))}")
    end

    # Кусок ответа модели по мере генерации.
    #
    # Спиннер гасится здесь, а не в вызывающем коде: он рисует себя в ту же
    # строку и затирал бы первые знаки ответа. Маркер печатается один раз —
    # у первого куска, дальше идёт голый текст, поэтому итоговый вид совпадает
    # с обычным assistant.
    #
    # С разметкой кусок часто не даёт на экран ничего: строка копится до
    # перевода. Поэтому и спиннер, и маркер откладываются до первого настоящего
    # текста — иначе анимация гасла бы, а на её месте оставалась пустота.
    def stream_chunk(text)
      emit_stream(@markdown.feed(Color.escape(text)))
    end

    # Ответ закончился. Перевод строки печатается только если что-то шло:
    # на ответе из одних вызовов инструментов лишняя пустая строка разорвала
    # бы блок «● Bash(...)» пополам.
    def stream_finish
      emit_stream(@markdown.flush)
      return unless @streaming

      @streaming = false
      # Показанный текст не должен печататься повторно: следом Agent зовёт
      # assistant с тем же содержимым. Признак одноразовый — гасится первым
      # же вызовом, иначе следующий ответ (например, из непотокового
      # /compact) молча пропал бы.
      @streamed = true
      # Рендерер отдаёт готовые строки вместе с переводом, и безусловный
      # puts дорисовывал бы пустую строку под каждым размеченным ответом.
      puts("") if @line_open
    end

    def warn(text)
      puts("#{paint(BULLET, :yellow)} #{text}")
    end

    def error(text)
      puts("#{paint(BULLET, :red)} #{text}")
    end

    # Заголовок вида «● Bash(ls -la lib)»: имя инструмента с заглавной,
    # аргумент в скобках. Для bash в скобках сама команда, для прочих —
    # компактный JSON.
    #
    # Аргумент усекается: запись файла через heredoc — это вся будущая
    # начинка файла одной командой, и без ограничения она печаталась целиком.
    # В модель уходит полный текст в любом случае, здесь только экран.
    # В скобках заголовка — то, к чему вызов относится: команда у bash, путь
    # у файловых инструментов. JSON целиком остаётся запасным вариантом для
    # инструмента, о котором мы ничего не знаем; у write_file он показал бы
    # весь записываемый файл в экранированном виде — ровно тот шум, ради
    # которого заведено усечение команды.
    def tool_call(name, arguments)
      argument = arguments["command"] || arguments["path"] || arguments.to_json
      puts("\n#{paint(BULLET, :blue)} #{paint(title(name), :bold)}(#{shorten(argument)})")
    end

    # Пользователю показываем усечённо — полный текст всё равно уходит модели.
    def tool_result(result)
      code, body = split_exit_code(result)
      # Пустой stdout при непустом stderr оставляет ведущий перевод строки:
      # для модели это разделитель секций, а на экране — пустая строка.
      # Режем только переводы строк: пробелы в начале несут выравнивание
      # колонок (вывод wc, ls), и strip его бы поломал.
      lines = body.gsub(/\A\n+|\n+\z/, "").lines
      shown = preview(lines)

      puts("  #{paint(BRANCH, :gray)} #{exit_code_label(code)}") if code&.positive?
      shown.each_with_index { |line, index| puts(prefix(index, code) + paint(line.chomp, :gray)) }
      print_ellipsis(lines.size - shown.size)
    end

    # Разбивка контекста по категориям (/context). Сама печать — в
    # ContextView: там три источника чисел со своими «неизвестно» и три
    # предупреждения с разным лечением, а здесь остаётся маркер и цвет.
    def context(report)
      ContextView.new(self).call(report)
    end

    # Открыт ради ContextView: раскраска знает про tty, и второй такой
    # выключатель разошёлся бы с этим при первой же правке.
    def paint(text, *styles)
      Color.paint(text, *styles, enabled: @tty)
    end

    # Список моделей сервера с пометкой выбранной: ради этого сравнения
    # команду обычно и запускают.
    def models(names, selected:, url:)
      puts(format(Messages::MODELS_HEADER, url: url))
      names.each do |name|
        marker = name == selected ? Messages::MODEL_SELECTED : Messages::MODEL_PLAIN
        puts(format(marker, name: name))
      end
    end

    def with_spinner(&) = @spinner.around(&)

    # Погасить спиннер досрочно, не дожидаясь конца блока. Нужен стримингу:
    # там ответ начинает печататься посреди запроса, а спиннер рисует себя
    # в ту же строку.
    def stop_spinner = @spinner.stop

    private

    # Показать то, что рендерер отдал на печать. Пусто — значит строка ещё
    # не дописалась: ни спиннер гасить, ни маркер печатать не за чем.
    def emit_stream(text)
      return if text.empty?

      unless @streaming
        stop_spinner
        @streaming = true
        print("\n#{paint(BULLET, :green)} ")
      end

      print(text)
      @line_open = !text.end_with?("\n")
    end

    # Имя инструмента для заголовка: write_file → WriteFile. capitalize
    # оставлял бы «Write_file» — подчёркивание в заголовке выглядит опечаткой.
    def title(name) = name.to_s.split("_").map(&:capitalize).join

    # Команда для заголовка: не длиннее COMMAND_LINES строк и COMMAND_CHARS
    # знаков. Отброшенное называется числом строк, а не многоточием: по нему
    # видно, много ли скрыто, — так же, как в выводе команды.
    def shorten(text)
      lines = text.to_s.lines
      return text if lines.size <= COMMAND_LINES && text.to_s.length <= COMMAND_CHARS

      shown = lines.take(COMMAND_LINES).join.rstrip[0, COMMAND_CHARS]
      hidden = lines.size - shown.lines.size
      return "#{shown}…" unless hidden.positive?

      "#{shown}\n#{INDENT}#{format(Messages::COMMAND_ELLIPSIS, count: Plural.with(hidden, *Messages::LINES))}"
    end

    # Первая строка результата — «Код выхода: N» от Tools::Bash. Человеку
    # она нужна только когда команда упала, поэтому отрезаем её от тела и
    # показываем отдельной пометкой лишь при ненулевом коде.
    def split_exit_code(result)
      match = Messages::EXIT_CODE_PATTERN.match(result)
      return [nil, result] unless match

      [match[1].to_i, match.post_match]
    end

    def print_ellipsis(hidden)
      return unless hidden.positive?

      text = format(Messages::OUTPUT_ELLIPSIS, count: Plural.with(hidden, *Messages::LINES))
      puts(INDENT + paint(text, :gray))
    end

    def exit_code_label(code)
      paint(format(Messages::EXIT_CODE_LABEL, code: code), :red)
    end

    def preview(lines)
      return lines unless lines.sum(&:length) > PREVIEW_CHARS || lines.size > PREVIEW_LINES

      lines.take(PREVIEW_LINES)
    end

    # Ветка BRANCH ставится один раз — у первой строки блока. Если пометка
    # кода выхода уже её заняла, тело идёт ровным отступом.
    def prefix(index, code)
      return INDENT unless index.zero? && !code&.positive?

      "  #{paint(BRANCH, :gray)} "
    end
  end
end
