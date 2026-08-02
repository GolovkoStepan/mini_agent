# frozen_string_literal: true

RSpec.describe MiniAgent::LineReader do
  let(:out) { StringIO.new }

  describe "вне терминала" do
    subject(:reader) { described_class.new(input: StringIO.new("задача\n"), output: out) }

    it "не считает себя интерактивным" do
      expect(reader).not_to be_interactive
    end

    it "печатает приглашение и читает строку обычным gets" do
      expect(reader.gets("> ")).to eq("задача\n")
      expect(out.string).to eq("> ")
    end

    # Конец ввода должен выглядеть одинаково при обоих способах чтения:
    # вызывающий код не обязан знать, какой из них сработал.
    it "возвращает nil в конце ввода" do
      reader = described_class.new(input: StringIO.new(""), output: out)

      expect(reader.gets("> ")).to be_nil
    end
  end

  # Reline трогать в тестах нельзя: он захватывает настоящий терминал.
  # Проверяем только развилку — именно она решает, вызывать ли его.
  describe "признак интерактивности" do
    it "требует терминала и на вводе, и на выводе" do
      tty = instance_double(IO, tty?: true)
      plain = instance_double(IO, tty?: false)

      expect(described_class.new(input: tty, output: tty)).to be_interactive
      expect(described_class.new(input: tty, output: plain)).not_to be_interactive
      expect(described_class.new(input: plain, output: tty)).not_to be_interactive
    end
  end
end
