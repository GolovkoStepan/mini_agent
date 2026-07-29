# frozen_string_literal: true

RSpec.describe MiniAgent::CLI do
  let(:out) { StringIO.new }

  def start(argv, input: StringIO.new(""))
    described_class.start(argv, out: out, input: input)
  end

  describe "справка и версия" do
    it "печатает справку по --help с кодом 0" do
      expect(start(["--help"])).to eq(0)
      expect(out.string).to include("Использование: mini_agent")
    end

    it "печатает справку по -h" do
      expect(start(["-h"])).to eq(0)
      expect(out.string).to include("--interactive")
    end

    it "печатает версию по --version" do
      expect(start(["--version"])).to eq(0)
      expect(out.string.strip).to eq(MiniAgent::VERSION)
    end

    it "перечисляет все опции в справке" do
      start(["--help"])

      %w[--max-turns --retry-count --retry-delay --base-url --model --[no-]allow-unsafe].each do |flag|
        expect(out.string).to include(flag)
      end
    end
  end

  describe "запуск без задачи" do
    it "возвращает код 1 и подсказку" do
      expect(start([])).to eq(1)
      expect(out.string).to include("Не указана задача")
    end

    it "возвращает код 1 при пустой строке задачи" do
      expect(start(["   "])).to eq(1)
    end
  end

  describe "разбор опций" do
    it "сообщает о неизвестной опции с кодом 1" do
      expect(start(["--unknown-flag"])).to eq(1)
      expect(out.string).to include("invalid option")
    end

    it "сообщает о некорректном значении числовой опции" do
      expect(start(["--max-turns", "не-число", "задача"])).to eq(1)
      expect(out.string).to include("invalid argument")
    end
  end

  describe "запуск задачи" do
    let(:endpoint) { "http://cli.test/v1/chat/completions" }

    before do
      stub_request(:post, endpoint).to_return(
        status: 200,
        body: { "choices" => [{ "message" => { "content" => "готово" } }] }.to_json
      )
    end

    it "выполняет задачу и возвращает код 0" do
      code = start(["--base-url", "http://cli.test/v1", "посчитай файлы"])

      expect(code).to eq(0)
      expect(out.string).to include("готово")
    end

    it "склеивает несколько аргументов в одну задачу" do
      start(["--base-url", "http://cli.test/v1", "посчитай", "файлы", "в", "проекте"])

      matcher = a_request(:post, endpoint)
                .with { |req| JSON.parse(req.body)["messages"].last["content"] == "посчитай файлы в проекте" }
      expect(matcher).to have_been_made
    end

    it "передаёт модель из --model" do
      start(["--base-url", "http://cli.test/v1", "--model", "llama3", "задача"])

      expect(a_request(:post, endpoint).with(body: hash_including("model" => "llama3"))).to have_been_made
    end

    it "передаёт схему инструмента bash" do
      start(["--base-url", "http://cli.test/v1", "задача"])

      matcher = a_request(:post, endpoint)
                .with { |req| JSON.parse(req.body)["tools"].first["function"]["name"] == "bash" }
      expect(matcher).to have_been_made
    end
  end

  describe "интерактивный режим" do
    it "запускается и завершается по exit" do
      stub_request(:post, "http://cli.test/v1/chat/completions").to_return(
        status: 200,
        body: { "choices" => [{ "message" => { "content" => "ответ" } }] }.to_json
      )

      code = start(["-i", "--base-url", "http://cli.test/v1"], input: StringIO.new("задача\nexit\n"))

      expect(code).to eq(0)
      expect(out.string).to include("интерактивный режим")
      expect(out.string).to include("До свидания!")
    end

    it "завершается сразу при пустом вводе" do
      expect(start(["-i", "--base-url", "http://cli.test/v1"], input: StringIO.new(""))).to eq(0)
    end
  end
end
