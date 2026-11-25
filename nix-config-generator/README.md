# Nix config generator для Noctalia

Плагин `local/nix-config-generator` автоматически записывает настройки Noctalia в Nix-файл,
кроме выбранных путей. Ручной файл плагин не создаёт и не изменяет. Функции
восстановления нет.

Источник — `noctalia config export merged --credentials omit`: конфиг из всех
`*.toml` в директории конфигурации вместе с GUI-изменениями из `settings.toml`.
Режим `full` дополнительно включает встроенные значения по умолчанию.
Сервис проверяет изменения примерно раз в две секунды.

## Установка

Добавь Git-репозиторий как источник плагинов:

```sh
noctalia msg plugins source add nix-config-generator git https://github.com/BlockedSte899/noctalia-plugins
noctalia msg plugins enable local/nix-config-generator
```

Для локальной разработки вместо Git-источника можно добавить `path`-источник,
указав путь к корню клонированного репозитория.

В настройках плагина выбери **новый** путь, например
`/home/nikita/nixos-config/home-manager/modules/noctalia/generated.nix`.
Плагин не перезаписывает чужие файлы, включая ранее созданный другим
экспортёром `noctalia.nix`. Встроенный по умолчанию путь —
`~/.config/noctalia/nix-config-generator.nix`.

Если использовалась предыдущая версия `local/selective-nix`, её настройки
плагина автоматически не перенесутся: укажи целевой путь и исключения заново.
Прежние файлы с маркером `local/selective-nix-auto-v2` совместимы с новой версией.

Второй экспортёр, если включён, лучше отключить:

```sh
noctalia msg plugins disable dmopp/settings-to-nix
```

## Исключения

В настройке **Ручные пути (исключения)** укажи по одному пути на элемент списка:

- `calendar.account` — все учётные записи; это значение по умолчанию.
- `calendar.account.personal.server_url` — только один параметр.
- `plugin_settings.*.password` — один произвольный сегмент.
- `calendar.**.password` — любое количество промежуточных сегментов.
- `plugin_settings.owner/plugin\.name` — `\.` означает точку внутри имени.

Исключение распространяется на всё поддерево. Массивы, в том числе массивы
таблиц, обрабатываются целиком: исключи путь к массиву, например
`control_center.shortcuts`. Если шаблон указывает внутрь массива, экспорт
прервётся с ошибкой вместо возможной утечки исключённого значения.
Исключённые данные никуда не копируются — перенеси нужные значения в ручной
конфиг самостоятельно.

## Подключение в Home Manager

Сгенерированный файл возвращает обычный набор Nix-атрибутов. Например, после
первого экспорта и создания `manual.nix` в той же директории:

```nix
{ inputs, lib, osConfig, ... }:
{
  imports = [ inputs.noctalia.homeModules.default ];
  programs.noctalia = {
    enable = true;
    settings = lib.recursiveUpdate
      (import ./generated.nix)
      (import ./manual.nix { inherit osConfig; });
  };
}
```

Здесь `manual.nix` имеет приоритет, а не просто дополняет автоматический файл.
Списки заменяются целиком. Файл не создаётся плагином:

```nix
{ osConfig }:
{
  calendar.account.personal = {
    type = "caldav";
    provider = "custom";
    server_url = "https://dav.example.com/remote.php/dav/";
    username = "user";
    credential_source = "file";
    password_file = osConfig.age.secrets.noctalia-caldav.path;
  };
}
```

Для CalDAV в Noctalia 5.6 путь `password_file` указывает на файл, который
Noctalia читает при синхронизации. Настрой agenix отдельно: расшифрованный файл
должен быть доступен пользователю Noctalia. Не используй `builtins.readFile` для
пароля: это может раскрыть его в Nix store. Укажи `server_url` вручную: режим
`--credentials omit` удаляет этот ключ даже без исключения `calendar.account`.
Не помещай чувствительный URL в Git.

Текущий проект использует `programs.noctalia.settings = ./noctalia.toml`;
подключение выше **заменяет** эту строку и требует ручной проверки перед
пересборкой. GUI-оверрайды в `~/.local/state/noctalia/settings.toml` могут иметь
приоритет над статическими настройками; плагин их не удаляет и не изменяет.
Если конфиг собирается как flake из Git, добавь новые Nix-файлы в Git до сборки.

## Безопасность и ограничения

- `--credentials omit` исключает значения, которые Noctalia сама распознаёт как
  чувствительные, но не гарантирует обнаружение произвольных секретов.
  Исключай свои секретные пути и проверяй сгенерированный файл перед коммитом.
- При фильтрации настройки из GUI **не меняются**, только исключаются из экспорта.
- Экспорт не может вернуть значения, которых уже нет ни в одном источнике Noctalia.
- Неподдерживаемые нечисловые значения `inf`/`nan` вызывают ошибку; файл не
  перезаписывается. При некорректном TOML или обрезанном выводе CLI — тоже.
- Запись выполняется через временный файл и переименование. Если доступен
  `nix-instantiate`, перед записью проверяется синтаксис.

## Проверки

```sh
noctalia plugins lint ./nix-config-generator
cd nix-config-generator
nix shell nixpkgs#luau -c luau tests/core.luau
nix shell nixpkgs#luau nixpkgs#python3 -c bash tests/live-export.sh
```

Последний тест читает текущий объединённый конфиг, но не изменяет настройки
Noctalia. Временные данные удаляются после проверки.

Происхождение заимствованного кода — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
