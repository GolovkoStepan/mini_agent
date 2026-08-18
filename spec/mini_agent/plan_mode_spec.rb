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

  describe "#allows?" do
    # Выключенный режим не имеет мнения о командах: всё решает политика.
    it "разрешает всё, пока выключен" do
      mode = described_class.new

      expect(mode.allows?("rm -rf /tmp/x")).to be(true)
    end

    # Планирование — не «ничего не выполнять»: план по незнакомому проекту
    # нельзя составить, не прочитав его.
    it "разрешает чтение, когда включён" do
      mode = described_class.new(enabled: true)

      expect(mode.allows?("cat README.md")).to be(true)
      expect(mode.allows?("git log --oneline")).to be(true)
    end

    it "отвергает всё остальное, когда включён" do
      mode = described_class.new(enabled: true)

      expect(mode.allows?("touch new.rb")).to be(false)
      expect(mode.allows?("bundle exec rspec")).to be(false)
    end

    # Свой список не заводится: ReadOnly уже отвечает на этот вопрос для
    # политики ask. Обе формы измерены живьём — на исследовании двух
    # репозиториев из 33 команд отвергнуто 6, из них 5 приходится на find.
    # Обе названы модели в PLAN_INSTRUCTION, чтобы она не открывала их
    # для себя отказами по ходу дела.
    it "отвергает find и перенаправление, как и ReadOnly" do
      mode = described_class.new(enabled: true)

      expect(mode.allows?("find . -type f")).to be(false)
      expect(mode.allows?("cat README.md 2>/dev/null")).to be(false)
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
