# frozen_string_literal: true

RSpec.describe MiniAgent::WindowProbe do
  let(:config) { MiniAgent::Config.new({ base_url: "http://probe.test/v1" }, env: {}) }
  let(:endpoint) { "http://probe.test/api/v0/models" }

  subject(:probe) { described_class.new(config: config) }

  def body(*models)
    { "data" => models }.to_json
  end

  def model(id:, state:, loaded: nil, max: 262_144)
    {
      "id" => id, "state" => state,
      "loaded_context_length" => loaded, "max_context_length" => max
    }.compact
  end

  describe "успешная проба" do
    it "берёт размер окна у загруженной модели" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(id: "qwen", state: "loaded", loaded: 8192)))

      expect(probe.call).to eq(8192)
    end

    # Работает та модель, что в памяти, а не та, что названа в настройках:
    # LM Studio на незнакомое имя молча подставляет загруженную.
    it "ищет загруженную модель, а не совпадающую по имени" do
      stub_request(:get, endpoint).to_return(
        status: 200,
        body: body(
          model(id: "первая", state: "not-loaded", loaded: 100),
          model(id: "вторая", state: "loaded", loaded: 65_536)
        )
      )

      expect(probe.call).to eq(65_536)
    end

    # Путь /api/v0 — сосед /v1, а не его потомок.
    it "спрашивает от корня сервера, а не от base_url" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(id: "q", state: "loaded", loaded: 4096)))

      probe.call

      expect(a_request(:get, endpoint)).to have_been_made
    end
  end

  describe "отступление" do
    # Так ответит любой сервер, кроме LM Studio: это не ошибка, а обычное
    # «узнать не вышло».
    it "молчит на 404" do
      stub_request(:get, endpoint).to_return(status: 404, body: "not found")

      expect(probe.call).to be_nil
    end

    it "молчит, когда сервера нет" do
      stub_request(:get, endpoint).to_raise(Errno::ECONNREFUSED)

      expect(probe.call).to be_nil
    end

    it "молчит на неразбираемом теле" do
      stub_request(:get, endpoint).to_return(status: 200, body: "не json")

      expect(probe.call).to be_nil
    end

    # Та же ловушка, что и в ModelsRequest: LM Studio отвечает 200 с полем
    # error на неверный путь. Без проверки поле data искалось бы в ошибке.
    it "молчит на 200 с полем error" do
      stub_request(:get, endpoint).to_return(status: 200, body: { "error" => "Unexpected endpoint" }.to_json)

      expect(probe.call).to be_nil
    end

    it "молчит, когда ни одна модель не загружена" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(id: "q", state: "not-loaded", loaded: 8192)))

      expect(probe.call).to be_nil
    end

    # max_context_length у той же модели — 262144 против загруженных 8192.
    # Ошибиться в тридцать раз в бо́льшую сторону хуже, чем не знать.
    it "не подставляет max_context_length вместо загруженного" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(id: "q", state: "loaded")))

      expect(probe.call).to be_nil
    end

    it "молчит на нечисловом и неположительном размере" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(id: "q", state: "loaded", loaded: 0)))

      expect(probe.call).to be_nil
    end
  end
end
