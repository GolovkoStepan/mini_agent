# frozen_string_literal: true

RSpec.describe Evals::Journal do
  def call(name, arguments)
    { "id" => "call_1", "function" => { "name" => name, "arguments" => arguments } }
  end

  def lines(*records)
    records.map { |record| JSON.generate(record) }
  end

  it "считает ходы по ответам модели" do
    journal = described_class.new(lines(
                                    { "type" => "message", "role" => "user", "content" => "задача" },
                                    { "type" => "message", "role" => "assistant", "content" => "раз" },
                                    { "type" => "message", "role" => "tool", "content" => "вывод" },
                                    { "type" => "message", "role" => "assistant", "content" => "два" }
                                  ))

    expect(journal.turns).to eq(2)
  end

  # Определение повтора обязано совпадать с ToolCallRunner#count_repeat:
  # разойдись они — отчёт показывал бы ноль повторов там, где агент их
  # считает и обрывает задачу.
  it "считает повторами только подряд идущие одинаковые вызовы" do
    journal = described_class.new(lines(
                                    { "type" => "message", "role" => "assistant",
                                      "tool_calls" => [call("bash", "{\"command\":\"ls\"}")] },
                                    { "type" => "message", "role" => "assistant",
                                      "tool_calls" => [call("bash", "{\"command\":\"ls\"}")] },
                                    { "type" => "message", "role" => "assistant",
                                      "tool_calls" => [call("bash", "{\"command\":\"pwd\"}")] },
                                    { "type" => "message", "role" => "assistant",
                                      "tool_calls" => [call("bash", "{\"command\":\"ls\"}")] }
                                  ))

    expect([journal.tool_calls, journal.repeats]).to eq([4, 1])
  end

  # Сумма prompt_tokens смысла не имеет: история уходит модели целиком
  # на каждом ходу. Осмысленно последнее значение — оно и упирается в окно.
  it "берёт контекст последнего запроса, а сгенерированное складывает" do
    journal = described_class.new(lines(
                                    { "type" => "message", "role" => "assistant",
                                      "usage" => { "prompt_tokens" => 100, "completion_tokens" => 20 } },
                                    { "type" => "message", "role" => "assistant",
                                      "usage" => { "prompt_tokens" => 300, "completion_tokens" => 30 } }
                                  ))

    expect([journal.context_tokens, journal.generated_tokens]).to eq([300, 50])
  end

  it "складывает знаки размышлений и считает сворачивания с откатами" do
    journal = described_class.new(lines(
                                    { "type" => "reasoning", "content" => "а" * 40 },
                                    { "type" => "reasoning", "content" => "б" * 2 },
                                    { "type" => "compact", "before" => 9000 },
                                    { "type" => "rollback", "removed" => 2 }
                                  ))

    expect([journal.reasoning_chars, journal.compacts, journal.rollbacks]).to eq([42, 1, 1])
  end

  # Журнал пишется по сообщению, и убитый посреди записи процесс оставляет
  # обрывок. Это норма прерванного прогона, а не порча измерителя.
  it "пропускает недописанную строку, не теряя остальные" do
    journal = described_class.new([JSON.generate({ "type" => "message", "role" => "assistant" }),
                                   "{\"type\":\"mess"])

    expect(journal.turns).to eq(1)
  end

  # Агент мог упасть до открытия журнала (нет сервера, неверный --cwd).
  # Прогон при этом честно провалился, а измеритель цел.
  it "читает отсутствующий файл как пустой журнал" do
    journal = described_class.read("/нет/такого/файла.jsonl")

    expect([journal.turns, journal.context_tokens]).to eq([0, nil])
  end

  it "читает журнал с диска" do
    dir = Dir.mktmpdir
    path = File.join(dir, "log.jsonl")
    File.write(path, "#{JSON.generate({ "type" => "message", "role" => "assistant" })}\n")

    expect(described_class.read(path).turns).to eq(1)
  ensure
    FileUtils.remove_entry(dir)
  end
end
