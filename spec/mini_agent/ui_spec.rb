# frozen_string_literal: true

RSpec.describe MiniAgent::UI do
  let(:out) { StringIO.new }

  subject(:ui) { described_class.new(out: out, tty: false) }

  it "не раскрашивает вывод вне терминала" do
    ui.error("сломалось")

    expect(out.string).to eq("● сломалось\n")
    expect(out.string).not_to include("\e[")
  end

  it "раскрашивает вывод в терминале" do
    tty_ui = described_class.new(out: out, tty: true)
    tty_ui.error("сломалось")

    expect(out.string).to include("\e[31m")
  end

  it "помечает маркером ответ ассистента" do
    ui.assistant("готово")

    expect(out.string).to include("● готово")
  end

  describe "#tool_call" do
    it "показывает команду для bash" do
      ui.tool_call("bash", { "command" => "ls -la" })

      expect(out.string).to include("● Bash(ls -la)")
    end

    it "показывает аргументы JSON для прочих инструментов" do
      ui.tool_call("search", { "query" => "ruby" })

      expect(out.string).to include('{"query":"ruby"}')
    end

    # У write_file JSON целиком — это весь записываемый файл в экранированном
    # виде: ровно тот шум, ради которого заведено усечение команды.
    it "показывает путь у файловых инструментов, а не начинку файла" do
      ui.tool_call("write_file", { "path" => "lib/a.rb", "content" => "class A\nend\n" })

      expect(out.string).to include("● WriteFile(lib/a.rb)")
      expect(out.string).not_to include("class A")
    end

    # Запись файла через heredoc — это вся начинка файла одной командой.
    # Без ограничения 30 строк содержимого давали 33 строки заголовка;
    # у результата команды лимит был, у самой команды — нет.
    it "усекает многострочную команду" do
      ui.tool_call("bash", { "command" => "cat > f <<EOF\n#{(1..30).map { |i| "строка #{i}" }.join("\n")}\nEOF" })

      expect(out.string).to include("cat > f <<EOF", "строка 1", "… ещё 29 строк команды")
      expect(out.string).not_to include("строка 30")
    end

    it "усекает длинную команду в одну строку" do
      ui.tool_call("bash", { "command" => "echo #{"слово " * 100}" })

      expect(out.string).to include("…")
      expect(out.string.lines.first(3).join.length).to be < 300
    end

    # Ровно на границе усечения быть не должно: обрезанная команда без
    # нужды выглядит как обрезанная по ошибке.
    it "не трогает короткую многострочную команду" do
      ui.tool_call("bash", { "command" => "a\nb\nc" })

      expect(out.string).to include("● Bash(a\nb\nc)")
      expect(out.string).not_to include("…")
    end
  end

  describe "#tool_result" do
    it "показывает короткий вывод целиком" do
      ui.tool_result("одна строка\n")

      expect(out.string).to include("⎿ одна строка")
      expect(out.string).not_to include("+")
    end

    it "обрезает длинный вывод для читаемости" do
      ui.tool_result((1..50).map { |i| "строка #{i}" }.join("\n"))

      expect(out.string).to include("строка 5")
      expect(out.string).not_to include("строка 6")
      expect(out.string).to include("… +45 строк")
    end

    # «+1 строк» — та же недоделка, что и «34 знаков», просто замеченная
    # позже: 45 скрытых строк случайно попадали в верную форму.
    it "согласует число скрытых строк" do
      ui.tool_result((1..6).map { |i| "строка #{i}" }.join("\n"))

      expect(out.string).to include("… +1 строка")
    end

    # Код выхода нужен модели всегда, человеку — только когда команда упала.
    it "не показывает нулевой код выхода" do
      ui.tool_result("Код выхода: 0\nвсё хорошо\n")

      expect(out.string).to include("⎿ всё хорошо")
      expect(out.string).not_to include("код выхода")
    end

    it "помечает ненулевой код выхода" do
      ui.tool_result("Код выхода: 1\ncat: нет файла\n")

      expect(out.string).to include("⎿ код выхода 1")
      expect(out.string).to include("cat: нет файла")
    end

    # Пустой stdout перед секцией STDERR давал пустую строку в блоке.
    it "не оставляет пустую строку при выводе только в stderr" do
      ui.tool_result("Код выхода: 1\n\nSTDERR:\ncat: нет файла\n")

      expect(out.string).not_to match(/⎿ код выхода 1\n\s*\n/)
      expect(out.string).to include("STDERR:")
    end

    # Пробелы в начале строки выравнивают колонки (wc, ls) — их резать нельзя.
    it "сохраняет ведущие пробелы выравнивания" do
      ui.tool_result("Код выхода: 0\n     150 agent.rb\n      46 color.rb\n")

      expect(out.string).to include("⎿      150 agent.rb")
    end
  end

  describe "#context" do
    def report(project_context: nil, usage: nil, config: nil)
      talk = MiniAgent::Conversation.new(system_prompt: "промпт", project_context: project_context)
      talk.user("почини тесты")
      MiniAgent::ContextReport.new(talk, usage: usage, config: config)
    end

    def tokens(count)
      MiniAgent::Usage.new.tap { |u| u.add({ "prompt_tokens" => count, "completion_tokens" => 7 }) }
    end

    def settings(window:, max_tokens: 1000)
      MiniAgent::Config.new({ context_window: window, max_tokens: max_tokens }, env: {})
    end

    it "печатает категории, доли и итог" do
      ui.context(report)

      expect(out.string).to include("Контекст: 2 сообщения", "системный промпт", "задачи", "всего", "%")
    end

    # «34 знаков» в целиком русском интерфейсе читается как недоделка ровно
    # там, где всё остальное выверено. Найдено живой проверкой /context.
    it "согласует числительные" do
      talk = MiniAgent::Conversation.new(system_prompt: "a" * 34)
      talk.user("b")

      ui.context(MiniAgent::ContextReport.new(talk))

      expect(out.string).to include("34 знака", "1 знак", "35 знаков")
      expect(out.string).not_to include("34 знаков", "1 знаков")
    end

    it "показывает описание проекта отдельной строкой" do
      ui.context(report(project_context: "тесты: make spec"))

      expect(out.string).to include("описание проекта")
    end

    it "печатает токены по данным сервера" do
      usage = MiniAgent::Usage.new
      usage.add({ "prompt_tokens" => 57, "completion_tokens" => 7 })

      ui.context(report(usage: usage))

      expect(out.string).to include("57 токенов")
    end

    # Ноль означал бы «промпт пустой», а не «измерить нечем».
    it "без данных сервера говорит об этом прямо, а не печатает ноль" do
      ui.context(report)

      expect(out.string).to include("не сообщал")
      expect(out.string).not_to include("0 токенов")
    end

    it "на пустом контексте не рисует таблицу" do
      empty = MiniAgent::ContextReport.new(MiniAgent::Conversation.new(system_prompt: nil))

      ui.context(empty)

      expect(out.string).to include("пуст")
      expect(out.string).not_to include("всего")
    end

    it "предупреждает, когда место занято описанием проекта" do
      ui.context(report(project_context: "описание " * 200))

      expect(out.string).to include("/compact его не тронет")
    end

    describe "контекстное окно" do
      # Слагаемыми, а не одной суммой: «3000 из 8192» не отвечало на вопрос,
      # занято это или свободно, и умалчивало, что резерв под ответ входит
      # в первое число. Замечание из живой работы.
      it "печатает заполнение окна слагаемыми" do
        ui.context(report(usage: tokens(2000), config: settings(window: 8192)))

        expect(out.string).to include("окно модели: 8192 токена")
        expect(out.string).to include("история        2000")
        expect(out.string).to include("резерв ответ   1000")
        expect(out.string).to include("свободно       5192  (37% занято)")
      end

      # Резерв не влезает в окно: «свободно -8700» читалось бы как ошибка
      # счёта, хотя это ровно тот случай, ради которого отчёт заводился.
      it "называет нехватку места нехваткой, а не отрицательным остатком" do
        ui.context(report(usage: tokens(5000), config: settings(window: 8192, max_tokens: 8000)))

        expect(out.string).to include("не хватает     4808")
        expect(out.string).not_to include("свободно")
      end

      # Незнание показывается прямо: молчание выглядело бы как «считать
      # нечего», хотя причина другая — протокол этого числа не передаёт.
      it "говорит, что размер окна неизвестен" do
        ui.context(report(usage: tokens(2000)))

        expect(out.string).to include("размер окна неизвестен", "--context-window")
      end

      # Размер известен, но usage не пришёл: строки про заполнение нет,
      # а жаловаться на незнание размера не на что.
      it "молчит о заполнении, когда сервер не прислал usage" do
        ui.context(report(config: settings(window: 8192)))

        expect(out.string).not_to include("окно модели", "размер окна неизвестен")
      end

      it "предупреждает о тесноте" do
        ui.context(report(usage: tokens(6000), config: settings(window: 8192, max_tokens: 500)))

        expect(out.string).to include("Окно заполнено на 79%", "/compact")
      end

      # Тот самый случай, что дал «пустой ответ» в живой работе. Лечится
      # не сворачиванием, поэтому и сообщение отдельное.
      it "отдельно предупреждает, что на ответ места не осталось" do
        ui.context(report(usage: tokens(5000), config: settings(window: 8192, max_tokens: 4096)))

        expect(out.string).to include("На ответ остаётся 3192", "max_tokens 4096", "Уменьшите --max-tokens")
      end

      # max_tokens — разрешение, а не бронь: при остатке 6035 и лимите 7000
      # живая проверка дала полный ответ, потому что модель уложилась в 800
      # токенов. Обещать обрыв значило бы врать ровно тогда, когда всё
      # в порядке, — такие предупреждения перестают читать.
      it "предупреждает о риске, а не обещает обрыв" do
        ui.context(report(usage: tokens(5000), config: settings(window: 8192, max_tokens: 4096)))

        expect(out.string).to include("длинный ответ оборвётся на 3192")
      end

      # Найдено живой проверкой: раздельные предупреждения противоречили
      # друг другу — «/compact его не тронет» и тут же «пора звать /compact».
      # По отдельности каждое было верным, потому тесты и молчали.
      it "не советует /compact, когда окно занято описанием проекта" do
        big = report(
          project_context: "описание " * 200, usage: tokens(6000),
          config: settings(window: 8192, max_tokens: 500)
        )

        ui.context(big)

        expect(out.string).to include("занято оно описанием проекта", "уменьшать надо сам файл")
        expect(out.string).not_to include("пора звать /compact")
      end

      # А когда тесно не из-за описания — совет про /compact на месте.
      it "советует /compact, когда тесно от самого диалога" do
        ui.context(report(usage: tokens(6000), config: settings(window: 8192, max_tokens: 500)))

        expect(out.string).to include("пора звать /compact")
      end

      it "на просторном окне не предупреждает ни о чём" do
        ui.context(report(usage: tokens(1000), config: settings(window: 65_536, max_tokens: 4096)))

        expect(out.string).to include("окно модели: 65536 токенов", "свободно      60440")
        expect(out.string).not_to include("Окно заполнено", "На ответ остаётся")
      end
    end
  end

  describe "#with_spinner" do
    it "возвращает значение блока" do
      expect(ui.with_spinner { 42 }).to eq(42)
    end

    # Вне TTY анимация не нужна, а лишний поток делает тесты недетерминированными.
    it "не создаёт поток вне терминала" do
      before_count = Thread.list.size
      ui.with_spinner { expect(Thread.list.size).to eq(before_count) }
    end

    it "пробрасывает исключение блока" do
      expect { ui.with_spinner { raise ArgumentError, "сбой" } }.to raise_error(ArgumentError, "сбой")
    end

    context "в терминале" do
      subject(:ui) { described_class.new(out: out, tty: true, spinner_interval: 0.01) }

      it "останавливает поток после блока" do
        before_count = Thread.list.size
        ui.with_spinner { sleep 0.05 }

        expect(Thread.list.size).to eq(before_count)
        expect(out.string).to include("Думаю")
      end

      # Номер хода показывается только здесь и стирается вместе со спиннером.
      it "подмешивает строку состояния" do
        ui.status = "ход 2/10"
        ui.with_spinner { sleep 0.05 }

        expect(out.string).to include("ход 2/10")
      end

      # ensure обязан снять спиннер даже при исключении, иначе поток
      # останется висеть до конца процесса.
      it "останавливает поток при исключении в блоке" do
        before_count = Thread.list.size

        expect { ui.with_spinner { raise "сбой" } }.to raise_error("сбой")
        expect(Thread.list.size).to eq(before_count)
      end

      # Ход размышлений: на рассуждающей модели их вдесятеро больше самого
      # ответа, и без этой строки поток выглядел бы как обычное ожидание.
      it "показывает ход размышлений" do
        ui.progress = "(размышления: 240 знаков)"
        ui.with_spinner { sleep 0.05 }

        expect(out.string).to include("размышления: 240 знаков")
      end

      # Спиннер и текст ответа делят одну строку: без досрочной остановки
      # анимация затирала бы первые знаки.
      #
      # stream_finish здесь обязателен: с разметкой строка копится до перевода,
      # и без завершения потока хвост так и остался бы в буфере рендерера.
      it "гасится досрочно и не мешает тексту" do
        before_count = Thread.list.size

        ui.with_spinner do
          sleep 0.03
          ui.stop_spinner
          ui.stream_chunk("ответ")
          ui.stream_finish
        end

        expect(Thread.list.size).to eq(before_count)
        expect(out.string).to end_with("ответ\n")
      end

      it "переживает повторную остановку" do
        ui.with_spinner { ui.stop_spinner }

        expect { ui.stop_spinner }.not_to raise_error
      end

      # Счётчик отвечает на вопрос «занята ли модель», бегущая строка —
      # «чем именно». На живой задаче счётчик доходил до 25 000 знаков,
      # и всё это время о содержании работы не было известно ничего.
      describe "бегущая строка" do
        subject(:ui) { described_class.new(out: out, tty: true, spinner_interval: 0.01, width: 80) }

        it "показывает текст размышлений" do
          ui.ticker = "проверяю файл agent.rb"
          ui.with_spinner { sleep 0.05 }

          expect(out.string).to include("проверяю файл agent.rb")
        end

        # Хвост, а не начало: интересно то, что модель думает сейчас.
        it "режет строку слева, оставляя свежее" do
          ui.status = "ход 2/10"
          ui.ticker = "#{"старое " * 40}свежее"
          ui.with_spinner { sleep 0.05 }

          expect(out.string).to include("свежее")
        end

        # Спиннер живёт в одной строке и перерисовывает её по \r: перевод
        # строки внутри оставил бы на экране обрывки, до которых \e[K уже
        # не дотянется.
        it "схлопывает переводы строк" do
          ui.ticker = "первая\nвторая"
          ui.with_spinner { sleep 0.05 }

          expect(out.string).to include("первая вторая")
          expect(out.string).not_to include("первая\nвторая")
        end

        # Строка, заполнившая ширину ровно, переносится, и перерисовка по \r
        # начинает мазать по экрану. Проверяется видимая длина — без ANSI.
        it "не выходит за ширину терминала" do
          ui.status = "ход 2/10"
          ui.ticker = "мысль " * 100
          ui.with_spinner { sleep 0.05 }

          drawn = out.string.split("\r").map { |part| part.gsub(/\e\[[0-9;]*[A-Za-z]/, "") }
          expect(drawn.map(&:length).max).to be < 80
        end

        # На узком терминале обрывок в несколько знаков не читается, а место
        # отнимает у счётчика — там бегущая строка пропадает целиком.
        it "пропадает, когда места не осталось" do
          narrow = described_class.new(out: out, tty: true, spinner_interval: 0.01, width: 30)
          narrow.status = "ход 2/10"
          narrow.ticker = "мысль"
          narrow.with_spinner { sleep 0.05 }

          expect(out.string).to include("ход 2/10")
          expect(out.string).not_to include("мысль")
        end

        # Гаснет вместе со спиннером: иначе размышления прошлого хода
        # осели бы под следующим запросом.
        it "гаснет вместе со спиннером" do
          ui.ticker = "мысль"
          ui.with_spinner { sleep 0.05 }
          out.truncate(out.rewind)

          ui.with_spinner { sleep 0.05 }

          expect(out.string).not_to include("мысль")
        end
      end
    end
  end

  describe "потоковый вывод" do
    it "печатает маркер один раз, а текст — по кускам" do
      ui.stream_chunk("при")
      ui.stream_chunk("вет")
      ui.stream_finish

      expect(out.string).to eq("\n● привет\n")
    end

    # Следом Agent зовёт assistant с тем же содержимым: показанный текст
    # не должен печататься второй раз.
    it "не печатает показанный текст повторно" do
      ui.stream_chunk("привет")
      ui.stream_finish
      ui.assistant("привет")

      expect(out.string.scan("привет").size).to eq(1)
    end

    # Признак одноразовый: иначе следующий ответ — например, непотоковое
    # резюме /compact — молча пропал бы.
    it "печатает следующий ответ как обычно" do
      ui.stream_chunk("первый")
      ui.stream_finish
      ui.assistant("первый")
      ui.assistant("второй")

      expect(out.string).to include("второй")
    end

    # Ответ из одних вызовов инструментов текста не содержит: лишняя пустая
    # строка разорвала бы блок «● Bash(...)» пополам.
    it "молчит, когда текста не было вовсе" do
      ui.stream_finish

      expect(out.string).to eq("")
    end
  end

  describe "разметка ответа" do
    subject(:ui) { described_class.new(out: out, tty: true, spinner_interval: 0.01, width: 40) }

    let(:answer) do
      "# Отчёт\nНашёл **три** ошибки в `agent.rb` и ещё несколько мелких замечаний.\n\n- первое\n- второе"
    end

    it "размечает ответ модели" do
      ui.assistant("текст с **важным** словом")

      expect(out.string).to include("\e[1mважным\e[0m")
      expect(out.string).not_to include("**")
    end

    # Ради этого весь рендерер и построен построчно: способ доставки ответа
    # на его вид влиять не должен.
    it "даёт на потоке тот же вид, что и целиком" do
      answer.each_char { |char| ui.stream_chunk(char) }
      ui.stream_finish
      streamed = out.string

      out.truncate(out.rewind)
      described_class.new(out: out, tty: true, spinner_interval: 0.01, width: 40).assistant(answer)

      expect(streamed).to eq(out.string)
    end

    # Вывод команды — данные от машины: звёздочка в выводе ls не курсив,
    # а решётка в начале строки не заголовок.
    it "не трогает вывод инструмента" do
      ui.tool_result("Код выхода: 0\n**.rb\n# комментарий")

      expect(out.string).to include("**.rb", "# комментарий")
    end

    # Вне терминала разметка не просто не нужна: буферизация до перевода
    # строки поменяла бы разбивку перенаправленного в файл вывода.
    it "молчит вне терминала, даже когда включена" do
      plain = described_class.new(out: out, tty: false, markdown: true)
      plain.stream_chunk("текст с **важным**")

      expect(out.string).to end_with("текст с **важным**")
    end

    it "выключается флагом" do
      off = described_class.new(out: out, tty: true, spinner_interval: 0.01, markdown: false)
      off.assistant("текст с **важным** словом")

      expect(out.string).to include("**важным**")
    end
  end

  # Управляющая последовательность в ответе модели способна подделать
  # сообщения самого агента: перекрасить их, стереть строку, нарисовать
  # «Продолжить выполнение?» поверх чужого текста. Граница проходит
  # по источнику — текст модели против вывода машины.
  describe "управляющие последовательности" do
    it "экранирует их в ответе модели" do
      ui.assistant("обычный текст\e[31m")

      expect(out.string).to include("обычный текст^[[31m")
      expect(out.string).not_to include("\e[31m")
    end

    it "экранирует их и в потоке" do
      streaming = described_class.new(out: out, tty: true, spinner_interval: 0.01, width: 40)
      streaming.stream_chunk("ответ\e[2K\n")
      streaming.stream_finish

      expect(out.string).to include("ответ^[[2K")
      expect(out.string).not_to include("\e[2K")
    end

    # Хвост размышлений — тоже текст модели, и в спиннер он идёт мимо разметки.
    it "экранирует их в бегущей строке" do
      spinning = described_class.new(out: out, tty: true, spinner_interval: 0.01, width: 80)
      spinning.ticker = "думаю\e[1;5;41m"
      spinning.with_spinner { sleep 0.05 }

      expect(out.string).to include("думаю^[[1;5;41m")
      expect(out.string).not_to include("\e[1;5;41m")
    end

    # Вывод команд — данные от машины, и ANSI в них законен: `ls --color`
    # и `git diff` печатают цвета сами. Подчистив их, агент испортил бы то,
    # ради чего команду и запускали.
    it "не трогает вывод команды" do
      ui.tool_result("Код выхода: 0\n\e[32mзелёное\e[0m")

      expect(out.string).to include("\e[32mзелёное\e[0m")
    end
  end
end
