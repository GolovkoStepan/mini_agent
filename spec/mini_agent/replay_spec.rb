# frozen_string_literal: true

require "tmpdir"

RSpec.describe MiniAgent::Replay do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  # Журнал пишется Transcript и читается здесь: формат один, и записывать
  # его в тесте руками — единственный способ проверить разбор чужого файла,
  # включая тот, что оборвался на полуслове.
  def journal(*records)
    path = File.join(@dir, "session.jsonl")
    File.write(path, records.map { |r| "#{r.is_a?(String) ? r : JSON.generate(r)}\n" }.join)
    path
  end

  def message(role, content, **rest) = { type: "message", role: role, content: content, **rest }

  def replay(*records) = described_class.new(journal(*records))

  describe "разбор журнала" do
    it "восстанавливает сообщения в том порядке, в каком они были" do
      result = replay({ type: "session" }, message("system", "промпт"),
                      message("user", "задача"), message("assistant", "ответ"))

      expect(result.messages.map { |m| m[:content] }).to eq(%w[задача ответ])
    end

    # Системный промпт берётся нынешний: в нём рабочий каталог, система и
    # описание проекта, а всё это со вчерашней сессией могло измениться.
    it "выбрасывает системный промпт" do
      result = replay(message("system", "вчерашний промпт"), message("user", "задача"))

      expect(result.messages.map { |m| m[:role] }).to eq(["user"])
    end

    # usage уходил только в журнал (Conversation#push), и вернуться в
    # сообщение он не должен: история отправляется модели целиком.
    it "не тащит служебные поля обратно в сообщение" do
      result = replay(message("assistant", "ответ", usage: { "total_tokens" => 10 }, time: "сейчас"))

      expect(result.messages.first.keys).to eq(%i[role content])
    end

    it "не считает размышления сообщением" do
      result = replay({ type: "reasoning", content: "думаю" }, message("user", "задача"))

      expect(result.messages.length).to eq(1)
    end
  end

  # Журнал протоколирует то, что уходило модели, и не переписывается задним
  # числом. Значит, при чтении надо повторить то, что происходило с историей
  # на самом деле, — иначе продолженная сессия отправит модели то, чего в её
  # истории уже не было.
  describe "события, менявшие историю" do
    it "снимает откаченный ход" do
      result = replay(message("user", "задача"), message("user", "не дошло"),
                      { type: "rollback", removed: 1 })

      expect(result.messages.map { |m| m[:content] }).to eq(["задача"])
    end

    it "выбрасывает всё, что заменило резюме" do
      result = replay(message("user", "старое"), { type: "compact", before: 2 },
                      message("system", "промпт"), message("user", "резюме"))

      expect(result.messages.map { |m| m[:content] }).to eq(["резюме"])
    end

    it "выбрасывает историю исследования при одобренном плане" do
      result = replay(message("user", "изучи"), { type: "plan", before: 2 },
                      message("user", "выполняй план"))

      expect(result.messages.map { |m| m[:content] }).to eq(["выполняй план"])
    end

    # В один файл (--log) пишутся несколько запусков подряд, и продолжать
    # надо последний, а не всё вместе.
    it "берёт последнюю сессию файла, а не все подряд" do
      result = replay({ type: "session" }, message("user", "позавчера"),
                      { type: "session" }, message("user", "вчера"))

      expect(result.messages.map { |m| m[:content] }).to eq(["вчера"])
    end
  end

  # Хвост из вызовов без ответа остаётся после Ctrl+C и после убитого
  # процесса — то есть после ровно тех сессий, которые и продолжают.
  # Модель ждёт ответа на каждый tool_call_id, и такой хвост валит первый
  # же запрос новой сессии.
  describe "оборванный ход" do
    def call(id) = { "id" => id, "function" => { "name" => "bash", "arguments" => "{}" } }

    it "снимает вызовы, на которые не пришло ответа" do
      result = replay(message("user", "задача"),
                      message("assistant", nil, tool_calls: [call("a"), call("b")]),
                      message("tool", "вывод", tool_call_id: "a"))

      expect(result.messages.map { |m| m[:role] }).to eq(["user"])
    end

    it "оставляет ход, на который ответили полностью" do
      result = replay(message("assistant", nil, tool_calls: [call("a")]),
                      message("tool", "вывод", tool_call_id: "a"))

      expect(result.messages.length).to eq(2)
    end
  end

  # Последнюю запись убитого процесса могло не дописать: журнал пишется по
  # мере работы. Бракевать из-за этого целую сессию не за что, но и молчать
  # не следует — по числу видно, сколько потерялось.
  it "пропускает оборванные строки и считает их" do
    result = replay(message("user", "задача"), '{"type":"mess')

    expect(result.messages.length).to eq(1)
    expect(result.broken).to eq(1)
  end

  it "считает пустым журнал без сообщений" do
    expect(replay({ type: "session" })).to be_empty
  end

  describe "перенос в историю" do
    let(:conversation) { MiniAgent::History.new.build }

    it "кладёт сообщения всех ролей в новую историю" do
      result = replay(message("user", "задача"),
                      message("assistant", nil, tool_calls: [{ "id" => "a" }]),
                      message("tool", "вывод", tool_call_id: "a"),
                      message("assistant", "готово"))
      result.into(conversation)

      expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant tool assistant])
      expect(conversation.to_a.last[:content]).to eq("готово")
    end

    it "сохраняет вызовы инструментов целиком" do
      result = replay(message("assistant", nil, tool_calls: [{ "id" => "a", "type" => "function" }]),
                      message("tool", "вывод", tool_call_id: "a"))
      result.into(conversation)

      expect(conversation.to_a[1][:tool_calls]).to eq([{ "id" => "a", "type" => "function" }])
    end

    # История собирается заново, то есть с нынешним системным промптом:
    # он один и первый, и вчерашний в неё уже не вставить.
    it "возвращает ту же историю, что дали" do
      expect(replay(message("user", "задача")).into(conversation)).to be(conversation)
    end
  end
end
