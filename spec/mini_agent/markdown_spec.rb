# frozen_string_literal: true

RSpec.describe MiniAgent::Markdown do
  # Раскраска подменяется читаемой разметкой: проверять ANSI-коды значит
  # проверять Color, а здесь важно, какой кусок каким стилем помечен.
  let(:paint) { ->(text, *styles) { "<#{styles.join(",")}>#{text}</>" } }

  subject(:markdown) { described_class.new(paint: paint, width: 40) }

  def render(text) = markdown.render(text)

  describe "строчная разметка" do
    it "выделяет жирное" do
      expect(render("текст **важно** дальше")).to eq("текст <bold>важно</> дальше")
    end

    it "выделяет код серым" do
      expect(render("запусти `make spec` сейчас")).to eq("запусти <gray>make spec</> сейчас")
    end

    it "выделяет курсив приглушённым" do
      expect(render("это *почти* всё")).to eq("это <dim>почти</> всё")
    end

    # Код разбирается раньше жирного: иначе звёздочки внутри `**` съели бы
    # обратные кавычки и на экран ушёл бы кусок команды с разметкой.
    it "не разбирает разметку внутри кода" do
      expect(render("см. `a ** b`")).to eq("см. <gray>a ** b</>")
    end

    # Найдено в журнале живой сессии: модель написала
    # `1. **`.github/workflows/ci.yml`** — обновлён`, и звёздочки ушли
    # на экран дословно. Разметка вкладывается, и кусок несёт оба стиля.
    it "размечает код внутри жирного" do
      expect(render("**`ci.yml`** дальше")).to eq("<bold,gray>ci.yml</> дальше")
    end

    # Второй дефект той же строки и куда хуже первого: разрезав строку кодом,
    # прежний разбор оставлял звёздочки в разных кусках, и осиротевшая пара
    # слипалась со следующей — жирным печаталось « и ».
    it "не склеивает разные пары звёздочек через код" do
      expect(render("**`код`** и **жир**")).to eq("<bold,gray>код</> и <bold>жир</>")
    end

    # Умножение, склейка имён, `*` в выводе — звёздочка посреди слова
    # разметкой не является.
    it "не принимает звёздочку внутри слова за курсив" do
      expect(render("2*2 и a*b")).to eq("2*2 и a*b")
    end

    # Разметка кончается посреди слова: `код`, — это два сегмента подряд,
    # и набор по кускам вставил бы между ними пробел.
    it "не отрывает знаки препинания от размеченного слова" do
      expect(render("вызови `make`, потом **rake**.")).to eq("вызови <gray>make</>, потом <bold>rake</>.")
    end
  end

  describe "блоки" do
    it "делает заголовок жирным без решёток" do
      expect(render("## Установка")).to eq("<bold>Установка</>")
    end

    it "ставит маркер списку" do
      expect(render("- первый\n- второй")).to eq("• первый\n  • второй")
    end

    # Номер печатается тот, что написала модель: пересчёт скрыл бы её же
    # дефект — сбитую нумерацию, — ради борьбы с которым всё и делается.
    it "сохраняет номера как есть, не пересчитывая" do
      expect(render("1. раз\n1. два")).to eq("1. раз\n  1. два")
    end

    it "прячет ограду блока кода" do
      expect(render("```ruby\nputs 1\n```")).to eq("<gray>puts 1</>")
    end

    # Перенесённая команда выглядит копируемой и таковой не является.
    it "не переносит код по ширине" do
      long = "bundle exec rspec spec/mini_agent/markdown_spec.rb:42 --format doc"

      expect(render("```\n#{long}\n```")).to eq("<gray>#{long}</>")
    end

    # Разметка внутри блока кода — это содержимое файла, а не оформление.
    it "не размечает текст внутри блока кода" do
      expect(render("```\na = b ** 2\n```")).to eq("<gray>a = b ** 2</>")
    end
  end

  describe "таблицы" do
    let(:simple) { "| Файл | Тест |\n|---|---|\n| card.rb | есть |\n| user.rb | нет |" }

    it "выравнивает колонки по самой длинной ячейке" do
      expect(render(simple).lines.map(&:chomp)).to eq(
        ["<bold>Файл</>     <bold>Тест</>", "  ─────────────", "  card.rb  есть", "  user.rb  нет"]
      )
    end

    # Строка разделителя — служебная: она объясняет разбор, а не содержимое.
    it "не печатает строку разделителя" do
      expect(render(simple)).not_to include("---")
    end

    # Двоеточия в разделителе — единственное, чем модель может сказать «это
    # числа». Игнорировать их значит соврать про содержимое.
    it "двигает текст по двоеточиям в разделителе" do
      table = "| Имя | Счёт |\n|:---|---:|\n| a | 1000 |"

      expect(render(table).lines.last.chomp).to eq("  a    1000")
    end

    it "размечает содержимое ячейки" do
      table = "| Файл | Что |\n|---|---|\n| `agent.rb` | **цикл** ходов |"

      expect(render(table).lines.last.chomp).to eq("  <gray>agent.rb</>  <bold>цикл</> ходов")
    end

    # Рваные строки у модели — дело обычное, и разъехавшаяся таблица хуже
    # добитой пустой ячейки. Число колонок задаёт заголовок, как в GFM.
    it "добивает короткую строку и режет длинную" do
      table = "| a | b | c |\n|---|---|---|\n| один |\n| 1 | 2 | 3 | 4 |"

      expect(render(table).lines.map(&:chomp).last(2)).to eq(["  один", "  1     2  3"])
    end

    # Пока не пришёл разделитель, строка с `|` неотличима от обычного текста.
    it "печатает строку с трубой как текст, когда разделителя не было" do
      expect(render("Выбор: | да | нет |\nвторая")).to eq("Выбор: | да | нет |\n  вторая")
    end

    it "не принимает трубу внутри блока кода за таблицу" do
      expect(render("```\n| a | b |\n|---|---|\n```").lines.first.chomp).to eq("<gray>| a | b |</>")
    end

    # Экранированная труба — часть ячейки: без этого одна такая сдвигала бы
    # всю строку на колонку влево.
    it "не режет ячейку по экранированной трубе" do
      table = "| a | b |\n|---|---|\n| x \\| y | 2 |"

      expect(render(table).lines.last.chomp).to eq("  x | y  2")
    end

    # Вылезшее за колонку слово сдвигает всю строку, и колонки перестают
    # быть колонками — то есть пропадает всё, ради чего таблица рисуется.
    it "ужимает колонки и рвёт длинное слово, когда таблица шире терминала" do
      table = "| Файл | Описание |\n|---|---|\n| lib/mini_agent/command_guard.rb | политика подтверждений |"

      expect(render(table).lines.map(&:chomp).last(2)).to eq(
        ["  lib/mini_agent/com  политика", "  mand_guard.rb       подтверждений"]
      )
    end

    it "дорисовывает таблицу, когда ответ ею кончился" do
      markdown.feed("| a |\n|---|\n| 1 |")

      expect(markdown.flush).to eq("<bold>a</>\n  ─\n  1")
    end
  end

  describe "перенос" do
    it "укладывается в ширину терминала" do
      lines = render("слово " * 20).split("\n")

      expect(lines.map { |line| line.sub(/\A {2}/, "").length }.max).to be <= 38
      expect(lines.size).to be > 1
    end

    # Отступ ровно в ширину маркера «● », который UI печатает перед первой
    # строкой: продолжения выравниваются по тексту, а не по маркеру.
    it "отбивает продолжения под текст, а не под маркер" do
      expect(render("слово " * 20).lines.drop(1)).to all(start_with("  "))
    end

    # Разорванный путь нельзя ни скопировать, ни прочитать.
    it "не рвёт длинное слово" do
      url = "http://llm-server:1234/v1/chat/completions?model=qwen3.6-35b-a3b"

      expect(render(url)).to eq(url)
    end

    # Продолжения пункта встают под его текст: иначе второй строкой список
    # неотличим от нового пункта.
    it "держит висячий отступ у списка" do
      expect(render("- #{"слово " * 12}").lines.drop(1)).to all(start_with("    "))
    end

    # Строка из двух слов читается хуже неперенесённой.
    it "не переносит вовсе на узком терминале" do
      narrow = described_class.new(paint: paint, width: 20)

      expect(narrow.render("слово " * 10).lines.size).to eq(1)
    end

    # Ширина спрашивается на каждой строке: окно меняют посреди генерации.
    it "спрашивает ширину у терминала, когда она не задана" do
      allow(MiniAgent::Terminal).to receive(:width).and_return(40)

      described_class.new(paint: paint).render("слово " * 20)

      expect(MiniAgent::Terminal).to have_received(:width).at_least(:twice)
    end

    # Длины считаются до раскраски: ANSI-коды занимают знаки в строке, но
    # не столбцы на экране, и обратный порядок ломает перенос ровно там,
    # где разметка есть (те же грабли, что в Spinner#line).
    it "не считает разметку за текст при переносе" do
      plain = described_class.new(paint: ->(text, *_) { text }, width: 40)

      expect(markdown.render("**слово** " * 10).lines.size).to eq(plain.render("слово " * 10).lines.size)
    end
  end

  # Инвариант всего класса: разметка разбирается только на целой строке,
  # поэтому границы кусков сокета на результат не влияют.
  describe "поток" do
    it "даёт тот же вывод, что и целый текст" do
      text = "# Отчёт\nНашёл **три** ошибки в `agent.rb`.\n\n- первая, довольно длинная строка про неё\n- вторая"
      streamed = +""
      text.each_char { |char| streamed << markdown.feed(char) }
      streamed << markdown.flush

      expect(streamed).to eq(described_class.new(paint: paint, width: 40).render(text))
    end

    # Главная страховка таблиц. Они — единственное, что копится целиком, то есть
    # единственное место, где вывод отстаёт от потока; разойтись с обычным
    # режимом он при этом не имеет права.
    it "даёт тот же вывод на тексте с таблицей" do
      text = "Итог:\n\n| Файл | Тест |\n|---|---|\n| card.rb | есть |\n\nВсё."
      streamed = +""
      text.each_char { |char| streamed << markdown.feed(char) }
      streamed << markdown.flush

      expect(streamed).to eq(described_class.new(paint: paint, width: 40).render(text))
    end

    # Кусок без перевода строки печатать нельзя: «**жир» и «ный**» приходят
    # порознь, и разбор по куску увидел бы одинокую звёздочку.
    it "молчит, пока строка не дописана" do
      expect(markdown.feed("текст с **жир")).to eq("")
      expect(markdown.feed("ным** концом")).to eq("")
      expect(markdown.flush).to eq("текст с <bold>жирным</> концом")
    end

    it "отдаёт готовую строку сразу" do
      expect(markdown.feed("**раз**\nдва")).to eq("<bold>раз</>\n")
    end

    # Рендерер живёт всю сессию: незакрытый блок кода из прошлого ответа
    # отдал бы следующий дословно и без разметки.
    it "забывает открытый блок кода между ответами" do
      markdown.render("```\nputs 1")

      expect(markdown.render("**жирный**")).to eq("<bold>жирный</>")
    end
  end

  describe MiniAgent::Markdown::Plain do
    subject(:plain) { described_class.new }

    # Вне терминала буферизация не оптимизация, а изменение поведения:
    # перенаправленный в файл вывод получил бы другую разбивку строк.
    it "пропускает кусок насквозь, не копя его" do
      expect(plain.feed("**текст**")).to eq("**текст**")
      expect(plain.flush).to eq("")
    end

    it "не трогает разметку" do
      expect(plain.render("# Заголовок")).to eq("# Заголовок")
    end
  end
end
