# frozen_string_literal: true

RSpec.describe MiniAgent::ChatResponse do
  def response(message: { "content" => "готово" }, usage: nil, finish_reason: nil)
    choice = { "message" => message }
    choice["finish_reason"] = finish_reason if finish_reason
    data = { "choices" => [choice] }
    data["usage"] = usage if usage
    described_class.new(data, message)
  end

  it "разбирает текст и вызовы инструментов" do
    calls = [{ "id" => "call_1" }]
    result = response(message: { "content" => " готово ", "tool_calls" => calls })

    expect(result.content).to eq("готово")
    expect(result.tool_calls).to eq(calls)
  end

  # Поля необязательные: их отсутствие — обычный ответ, а не сбой.
  it "подставляет пустые значения вместо отсутствующих полей" do
    result = response(message: {})

    expect(result.content).to eq("")
    expect(result.tool_calls).to eq([])
    expect(result.usage).to be_nil
    expect(result.finish_reason).to be_nil
  end

  # usage лежит в корне ответа, finish_reason — в choices[0]: ни то, ни другое
  # не внутри message, и перепутать уровни легко.
  it "берёт usage из корня, а finish_reason из choices" do
    result = response(usage: { "prompt_tokens" => 13 }, finish_reason: "stop")

    expect(result.usage).to eq({ "prompt_tokens" => 13 })
    expect(result.finish_reason).to eq("stop")
  end

  describe "#truncated?" do
    it "распознаёт обрыв по лимиту" do
      expect(response(finish_reason: "length")).to be_truncated
    end

    it "не считает обрывом обычное завершение" do
      expect(response(finish_reason: "stop")).not_to be_truncated
      expect(response).not_to be_truncated
    end
  end

  it "отдаёт кортеж в том порядке, в каком его разбирает клиент" do
    result = response(usage: { "total_tokens" => 20 }, finish_reason: "stop")

    expect(result.to_a).to eq(["готово", [], { "total_tokens" => 20 }, "stop"])
  end
end
