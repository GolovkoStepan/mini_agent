# frozen_string_literal: true

RSpec.describe MiniAgent::Lookup do
  let(:defaults) { { model: "по умолчанию", turns: 50, stream: true }.freeze }
  let(:keys) { { model: "LLM_MODEL", turns: "MAX_TURNS", stream: "LLM_STREAM", temperature: "LLM_TEMPERATURE" }.freeze }

  def lookup(options = {}, env = {})
    described_class.new(options, env, defaults: defaults, keys: keys)
  end

  describe "приоритет источников" do
    it "предпочитает опцию переменной окружения" do
      expect(lookup({ model: "из флага" }, { "LLM_MODEL" => "из окружения" }).fetch(:model)).to eq("из флага")
    end

    it "берёт переменную окружения, когда опции нет" do
      expect(lookup({}, { "LLM_MODEL" => "из окружения" }).fetch(:model)).to eq("из окружения")
    end

    it "берёт умолчание, когда не задано ничего" do
      expect(lookup.fetch(:model)).to eq("по умолчанию")
    end
  end

  describe "#given" do
    it "отдаёт nil, когда значение только в умолчаниях" do
      expect(lookup.given(:model)).to be_nil
    end

    # options.key?, а не проверка на истинность: иначе --no-allow-unsafe
    # не смог бы перебить ALLOW_UNSAFE=true — флаг молча проигрывал бы
    # переменной окружения, хотя сказан позже и точнее.
    it "не теряет явное false" do
      given = lookup({ stream: false }, { "LLM_STREAM" => "true" })

      expect(given.given(:stream)).to be(false)
      expect(given.bool(:stream)).to be(false)
    end

    # `LLM_MODEL= mini_agent ...` означает «не задано», а не «модель
    # с пустым именем».
    it "считает пустую переменную окружения незаданной" do
      expect(lookup({}, { "LLM_MODEL" => "" }).given(:model)).to be_nil
    end

    it "отвечает на given?, задано ли значение человеком" do
      expect(lookup({ model: "своя" }).given?(:model)).to be(true)
      expect(lookup.given?(:model)).to be(false)
    end
  end

  # Умолчания есть не у всех ключей: у параметров сэмплинга их нет вовсе,
  # решает пресет сервера. Падение здесь намеренное — код, спросивший
  # температуру общим путём, обязан ломаться громко, а не получать
  # выдуманное число, которое молча уедет в тело запроса.
  describe "ключ без умолчания" do
    it "падает на fetch" do
      expect { lookup.fetch(:temperature) }.to raise_error(KeyError)
    end

    it "но отвечает на given" do
      expect(lookup({ temperature: 0.3 }).given(:temperature)).to eq(0.3)
    end
  end

  # Из флага признак приходит уже булевым, из окружения — строкой.
  describe "#bool" do
    it "понимает истину строкой в любом виде" do
      ["true", "1", "yes", "TRUE", " Yes "].each do |value|
        expect(lookup({}, { "LLM_STREAM" => value }).bool(:stream)).to be(true)
      end
    end

    it "считает ложью всё остальное" do
      expect(lookup({}, { "LLM_STREAM" => "нет" }).bool(:stream)).to be(false)
    end

    it "пропускает булево значение как есть" do
      expect(lookup({ stream: true }).bool(:stream)).to be(true)
    end
  end
end
