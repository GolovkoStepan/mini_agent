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
