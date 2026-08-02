# frozen_string_literal: true

RSpec.describe MiniAgent::Usage do
  subject(:usage) { described_class.new }

  it "пуст, пока запросов не было" do
    expect(usage).to be_empty
    expect(usage.to_h).to eq(sent: 0, generated: 0, context: 0, requests: 0)
  end

  it "считает один ответ" do
    usage.add({ "prompt_tokens" => 13, "completion_tokens" => 5 })

    expect(usage).not_to be_empty
    expect(usage.to_h).to eq(sent: 13, generated: 5, context: 13, requests: 1)
  end

  # Главное свойство класса. История уходит модели целиком на каждом ходу,
  # поэтому prompt_tokens растёт от запроса к запросу — числа взяты из живого
  # замера на LM Studio. Их сумма (102) не значит ничего, осмысленно последнее
  # значение: это текущий размер контекста.
  it "запоминает последний промпт, а не складывает промпты" do
    usage.add({ "prompt_tokens" => 13, "completion_tokens" => 5 })
    usage.add({ "prompt_tokens" => 32, "completion_tokens" => 5 })
    usage.add({ "prompt_tokens" => 57, "completion_tokens" => 5 })

    expect(usage.context).to eq(57)
    expect(usage.generated).to eq(15)
  end

  it "складывает отправленное за все запросы" do
    usage.add({ "prompt_tokens" => 13, "completion_tokens" => 5 })
    usage.add({ "prompt_tokens" => 32, "completion_tokens" => 5 })

    expect(usage.sent).to eq(45)
  end

  # Спецификация usage не требует, и не всякий сервер его шлёт.
  describe "ответ без usage" do
    it "не считает отсутствующий usage за запрос" do
      usage.add(nil)

      expect(usage).to be_empty
    end

    it "не ломается на неполном usage" do
      usage.add({ "prompt_tokens" => 10 })

      expect(usage.to_h).to eq(sent: 10, generated: 0, context: 10, requests: 1)
    end
  end

  # Из JSON ключи приходят строками, из рукописных стабов — символами.
  it "принимает и строковые, и символьные ключи" do
    usage.add({ prompt_tokens: 7, completion_tokens: 3 })

    expect(usage.to_h).to include(sent: 7, generated: 3)
  end
end
