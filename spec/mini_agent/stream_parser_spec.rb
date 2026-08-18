# frozen_string_literal: true

RSpec.describe MiniAgent::StreamParser do
  def chunk(delta, finish_reason: nil)
    choice = { "index" => 0, "delta" => delta, "finish_reason" => finish_reason }
    "data: #{{ "choices" => [choice] }.to_json}\n\n"
  end

  describe "текст" do
    it "склеивает содержимое из дельт" do
      parser = described_class.new
      parser.feed(chunk({ "role" => "assistant", "content" => "при" }))
      parser.feed(chunk({ "content" => "вет" }))

      expect(parser.content).to eq("привет")
    end

    it "отдаёт куски текста в блок по мере поступления" do
      pieces = []
      parser = described_class.new { |text| pieces << text }
      parser.feed(chunk({ "content" => "раз" }))
      parser.feed(chunk({ "content" => " два" }))

      expect(pieces).to eq(%w[раз] + [" два"])
    end

    it "запоминает причину остановки" do
      parser = described_class.new
      parser.feed(chunk({ "content" => "x" }, finish_reason: "length"))

      expect(parser.finish_reason).to eq("length")
    end

    it "переживает [DONE] и пустые строки" do
      parser = described_class.new
      parser.feed(chunk({ "content" => "готово" }))
      parser.feed("data: [DONE]\n\n")

      expect(parser.content).to eq("готово")
      expect(parser.finish_reason).to be_nil
    end

    # Комментарии для поддержания соединения приходят строками с двоеточия.
    it "пропускает строки, не начинающиеся с data:" do
      parser = described_class.new
      parser.feed(": keep-alive\n\n")
      parser.feed(chunk({ "content" => "текст" }))

      expect(parser.content).to eq("текст")
    end

    # Битый кусок не повод потерять весь ответ: остальные придут целыми.
    it "не роняет разбор на некорректном JSON" do
      parser = described_class.new
      parser.feed("data: {это не json\n\n")
      parser.feed(chunk({ "content" => "цел" }))

      expect(parser.content).to eq("цел")
    end
  end

  describe "границы кусков" do
    # Куски сокета не совпадают со строками: событие приезжает разрезанным.
    it "собирает событие, разрезанное между чтениями" do
      parser = described_class.new
      full = chunk({ "content" => "склеено" })
      parser.feed(full[0, 20])
      parser.feed(full[20..])

      expect(parser.content).to eq("склеено")
    end

    # Байты приходят в ASCII-8BIT, и русская буква занимает два байта:
    # разрез ровно посередине символа — обычное дело, а не редкость.
    # Назначать UTF-8 куску нельзя, только собранной строке.
    it "не портит русский текст, разрезанный посреди символа" do
      parser = described_class.new
      bytes = chunk({ "content" => "привет" }).dup.force_encoding(Encoding::BINARY)
      cut = bytes.index("привет".b) + 3 # середина второй буквы

      parser.feed(bytes[0, cut])
      parser.feed(bytes[cut..])

      expect(parser.content).to eq("привет")
      expect(parser.content.encoding).to eq(Encoding::UTF_8)
    end

    it "склеивает несколько событий из одного куска" do
      parser = described_class.new
      parser.feed(chunk({ "content" => "а" }) + chunk({ "content" => "б" }))

      expect(parser.content).to eq("аб")
    end
  end

  describe "вызовы инструментов" do
    it "склеивает имя и аргументы из разных дельт" do
      parser = described_class.new
      parser.feed(chunk({ "tool_calls" => [{ "index" => 0, "id" => "call_1", "type" => "function",
                                             "function" => { "name" => "bash", "arguments" => "" } }] }))
      parser.feed(chunk({ "tool_calls" => [{ "index" => 0, "function" => { "arguments" => "{\"command\":" } }] }))
      parser.feed(chunk({ "tool_calls" => [{ "index" => 0, "function" => { "arguments" => "\"ls\"}" } }] }))

      expect(parser.tool_calls).to eq(
        [{ "id" => "call_1", "type" => "function",
           "function" => { "name" => "bash", "arguments" => "{\"command\":\"ls\"}" } }]
      )
    end

    # Дельты разных вызовов чередуются, и склейка «по последнему пришедшему»
    # смешала бы аргументы в один нечитаемый JSON.
    it "не смешивает аргументы разных вызовов" do
      parser = described_class.new
      parser.feed(chunk({ "tool_calls" => [{ "index" => 0, "id" => "a",
                                             "function" => { "name" => "bash", "arguments" => "{\"c\":" } }] }))
      parser.feed(chunk({ "tool_calls" => [{ "index" => 1, "id" => "b",
                                             "function" => { "name" => "bash", "arguments" => "{\"d\":" } }] }))
      parser.feed(chunk({ "tool_calls" => [{ "index" => 0, "function" => { "arguments" => "1}" } }] }))
      parser.feed(chunk({ "tool_calls" => [{ "index" => 1, "function" => { "arguments" => "2}" } }] }))

      arguments = parser.tool_calls.map { |call| call["function"]["arguments"] }
      expect(arguments).to eq(["{\"c\":1}", "{\"d\":2}"])
    end

    it "упорядочивает вызовы по index, а не по приходу" do
      parser = described_class.new
      parser.feed(chunk({ "tool_calls" => [{ "index" => 1, "id" => "второй" }] }))
      parser.feed(chunk({ "tool_calls" => [{ "index" => 0, "id" => "первый" }] }))

      expect(parser.tool_calls.map { |call| call["id"] }).to eq(%w[первый второй])
    end

    it "отдаёт пустой список, когда вызовов не было" do
      parser = described_class.new
      parser.feed(chunk({ "content" => "просто текст" }))

      expect(parser.tool_calls).to eq([])
    end
  end

  describe "расход токенов" do
    # На LM Studio usage приезжает ОТДЕЛЬНЫМ куском, где choices пуст.
    # Обращение к choices[0] без оговорки роняло бы разбор на последнем куске.
    it "берёт usage из куска с пустым choices" do
      parser = described_class.new
      parser.feed(chunk({ "content" => "текст" }))
      parser.feed("data: #{{ "choices" => [], "usage" => { "prompt_tokens" => 16 } }.to_json}\n\n")

      expect(parser.usage).to include("prompt_tokens" => 16)
      expect(parser.content).to eq("текст")
    end

    it "оставляет usage пустым, когда сервер его не прислал" do
      parser = described_class.new
      parser.feed(chunk({ "content" => "текст" }))

      expect(parser.usage).to be_nil
    end
  end

  describe "размышления" do
    # Объём нужен для диагностики пустого ответа: по нему видно, на что ушёл
    # бюджет. В сам ответ размышления не попадают ни знаком.
    it "считает знаки reasoning_content, не смешивая с ответом" do
      parser = described_class.new
      parser.feed(chunk({ "reasoning_content" => "Надо подумать" }))
      parser.feed(chunk({ "content" => "ответ" }))

      expect(parser.content).to eq("ответ")
      expect(parser.reasoning_length).to eq("Надо подумать".length)
      expect(parser.reasoning_tail).to eq("Надо подумать")
    end

    # Дельты режутся сервером как попало, а бегущей строке нужен связный
    # хвост — склейка обязана быть сквозной, а не поштучной.
    it "склеивает хвост из дельт" do
      parser = described_class.new
      parser.feed(chunk({ "reasoning_content" => "Надо " }))
      parser.feed(chunk({ "reasoning_content" => "подумать" }))

      expect(parser.reasoning_tail).to eq("Надо подумать")
    end

    # В строку помещается не больше ширины терминала; держать ради этого
    # всю цепочку рассуждений — десятки тысяч знаков, которых никто не увидит.
    it "держит только хвост" do
      parser = described_class.new
      parser.feed(chunk({ "reasoning_content" => "старое" * 500 }))
      parser.feed(chunk({ "reasoning_content" => "свежее" }))

      expect(parser.reasoning_tail.length).to eq(described_class::TAIL_LIMIT)
      expect(parser.reasoning_tail).to end_with("свежее")
    end

    # Срез по байтам развалил бы русскую букву надвое — та же ошибка,
    # что ловилась на границе кусков сокета, только с другого конца.
    it "режет хвост по знакам, а не по байтам" do
      parser = described_class.new
      parser.feed(chunk({ "reasoning_content" => "щ" * (described_class::TAIL_LIMIT + 10) }))

      expect(parser.reasoning_tail).to eq("щ" * described_class::TAIL_LIMIT)
      expect(parser.reasoning_tail).to be_valid_encoding
    end
  end

  # Кортеж — тот же, что у ChatResponse: дальше по коду разницы между
  # потоковым и обычным ответом быть не должно.
  it "отдаёт кортеж того же вида, что и обычный ответ" do
    parser = described_class.new
    parser.feed(chunk({ "content" => "готово" }, finish_reason: "stop"))
    parser.feed("data: #{{ "choices" => [], "usage" => { "total_tokens" => 9 } }.to_json}\n\n")

    content, tool_calls, usage, finish_reason = parser.to_a

    expect(content).to eq("готово")
    expect(tool_calls).to eq([])
    expect(usage).to include("total_tokens" => 9)
    expect(finish_reason).to eq("stop")
  end
end
