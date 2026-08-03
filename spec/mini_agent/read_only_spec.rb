# frozen_string_literal: true

RSpec.describe MiniAgent::ReadOnly do
  describe ".command?" do
    readers = [
      "ls -la",
      "cat README.md",
      "pwd",
      "head -20 lib/mini_agent/agent.rb",
      "grep -rn TODO lib",
      "rg --files",
      "wc -l spec/**/*.rb",
      "git status",
      "git log --oneline -10",
      "git diff HEAD~1",
      "git ls-files",
      "cat Gemfile | grep rspec",
      "ls lib && ls spec",
      "cat a.txt; cat b.txt",
      "ls | head -5 | wc -l",
      "echo привет",
      "which ruby",
      "file lib/mini_agent.rb"
    ]

    writers = [
      # Пишущие в явном виде.
      "rm tmp/cache",
      "mkdir -p tmp",
      "touch new.rb",
      "bundle exec rspec",
      "rake",
      "make test",
      "git commit -m x",
      "git push",
      "git checkout master",
      # Читающая команда в связке с пишущей: достаточно одной части.
      "ls | tee out.txt",
      "cat a.txt && rm a.txt",
      "cat Gemfile; bundle install",
      # Перенаправление — это запись, каким бы читающим ни было начало.
      "cat README.md > copy.md",
      "echo привет >> file.txt",
      "wc -l < input.txt",
      # Подстановка команды: внутри может быть что угодно.
      "echo $(rm -rf /tmp/x)",
      "cat `find . -name '*.rb'`",
      # Фоновый запуск прячет вторую команду за одиночным амперсандом.
      "ls & rm -rf /tmp/x",
      "sleep 300 &",
      # Пустое.
      "",
      "   "
    ]

    readers.each do |command|
      it "считает читающей: #{command}" do
        expect(described_class.command?(command)).to be(true)
      end
    end

    writers.each do |command|
      it "не считает читающей: #{command.inspect}" do
        expect(described_class.command?(command)).to be(false)
      end
    end

    # Разбор идёт по словам и кавычек не понимает. Проверяем не то, что он
    # их разбирает, а то, что ошибка всегда в сторону лишнего вопроса:
    # признать пишущую команду читающей нельзя ни при каких кавычках.
    it "ошибается в сторону отказа, когда разделитель стоит внутри кавычек" do
      expect(described_class.command?("echo 'a; b'")).to be(false)
    end

    it "не пропускает выполнение чужой команды через xargs" do
      expect(described_class.command?("ls | xargs rm")).to be(false)
    end

    it "не пропускает git-подкоманды, умеющие писать" do
      expect(described_class.command?("git branch -d master")).to be(false)
      expect(described_class.command?("git config user.name x")).to be(false)
    end

    it "не считает читающей команду, начинающуюся именем из списка как частью слова" do
      expect(described_class.command?("catalog-tool run")).to be(false)
    end
  end
end
