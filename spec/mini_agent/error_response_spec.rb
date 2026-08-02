# frozen_string_literal: true

RSpec.describe MiniAgent::ErrorResponse do
  # Заглушка вместо настоящего Net::HTTPResponse: нужен только код, тело и
  # доступ к заголовку по имени — собирать реальный ответ ради трёх методов
  # значило бы тащить в тест половину Net::HTTP.
  def response(code:, body: "", headers: {})
    instance_double(Net::HTTPResponse, code: code, body: body).tap do |double|
      allow(double).to receive(:[]) { |name| headers[name.downcase] }
    end
  end

  describe "#retriable?" do
    it "повторяет 5xx: сервер упал, но запрос корректен" do
      expect(described_class.new(response(code: "500")).retriable?).to be(true)
      expect(described_class.new(response(code: "503")).retriable?).to be(true)
    end

    # Занятость сервера, а не негодность запроса — единственные 4xx,
    # которые имеет смысл повторять.
    it "повторяет 408 и 429" do
      expect(described_class.new(response(code: "408")).retriable?).to be(true)
      expect(described_class.new(response(code: "429")).retriable?).to be(true)
    end

    it "не повторяет прочие 4xx" do
      %w[400 401 403 404 422].each do |code|
        expect(described_class.new(response(code: code)).retriable?).to be(false)
      end
    end
  end

  describe "#retry_after" do
    it "возвращает nil, когда заголовка нет" do
      expect(described_class.new(response(code: "429")).retry_after).to be_nil
    end

    it "читает число секунд" do
      error = described_class.new(response(code: "429", headers: { "retry-after" => "7" }))

      expect(error.retry_after).to eq(7.0)
    end

    it "ограничивает значение потолком" do
      error = described_class.new(response(code: "429", headers: { "retry-after" => "9999" }))

      expect(error.retry_after).to eq(described_class::MAX_RETRY_AFTER.to_f)
    end

    # HTTP-дата спецификацией допустима, но локальные серверы её не шлют,
    # а разбор дат втянул бы в тесты зависимость от текущего времени.
    it "игнорирует форму HTTP-даты" do
      error = described_class.new(response(code: "429", headers: { "retry-after" => "Wed, 21 Oct 2026 07:28:00 GMT" }))

      expect(error.retry_after).to be_nil
    end
  end

  describe "#text" do
    it "достаёт message из объекта error" do
      body = { error: { message: "Модель не загружена", type: "invalid_request_error" } }.to_json

      expect(described_class.new(response(code: "400", body: body)).text).to eq("Модель не загружена")
    end

    it "принимает error строкой" do
      body = { error: "Сообщение system должно быть первым" }.to_json

      expect(described_class.new(response(code: "400", body: body)).text).to eq("Сообщение system должно быть первым")
    end

    it "отдаёт тело целиком, когда это не JSON" do
      expect(described_class.new(response(code: "502", body: "Bad Gateway")).text).to eq("Bad Gateway")
    end

    it "отдаёт тело целиком, когда в JSON нет поля error" do
      body = { detail: "что-то пошло не так" }.to_json

      expect(described_class.new(response(code: "400", body: body)).text).to eq(body)
    end

    # Net::HTTP отдаёт тело как ASCII-8BIT, если сервер не прислал charset;
    # склейка такой строки с русским текстом роняла бы клиент
    # Encoding::CompatibilityError вместо показа самой ошибки.
    it "перекодирует тело без charset" do
      body = '{"error":"Модель не найдена"}'.dup.force_encoding(Encoding::BINARY)

      expect(described_class.new(response(code: "400", body: body)).text).to eq("Модель не найдена")
    end

    it "не падает на невалидных байтах" do
      body = "bad \xFF\xFE byte".dup.force_encoding(Encoding::BINARY)

      expect { described_class.new(response(code: "400", body: body)).text }.not_to raise_error
    end
  end

  describe "#to_s" do
    it "склеивает код и текст ошибки" do
      body = { error: { message: "нет такой модели" } }.to_json

      expect(described_class.new(response(code: "404", body: body)).to_s).to eq("HTTP 404: нет такой модели")
    end
  end
end
