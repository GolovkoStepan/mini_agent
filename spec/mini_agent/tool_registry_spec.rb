# frozen_string_literal: true

RSpec.describe MiniAgent::ToolRegistry do
  # Простой инструмент-заглушка, чтобы не тянуть bash и процессы.
  let(:echo_tool) do
    Class.new do
      def name = "echo"
      def schema = { "type" => "function", "function" => { "name" => "echo" } }
      def call(arguments) = "эхо: #{arguments["text"]}"
    end.new
  end

  subject(:registry) { described_class.new([echo_tool]) }

  it "пустой реестр не содержит инструментов" do
    expect(described_class.new).to be_empty
  end

  it "регистрирует инструмент по имени" do
    expect(registry.names).to eq(["echo"])
  end

  it "отдаёт схемы для передачи модели" do
    expect(registry.schemas).to eq([echo_tool.schema])
  end

  it "вызывает инструмент по имени" do
    expect(registry.dispatch("echo", { "text" => "привет" })).to eq("эхо: привет")
  end

  it "сообщает о неизвестном инструменте, не бросая исключение" do
    expect(registry.dispatch("magic", {})).to eq(format(MiniAgent::Messages::UNKNOWN_TOOL, name: "magic"))
  end

  it "перехватывает исключение инструмента и возвращает текст" do
    broken = Class.new do
      def name = "broken"
      def schema = {}
      def call(_args) = raise(StandardError, "внутренняя поломка")
    end.new

    result = described_class.new([broken]).dispatch("broken", {})

    expect(result).to include("внутренняя поломка")
  end

  it "позволяет добавлять инструменты цепочкой" do
    registry.register(echo_tool)

    expect(registry.names.size).to eq(1)
  end
end
