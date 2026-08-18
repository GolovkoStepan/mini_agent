# frozen_string_literal: true

module MiniAgent
  # Свернуть диалог самостоятельно, когда окно кончается.
  #
  # Отвечает на один вопрос — «пора ли», — и сама работа остаётся у Compactor.
  # Разделение не косметическое: /compact сворачивает по прямой просьбе и обязан
  # объяснить отказ, а здесь отказ означает «дальше живём как есть» и повторять
  # его на каждом ходу нельзя.
  #
  # Контракт тот же, что у Compactor: возвращает прежний объект, если история
  # не менялась. Тождество объекта — единственный признак, по которому вызвавший
  # отличает одно от другого.
  class AutoCompactor
    # Какую часть контекста сворачивание обязано освободить, чтобы считаться
    # удачным. Порог, а не «стало хоть немного меньше», — из живой проверки:
    # при первом сворачивании диалог ужался с 11275 знаков до 1552, а на
    # следующем ходу теснота никуда не делась, и второе сворачивание дало
    # 1794 → 1514. Формально выигрыш, по делу — потраченный ход и потерянная
    # нить задачи: модель после него переспросила, чем ещё помочь, вместо
    # ответа. Сворачивать нечего — надо останавливаться, а не выигрывать
    # проценты.
    #
    # Условие project_dominates? этот случай не ловит: описание проекта может
    # занимать и сорок процентов, до половины не дотягивая.
    MIN_GAIN = 0.2

    def initialize(compactor:, config:, ui:, usage: nil)
      @compactor = compactor
      @config = config
      @ui = ui
      @usage = usage
      @given_up = false
    end

    # Зовётся перед каждым запросом к модели, а не после неудачного: после
    # упора в окно сворачивание уже не проходит — чтобы получить резюме,
    # историю надо отправить целиком, то есть сделать ровно тот запрос,
    # который перестал проходить. Отсюда и порог WARN_AT: сворачиваем
    # заранее, на трёх четвертях.
    def call(conversation)
      return conversation unless @config.auto_compact?
      return conversation if @given_up

      report = ContextReport.new(conversation, usage: @usage, config: @config)
      window = report.window
      return conversation unless window.tight?

      # Запрос не делается вовсе: сворачивать в этом случае нечего, и целый
      # ход к модели ушёл бы на резюме, которое места не освободит.
      if report.project_dominates?
        return give_up(conversation, format(Messages::AUTO_COMPACT_PROJECT, percent: window.percent))
      end

      @ui.warn(format(Messages::AUTO_COMPACT_RUNNING, percent: window.percent))
      compact(conversation, report)
    end

    private

    def compact(conversation, before)
      result = @compactor.call(conversation)
      # Отказ Compactor уже объяснил своими словами — здесь добавляется только
      # то, чего он не знает: повторять попытку никто не будет.
      return give_up(conversation, Messages::AUTO_COMPACT_REFUSED) if result.equal?(conversation)
      return give_up(result, Messages::AUTO_COMPACT_NO_GAIN) unless gained?(before, result)

      result
    end

    # Освободилось ли ощутимо. Меряется знаками, а не токенами: пересчёт
    # одного в другое отвергнут по всему проекту, а для сравнения «до» и
    # «после» одной и той же историей знаков достаточно.
    def gained?(before, after)
      ContextReport.new(after).total <= before.total * (1 - MIN_GAIN)
    end

    # Сдаёмся до конца сессии, и сообщение печатается один раз.
    #
    # Признак нужен потому, что теснота сама по себе не проходит: усечённое
    # резюме, описание проекта во всё окно, отказавший сервер — на следующем
    # ходу условие выполнится снова, и агент упёрся бы в ту же стену, печатая
    # то же предупреждение до конца задачи. Второй случай, когда без признака
    # не обойтись: usage обнуляется при сборке новой истории, поэтому после
    # неудачной попытки теснота меряется по старому промпту.
    #
    # Возвращается тот объект, что передали: сдача — не откат. Если резюме
    # всё-таки получилось, но места не дало, история остаётся свёрнутой.
    def give_up(conversation, message)
      @given_up = true
      @ui.warn(message)
      conversation
    end
  end
end
