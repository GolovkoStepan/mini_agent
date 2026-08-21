# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe MiniAgent::AgentBuilder do
  let(:dir) { Dir.mktmpdir }
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:config) { MiniAgent::Config.new({ base_url: "http://builder.test/v1", cwd: dir }, env: {}) }

  after { FileUtils.remove_entry(dir) }

  before { stub_request(:get, %r{/api/v1/models}).to_return(status: 404, body: "") }

  subject(:builder) { described_class.new(config: config, ui: ui) }

  # Инструмент, не попавший в реестр, модели не виден вовсе, и заметить это
  # можно только по тому, что она обходится без него — то есть никак.
  it "собирает реестр со всеми инструментами" do
    builder.call do |_agent, tools|
      expect(tools.names).to contain_exactly("bash", "read_file", "write_file", "edit_file")
    end
  end

  # Каталог у файловых инструментов тот же, что уходит в chdir: ProcessRunner.
  # Разойдись они — `ls` показывал бы один каталог, а read_file читал бы
  # из другого, и заметить это можно было бы только по содержимому файлов.
  it "даёт файловым инструментам рабочий каталог агента" do
    File.write(File.join(dir, "a.txt"), "оттуда")

    builder.call do |_agent, tools|
      expect(tools.dispatch("read_file", { "path" => "a.txt" })).to eq("оттуда")
    end
  end
end
