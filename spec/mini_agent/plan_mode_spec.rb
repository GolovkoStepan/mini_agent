# frozen_string_literal: true

RSpec.describe MiniAgent::PlanMode do
  it "выключен по умолчанию" do
    expect(described_class.new.on?).to be(false)
  end

  it "включается и выключается" do
    mode = described_class.new

    expect(mode.enable.on?).to be(true)
    expect(mode.disable.on?).to be(false)
  end

  describe "#permits?" do
    # Выключенный режим не имеет мнения ни о чём: всё решает политика.
    it "разрешает всё, пока выключен" do
      mode = described_class.new

      expect(mode.permits?(read_only: false)).to be(true)
    end

    # Планирование — не «ничего не выполнять»: план по незнакомому проекту
    # нельзя составить, не прочитав его.
    it "разрешает чтение, когда включён" do
      expect(described_class.new(enabled: true).permits?(read_only: true)).to be(true)
    end

    it "отвергает всё остальное, когда включён" do
      expect(described_class.new(enabled: true).permits?(read_only: false)).to be(false)
    end

    # Спрашивается признак, а не команда: про инструмент чтения известно
    # сразу, про команду приходится гадать. Само гадание — забота ReadOnly
    # и того, кто его зовёт (CommandGuard), а не режима.
    it "спрашивает признак, а не разбирает команду" do
      mode = described_class.new(enabled: true)

      expect(mode.permits?(read_only: MiniAgent::ReadOnly.command?("cat README.md"))).to be(true)
      expect(mode.permits?(read_only: MiniAgent::ReadOnly.command?("touch new.rb"))).to be(false)
    end
  end

  describe "#plan" do
    # План хранится объектом, а не выковыривается из истории: сворачивание
    # заменяет её целиком, и единственный результат работы ушёл бы в резюме.
    it "запоминает текст плана" do
      mode = described_class.new(enabled: true)
      mode.plan = "1. Прочитать. 2. Написать."

      expect(mode.plan).to eq("1. Прочитать. 2. Написать.")
    end

    it "пуст, пока плана не было" do
      expect(described_class.new.plan).to be_nil
    end
  end
end
