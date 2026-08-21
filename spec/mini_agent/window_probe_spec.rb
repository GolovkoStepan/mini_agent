# frozen_string_literal: true

RSpec.describe MiniAgent::WindowProbe do
  let(:config) { MiniAgent::Config.new({ base_url: "http://probe.test/v1", model: "выбранная" }, env: {}) }
  let(:endpoint) { "http://probe.test/api/v1/models" }

  subject(:probe) { described_class.new(config: config) }

  def body(*models)
    { "models" => models }.to_json
  end

  # Загруженное в v1 описывается списком экземпляров, а не плоским
  # признаком: loaded: nil означает модель, лежащую на диске.
  def model(key:, loaded: nil, max: 262_144)
    instances = Array(loaded).map do |window|
      { "id" => key, "config" => { "context_length" => window }.compact }
    end

    { "key" => key, "loaded_instances" => instances, "max_context_length" => max }
  end

  describe "успешная проба" do
    it "берёт размер окна у загруженной модели" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "qwen", loaded: 8192)))

      expect(probe.call).to eq(8192)
    end

    # Незагруженные не в счёт: работает та, что в памяти.
    it "не берёт размер у незагруженной модели" do
      stub_request(:get, endpoint).to_return(
        status: 200,
        body: body(model(key: "первая"), model(key: "вторая", loaded: 65_536))
      )

      expect(probe.call).to eq(65_536)
    end

    # Найдено на живом сервере: загруженных моделей оказалось две (qwen
    # с окном 65536 и bonsai с 8192), и первая версия брала первую
    # попавшуюся — при работе со второй показывала чужое окно вдвое
    # больше настоящего.
    it "выбирает по имени, когда загружено несколько" do
      stub_request(:get, endpoint).to_return(
        status: 200,
        body: body(model(key: "другая", loaded: 65_536), model(key: "выбранная", loaded: 8192))
      )

      expect(probe.call).to eq(8192)
    end

    # Одна загруженная отвечает на всё, какое бы имя ни стояло в настройках:
    # LM Studio на незнакомое имя молча подставляет её.
    it "берёт единственную загруженную, даже если имя не совпало" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "совсем другая", loaded: 4096)))

      expect(probe.call).to eq(4096)
    end

    # Одну и ту же модель поднимают дважды с разными окнами — этого v0
    # выразить не мог вовсе, и выбирать надо среди экземпляров.
    it "различает экземпляры одной модели по имени" do
      stub_request(:get, endpoint).to_return(
        status: 200,
        body: { "models" => [{
          "key" => "qwen",
          "loaded_instances" => [
            { "id" => "другая", "config" => { "context_length" => 65_536 } },
            { "id" => "выбранная", "config" => { "context_length" => 8192 } }
          ]
        }] }.to_json
      )

      expect(probe.call).to eq(8192)
    end

    # Путь /api/v1 — сосед /v1, а не его потомок.
    it "спрашивает от корня сервера, а не от base_url" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "q", loaded: 4096)))

      probe.call

      expect(a_request(:get, endpoint)).to have_been_made
    end
  end

  describe "отступление" do
    # Так ответит любой сервер, кроме LM Studio: это не ошибка, а обычное
    # «узнать не вышло». Сюда же попала устаревшая сборка, знающая только
    # /api/v0/models, — запасного разбора для неё нет намеренно.
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
    # error на неверный путь. Без проверки поле models искалось бы в ошибке.
    it "молчит на 200 с полем error" do
      stub_request(:get, endpoint).to_return(status: 200, body: { "error" => "Unexpected endpoint" }.to_json)

      expect(probe.call).to be_nil
    end

    # Старый формат отвечает 200 и разбирается как JSON — молчание здесь
    # обеспечивает не сеть, а то, что поля models в нём нет.
    it "молчит на ответе старого формата" do
      stub_request(:get, endpoint).to_return(
        status: 200,
        body: { "data" => [{ "id" => "q", "state" => "loaded", "loaded_context_length" => 8192 }] }.to_json
      )

      expect(probe.call).to be_nil
    end

    it "молчит, когда ни одна модель не загружена" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "q")))

      expect(probe.call).to be_nil
    end

    # max_context_length у той же модели — 262144 против загруженных 50176.
    # Ошибиться в пять раз в бо́льшую сторону хуже, чем не знать.
    it "не подставляет max_context_length вместо загруженного" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "q", loaded: nil)))

      expect(probe.call).to be_nil
    end

    # Загружено несколько, имя не совпало ни с одной — угадывать нечего.
    # Взять первую попавшуюся значило бы показать чужое окно, а это та
    # самая ошибка в бо́льшую сторону, от которой отказались в пользу
    # незнания.
    it "молчит, когда загружено несколько и ни одна не совпала по имени" do
      stub_request(:get, endpoint).to_return(
        status: 200,
        body: body(model(key: "первая", loaded: 65_536), model(key: "вторая", loaded: 8192))
      )

      expect(probe.call).to be_nil
    end

    it "молчит на нечисловом и неположительном размере" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "q", loaded: 0)))

      expect(probe.call).to be_nil
    end
  end

  # Промах на старте почти всегда означает модель, которую LM Studio ещё
  # не подняла: она грузится по первому запросу к /chat/completions, то есть
  # уже после пробы. Без повторов размер окна оставался неизвестен до конца
  # сессии и лечился только перезапуском.
  describe "фоновые повторы" do
    subject(:probe) { described_class.new(config: config, delays: [0, 0, 0]) }

    it "берёт размер, когда модель поднялась не сразу" do
      stub_request(:get, endpoint)
        .to_return(status: 200, body: body(model(key: "выбранная")))
        .then.to_return(status: 200, body: body(model(key: "выбранная", loaded: 50_176)))

      expect(collect(probe)).to eq([50_176])
    end

    # Успех один: дальше повторять нечего, а поток, переживший свою задачу,
    # сам себя не остановит.
    it "прекращает повторы после первого успеха" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "выбранная", loaded: 8192)))

      collect(probe)

      expect(a_request(:get, endpoint)).to have_been_made.once
    end

    # Ничего не добившись, поток умирает молча: неудача необязательной
    # справки не повод шуметь, а повторять её бесконечно тем более незачем.
    it "сдаётся, исчерпав паузы, и не зовёт блок" do
      stub_request(:get, endpoint).to_return(status: 404, body: "")

      expect(collect(probe)).to be_empty
      expect(a_request(:get, endpoint)).to have_been_made.times(3)
    end

    it "переживает отсутствие блока" do
      stub_request(:get, endpoint).to_return(status: 200, body: body(model(key: "выбранная", loaded: 8192)))

      expect { probe.watch.join }.not_to raise_error
    end

    def collect(probe)
      sizes = []
      probe.watch { |size| sizes << size }.join
      sizes
    end
  end
end
