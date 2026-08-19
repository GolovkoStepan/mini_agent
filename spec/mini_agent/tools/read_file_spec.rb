# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe MiniAgent::Tools::ReadFile do
  let(:dir) { Dir.mktmpdir }
  let(:guard) { MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new) }

  after { FileUtils.remove_entry(dir) }

  subject(:tool) { described_class.new(guard: guard, cwd: dir) }

  it "объявляет имя и схему для модели" do
    expect(tool.name).to eq("read_file")
    expect(tool.schema.dig("function", "name")).to eq("read_file")
    expect(tool.schema.dig("function", "parameters", "required")).to eq(["path"])
  end

  it "отдаёт содержимое файла как есть" do
    File.write(File.join(dir, "a.txt"), "привет\nмир\n")

    expect(tool.call({ "path" => "a.txt" })).to eq("привет\nмир\n")
  end

  # Номеров строк нет намеренно: edit_file ищет текст дословно, и модель,
  # увидевшая файл с номерами, вставила бы их в old_text.
  it "не добавляет к строкам номеров" do
    File.write(File.join(dir, "a.txt"), "первая\nвторая\n")

    expect(tool.call({ "path" => "a.txt" })).not_to match(/^\s*1[:|]/)
  end

  it "читает по абсолютному пути" do
    path = File.join(dir, "a.txt")
    File.write(path, "текст")

    expect(tool.call({ "path" => path })).to eq("текст")
  end

  # Путь разрешается от рабочего каталога агента, а не от каталога запуска:
  # с --cwd это разные места, и читать не оттуда, где работают команды, —
  # худшее из возможных поведений.
  it "разрешает относительный путь от рабочего каталога" do
    Dir.mkdir(File.join(dir, "sub"))
    File.write(File.join(dir, "sub", "b.txt"), "вложенный")

    expect(tool.call({ "path" => "sub/b.txt" })).to eq("вложенный")
  end

  it "сообщает об отсутствующем файле, а не молчит" do
    expect(tool.call({ "path" => "нет.txt" })).to include("не существует")
  end

  it "сообщает о пустом пути" do
    expect(tool.call({ "path" => "  " })).to eq(MiniAgent::Messages::Tool::FILE_NO_PATH)
    expect(tool.call({})).to eq(MiniAgent::Messages::Tool::FILE_NO_PATH)
  end

  it "не пытается читать каталог" do
    Dir.mkdir(File.join(dir, "sub"))

    expect(tool.call({ "path" => "sub" })).to include("каталог, а не файл")
  end

  # Пустая строка в ответе неотличима от «инструмент ничего не вернул»,
  # и модель принимается искать несуществующую ошибку.
  it "говорит словами, что файл пуст" do
    File.write(File.join(dir, "empty.txt"), "")

    expect(tool.call({ "path" => "empty.txt" })).to include("существует и пуст")
  end

  it "отказывается тянуть в память слишком большой файл" do
    File.write(File.join(dir, "big.bin"), "x" * (described_class::MAX_BYTES + 1))

    expect(tool.call({ "path" => "big.bin" })).to include("слишком велик")
  end

  # Та же граница и та же причина, что у ProcessRunner: испорченная строка
  # иначе доезжает до сборки тела запроса и роняет агента JSON-ошибкой.
  it "заменяет негодные байты, а не роняет агента" do
    File.binwrite(File.join(dir, "binary"), "нормально\xC3\x28ещё")
    result = tool.call({ "path" => "binary" })

    expect(result.valid_encoding?).to be(true)
    expect { JSON.generate({ "result" => result }) }.not_to raise_error
  end

  # Чтение читает: в планировании оно обязано проходить, иначе план по
  # незнакомому проекту не составить.
  it "работает в режиме планирования" do
    File.write(File.join(dir, "a.txt"), "текст")
    guard = MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoDeny.new,
                                        plan_mode: MiniAgent::PlanMode.new(enabled: true))

    expect(described_class.new(guard: guard, cwd: dir).call({ "path" => "a.txt" })).to eq("текст")
  end

  # Вопрос про выход за рабочий каталог задаётся только записи: заглянуть
  # в чужой файл — обычное дело (конфиг, соседний проект), и подтверждение
  # на каждое такое чтение стало бы шумом, за которым не видно записи.
  it "не спрашивает про чтение за пределами рабочего каталога" do
    outside = File.join(Dir.mktmpdir, "a.txt")
    File.write(outside, "текст")
    prompt = instance_spy(MiniAgent::Prompt)
    guard = MiniAgent::CommandGuard.new(prompt: prompt)

    expect(described_class.new(guard: guard, cwd: dir).call({ "path" => outside })).to eq("текст")
    expect(prompt).not_to have_received(:confirm?)
  end

  # Ошибка файловой системы — это результат, который модель должна прочитать
  # и обработать, а не исключение, роняющее цикл агента.
  it "возвращает ошибку доступа строкой" do
    path = File.join(dir, "secret.txt")
    File.write(path, "текст")
    File.chmod(0o000, path)

    expect(tool.call({ "path" => "secret.txt" })).to include("Ошибка файловой операции")
  ensure
    File.chmod(0o600, path)
  end
end
