# Обёртка над bundler/rake/rspec: одни и те же вызовы для человека и для агента.
# `make` без цели — полная проверка (тесты + линтер), как `rake` по умолчанию.

.DEFAULT_GOAL := check
.PHONY: help setup check spec lint lint-fix rbs run repl console evals build install uninstall clean

BUNDLE ?= bundle exec
GEM_VERSION := $(shell ruby -Ilib -rmini_agent/version -e 'print MiniAgent::VERSION')
GEM_FILE := mini_agent-$(GEM_VERSION).gem

# Аргументы целей: FILE — путь к спеке (можно с :номером строки),
# TASK — задача для агента, ARGS — произвольные флаги CLI.
FILE ?=
TASK ?=
ARGS ?=

# Аргументы стенда: TASKS/PRESETS — имена через запятую, RUNS — прогонов
# на пару «задача × набор».
TASKS ?=
PRESETS ?=
RUNS ?=
EVAL_ARGS = $(if $(TASKS),--tasks $(TASKS)) $(if $(PRESETS),--presets $(PRESETS)) \
	$(if $(RUNS),--runs $(RUNS))

help: ## Список целей
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN { FS = ":.*?## " } { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }'

setup: ## Установить зависимости
	bin/setup

check: ## Тесты и линтер (цель по умолчанию)
	$(BUNDLE) rake

spec: ## Тесты; FILE=spec/mini_agent/agent_spec.rb:42 — один файл или пример
	$(BUNDLE) rspec $(FILE)

lint: ## Линтер
	$(BUNDLE) rubocop

lint-fix: ## Автоисправление линтера
	$(BUNDLE) rubocop -a

# uri подключается явно: без него не резолвится URI::Generic из сигнатур.
rbs: ## Проверить сигнатуры типов
	$(BUNDLE) rbs -r uri -I sig validate

# TASK в кавычках: иначе задача из нескольких слов разъедется на аргументы.
# ARGS без кавычек намеренно — это набор флагов.
run: ## Разовый запуск; TASK="задача" [ARGS="--model ..."]
	$(BUNDLE) ruby -Ilib exe/mini_agent $(ARGS) "$(TASK)"

repl: ## Интерактивный режим агента; [ARGS="--model ..."]
	$(BUNDLE) ruby -Ilib exe/mini_agent -i $(ARGS)

console: ## IRB с загруженным гемом
	bin/console

# Ходит к настоящей модели и идёт часами — в `make check` не входит намеренно.
# ARGS после -- уходят агенту: ARGS="--model qwen3-coder".
evals: ## Оценочные задачи; [TASKS=a,b] [PRESETS=server,tuned] [RUNS=5] [ARGS="..."]
	$(BUNDLE) ruby evals/run.rb $(EVAL_ARGS) $(if $(ARGS),-- $(ARGS))

build: ## Собрать гем
	gem build mini_agent.gemspec

install: build ## Собрать и установить гем локально
	gem install ./$(GEM_FILE)

uninstall: ## Удалить установленный гем
	gem uninstall mini_agent -x -a

clean: ## Убрать артефакты сборки и кэш тестов
	rm -f ./*.gem .rspec_status
