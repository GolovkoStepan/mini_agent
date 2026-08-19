# frozen_string_literal: true

RSpec.describe MiniAgent::TextWrap do
  # Раскраска подменяется читаемой разметкой: проверять ANSI-коды значит
  # проверять Color, а здесь важно, где стиль открывается и где закрывается.
  let(:paint) { ->(text, *styles) { "<#{styles.join(",")}>#{text}</>" } }

  subject(:wrap) { described_class.new(paint: paint, indent: "  ", width: 40) }

  def plain(text) = [[text, nil]]

  it "укладывает строку в ширину терминала" do
    lines = wrap.call(plain("слово " * 20)).split("\n")

    expect(lines.map { |line| line.sub(/\A {2}/, "").length }.max).to be <= 38
  end

  it "отбивает продолжения отступом" do
    expect(wrap.call(plain("слово " * 20)).lines.drop(1)).to all(start_with("  "))
  end

  # Продолжения пункта встают под его текст, а не под маркер.
  it "добавляет к отступу висячую часть" do
    expect(wrap.call(plain("слово " * 20), hang: "  ").lines.drop(1)).to all(start_with("    "))
  end

  # Разорванный путь нельзя ни скопировать, ни прочитать.
  it "не рвёт длинное слово" do
    url = "http://llm-server:1234/v1/chat/completions?model=qwen3.6-35b-a3b"

    expect(wrap.call(plain(url))).to eq(url)
  end

  # Строка из двух слов читается хуже неперенесённой, а обрубок — хуже обеих.
  it "не переносит вовсе на узком терминале" do
    narrow = described_class.new(paint: paint, indent: "  ", width: 20)

    expect(narrow.call(plain("слово " * 10)).lines.size).to eq(1)
  end

  # Ширина спрашивается на каждом вызове: окно меняют посреди генерации.
  it "спрашивает ширину у терминала, когда она не задана" do
    allow(MiniAgent::Terminal).to receive(:width).and_return(40)

    described_class.new(paint: paint, indent: "  ").call(plain("слово " * 20))

    expect(MiniAgent::Terminal).to have_received(:width).at_least(:once)
  end

  # Отдельный вход для Table: тому нужны не склеенные строки, а каждая со своей
  # длиной — по готовой строке её уже не измерить.
  describe "#lines" do
    it "отдаёт длину строки без раскраски" do
      expect(wrap.lines([["make", :gray], [" spec", nil]], 20)).to eq([["<gray>make</> spec", 9]])
    end

    # Проза длинное слово не рвёт (разорванный путь не прочесть), а ячейка
    # обязана: вылезшее слово сдвигает всю строку, и колонки перестают быть
    # колонками — то есть пропадает всё, ради чего таблица рисуется.
    it "рвёт длинное слово только по требованию" do
      expect(wrap.lines(plain("длинноеслово"), 5).map(&:first)).to eq(["длинноеслово"])
      expect(wrap.lines(plain("длинноеслово"), 5, hard: true).map(&:first)).to eq(%w[длинн оесло во])
    end
  end

  describe "раскраска" do
    # Соседние куски одного стиля склеиваются: иначе каждое слово внутри
    # `команды с пробелами` получило бы свою пару ANSI-кодов.
    it "красит соседей одного стиля разом" do
      expect(wrap.call([["make spec", :gray]])).to eq("<gray>make spec</>")
    end

    # Разметка кончается посреди слова: `код`, — это два сегмента подряд,
    # и набор по кускам вставил бы между ними пробел.
    it "не отрывает соседний сегмент от слова" do
      expect(wrap.call([["make", :gray], [", потом", nil]])).to eq("<gray>make</>, потом")
    end

    # Длины считаются до раскраски: ANSI-коды занимают знаки в строке, но
    # не столбцы на экране (те же грабли, что в Spinner#line).
    it "не считает разметку за текст при переносе" do
      styled = wrap.call(Array.new(10) { [["слово", :bold], [" ", nil]] }.flatten(1))

      expect(styled.lines.size).to eq(wrap.call(plain("слово " * 10)).lines.size)
    end
  end
end
