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

  describe ".escape" do
    it "делает управляющую последовательность видимой, а не удаляет её" do
      expect(described_class.escape("до\e[31mпосле")).to eq("до^[[31mпосле")
    end

    # Переписать напечатанное можно и без ANSI: \r возвращает курсор
    # в начало строки, \b сдвигает его назад.
    it "экранирует возврат каретки и забой" do
      expect(described_class.escape("строка\rподделка")).to eq("строка^Mподделка")
      expect(described_class.escape("текст\b\b")).to eq("текст^H^H")
    end

    it "не трогает перевод строки и табуляцию" do
      expect(described_class.escape("а\nб\tв")).to eq("а\nб\tв")
    end

    # Иначе ответ с виндовыми переводами строк получил бы ^M в конце каждой.
    it "сводит CRLF к LF, а не показывает его" do
      expect(described_class.escape("а\r\nб")).to eq("а\nб")
    end
  end

  it "поддерживает все объявленные цвета" do
    described_class::CODES.each_key do |name|
      expect(described_class.public_send(name, "x")).to include("x")
    end
  end
end
