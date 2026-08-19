# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe MiniAgent::Tools::EditFile do
  let(:dir) { Dir.mktmpdir }
  let(:guard) { MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new) }
  let(:path) { File.join(dir, "a.rb") }

  after { FileUtils.remove_entry(dir) }

  subject(:tool) { described_class.new(guard: guard, cwd: dir) }

  def edit(old_text, new_text, file: "a.rb")
    tool.call({ "path" => file, "old_text" => old_text, "new_text" => new_text })
  end

  it "объявляет имя и схему для модели" do
    expect(tool.name).to eq("edit_file")
    expect(tool.schema.dig("function", "name")).to eq("edit_file")
    expect(tool.schema.dig("function", "parameters", "required")).to eq(%w[path old_text new_text])
  end

  it "заменяет кусок и оставляет остальное нетронутым" do
    File.write(path, "первая\nвторая\nтретья\n")
    result = edit("вторая", "ВТОРАЯ")

    expect(File.read(path)).to eq("первая\nВТОРАЯ\nтретья\n")
    expect(result).to include("изменён")
  end

  it "удаляет кусок при пустом new_text" do
    File.write(path, "a\nb\nc\n")
    edit("b\n", "")

    expect(File.read(path)).to eq("a\nc\n")
  end

  # sub с блоком, а не со строкой: в строке замены Ruby разбирает \1, \0 и \\
  # как обратные ссылки, и текст записался бы искажённым. В коде это обычные
  # знаки — регулярные выражения, пути, экранирование в строках.
  it "не разбирает обратные ссылки в новом тексте" do
    replacement = 'text.sub(/(\d+)/) { "\1\0\\" }'
    File.write(path, "было\n")
    edit("было", replacement)

    expect(File.read(path)).to eq("#{replacement}\n")
  end

  it "ищет дословно, вместе с пробелами" do
    File.write(path, "  отступ\n")

    expect(edit("отступ\n", "иначе\n")).to include("изменён")
    expect(File.read(path)).to eq("  иначе\n")
  end

  # Найденное дважды — это отказ, а не выбор первого попавшегося: первое
  # попавшееся невозможно проверить по результату, и ошибка вылезет через
  # десяток ходов в чужом месте.
  it "отказывается править неоднозначный кусок и не трогает файл" do
    File.write(path, "x = 1\ny = 1\n")
    result = edit("= 1", "= 2")

    expect(result).to include("2 раза")
    expect(File.read(path)).to eq("x = 1\ny = 1\n")
  end

  it "сообщает, что кусок не найден" do
    File.write(path, "текст\n")

    expect(edit("нет такого", "другое")).to include("не найден")
    expect(File.read(path)).to eq("текст\n")
  end

  it "требует непустой old_text" do
    File.write(path, "текст\n")

    expect(edit("", "другое")).to eq(MiniAgent::Messages::Tool::EDIT_NO_OLD_TEXT)
    expect(File.read(path)).to eq("текст\n")
  end

  it "сообщает об отсутствующем файле" do
    expect(edit("a", "b", file: "нет.rb")).to include("не существует")
  end

  it "не правит каталог" do
    Dir.mkdir(File.join(dir, "sub"))

    expect(edit("a", "b", file: "sub")).to include("каталог, а не файл")
  end

  it "сообщает о пустом пути" do
    expect(tool.call({ "old_text" => "a", "new_text" => "b" })).to eq(MiniAgent::Messages::Tool::FILE_NO_PATH)
  end

  # Читать двоичный файл с заменой негодных байтов можно — там ничего не
  # портится; записать его обратно значило бы закрепить замену навсегда.
  it "отказывается править не-UTF-8, вместо того чтобы испортить файл" do
    binary = File.join(dir, "binary")
    File.binwrite(binary, "начало\xC3\x28конец")
    result = tool.call({ "path" => "binary", "old_text" => "начало", "new_text" => "НАЧАЛО" })

    expect(result).to include("не является текстом")
    expect(File.binread(binary)).to eq("начало\xC3\x28конец".b)
  end

  it "не правит ничего, когда человек отказал" do
    File.write(path, "текст\n")
    guard = MiniAgent::CommandGuard.new(policy: :ask, prompt: MiniAgent::Prompt::AutoDeny.new)
    result = described_class.new(guard: guard, cwd: dir)
                            .call({ "path" => "a.rb", "old_text" => "текст", "new_text" => "иначе" })

    expect(result).to eq(MiniAgent::Messages::CANCELLED)
    expect(File.read(path)).to eq("текст\n")
  end

  it "отвергается режимом планирования, ничего не изменив" do
    File.write(path, "текст\n")
    guard = MiniAgent::CommandGuard.new(prompt: MiniAgent::Prompt::AutoApprove.new,
                                        plan_mode: MiniAgent::PlanMode.new(enabled: true))
    result = described_class.new(guard: guard, cwd: dir)
                            .call({ "path" => "a.rb", "old_text" => "текст", "new_text" => "иначе" })

    expect(result).to eq(MiniAgent::Messages::PLAN_REFUSED)
    expect(File.read(path)).to eq("текст\n")
  end
end
