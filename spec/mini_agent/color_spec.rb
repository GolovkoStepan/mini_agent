# frozen_string_literal: true

RSpec.describe MiniAgent::Color do
  it "оборачивает текст в ANSI-код цвета" do
    expect(described_class.red("ошибка")).to eq("\e[31mошибка\e[0m")
  end

  it "возвращает чистый текст, когда раскраска выключена" do
    expect(described_class.red("ошибка", enabled: false)).to eq("ошибка")
  end

  it "умеет комбинировать стили" do
    expect(described_class.paint("важно", :bold, :green)).to eq("\e[1m\e[32mважно\e[0m")
  end

  it "возвращает текст без изменений при неизвестном стиле" do
    expect(described_class.paint("текст", :chartreuse)).to eq("текст")
  end

  it "поддерживает все объявленные цвета" do
    described_class::CODES.each_key do |name|
      expect(described_class.public_send(name, "x")).to include("x")
    end
  end
end
