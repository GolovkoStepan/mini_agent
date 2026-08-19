# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe MiniAgent::Tools::WriteFile do
  let(:dir) { Dir.mktmpdir }
  let(:guard) { MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new) }

  after { FileUtils.remove_entry(dir) }

  subject(:tool) { described_class.new(guard: guard, cwd: dir) }

  it "объявляет имя и схему для модели" do
    expect(tool.name).to eq("write_file")
    expect(tool.schema.dig("function", "name")).to eq("write_file")
    expect(tool.schema.dig("function", "parameters", "required")).to eq(%w[path content])
  end

  it "создаёт файл и говорит, что создал" do
    result = tool.call({ "path" => "a.txt", "content" => "привет\nмир\n" })

    expect(File.read(File.join(dir, "a.txt"))).to eq("привет\nмир\n")
    expect(result).to include("создан")
  end

  # Текст приходит отдельным полем JSON и до shell не доходит вовсе: ровно
  # то, ради чего инструмент заведён. Кавычки, разделители heredoc и знаки
  # подстановки здесь просто знаки.
  it "пишет текст дословно, без разбора кавычек и подстановок" do
    content = %(x = "$HOME"\nEOF\n`date`\n'\\1'\n)
    tool.call({ "path" => "a.sh", "content" => content })

    expect(File.read(File.join(dir, "a.sh"))).to eq(content)
  end

  # «Перезаписан» против «создан» не даёт выдать замену чужого файла
  # за создание своего, а числа — единственный способ для модели заметить,
  # что вместо файла на 200 строк записалось 3.
  it "различает перезапись и создание и называет размер" do
    File.write(File.join(dir, "a.txt"), "старое")
    result = tool.call({ "path" => "a.txt", "content" => "одна\nдве\n" })

    expect(result).to include("перезаписан")
    expect(result).to include("2 строки")
    expect(result).to include("9 знаков")
  end

  it "пишет по относительному пути от рабочего каталога" do
    Dir.mkdir(File.join(dir, "sub"))
    tool.call({ "path" => "sub/b.txt", "content" => "текст" })

    expect(File.read(File.join(dir, "sub", "b.txt"))).to eq("текст")
  end

  # Молчаливый mkdir_p превращает опечатку в пути в новое дерево каталогов,
  # и модель докладывает об успехе, записав файл не туда.
  it "не создаёт каталог сам, а отказывается" do
    result = tool.call({ "path" => "нет/b.txt", "content" => "текст" })

    expect(result).to include("не существует")
    expect(File.exist?(File.join(dir, "нет"))).to be(false)
  end

  it "не пишет поверх каталога" do
    Dir.mkdir(File.join(dir, "sub"))

    expect(tool.call({ "path" => "sub", "content" => "текст" })).to include("каталог, а не файл")
  end

  it "сообщает о пустом пути" do
    expect(tool.call({ "content" => "текст" })).to eq(MiniAgent::Messages::Tool::FILE_NO_PATH)
  end

  it "считает отсутствующий content пустым файлом, а не падает" do
    tool.call({ "path" => "a.txt" })

    expect(File.read(File.join(dir, "a.txt"))).to eq("")
  end

  # Отказ обязан говорить, что ничего не изменилось: на коротком «отменено»
  # модель рапортует о созданном файле (грабли CANCELLED).
  it "не пишет ничего, когда человек отказал" do
    guard = MiniAgent::CommandGuard.new(policy: :ask, prompt: MiniAgent::Prompt::AutoDeny.new)
    result = described_class.new(guard: guard, cwd: dir).call({ "path" => "a.txt", "content" => "текст" })

    expect(result).to eq(MiniAgent::Messages::CANCELLED)
    expect(File.exist?(File.join(dir, "a.txt"))).to be(false)
  end

  it "отвергается режимом планирования, ничего не записав" do
    guard = MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new,
                                        plan_mode: MiniAgent::PlanMode.new(enabled: true))
    result = described_class.new(guard: guard, cwd: dir).call({ "path" => "a.txt", "content" => "текст" })

    expect(result).to eq(MiniAgent::Messages::PLAN_REFUSED)
    expect(File.exist?(File.join(dir, "a.txt"))).to be(false)
  end
end
