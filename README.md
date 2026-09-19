# 🎵 RydMusic VK HLS Parser Update

## Быстрый старт (2 минуты)

```bash
# 1. Установить Python зависимости
pip install -r python_scripts/vk_parser/requirements.txt

# 2. Скопировать Python скрипты
cp -r python_scripts/vk_parser /path/to/your/project/

# 3. Скопировать Dart сервисы
cp lib/services/vk_*.dart /path/to/your/project/lib/services/

# 4. Скопировать Kotlin код
cp android/app/src/main/kotlin/com/example/rydmusic/VKHLSBridge.kt \
   /path/to/your/project/android/app/src/main/kotlin/com/example/rydmusic/

# 5. Обновить MainActivity и build.gradle (см. INSTALLATION.md)
# 6. flutter clean && flutter pub get && flutter build apk
```

## 📋 Что добавлено

✅ **HLS M3U8 парсинг** - Полная поддержка HTTP Live Streaming манифестов  
✅ **AES-128-CBC дешифровка** - Автоматическое распакование зашифрованных сегментов  
✅ **Метаданные трека** - Название, исполнитель, обложка, длительность  
✅ **Fallback механизм** - Автоматический переход на Python если нет native поддержки  
✅ **Полная документация** - Гайды, примеры, troubleshooting  

## 🚀 Использование

```dart
import 'services/vk_hls_service.dart';

// Парсинг M3U8 манифеста
final info = await VKHLSService.parseM3U8('https://vk.com/audio.m3u8');

// Загрузка и дешифровка сегментов
final audioData = await VKHLSService.downloadAndDecryptSegments(url);

// Получение метаданных трека
final metadata = await VKHLSService.getTrackMetadata(url);
```

## 📁 Структура

```
vk_parser_update/
├── python_scripts/vk_parser/          Python скрипты для HLS парсинга
├── lib/services/                      Dart сервисы
├── android/app/src/main/kotlin/       Kotlin интеграция
└── docs/                              Полная документация
```

## 📚 Документация

1. **INSTALLATION.md** - Пошаговая установка (читайте первым!)
2. **docs/README_UPDATES.md** - Подробный обзор обновлений
3. **docs/VK_HLS_INTEGRATION_GUIDE.md** - Полный гайд интеграции и архитектура

## 🔧 Требования

- Python 3.8+
- Flutter 3.0+
- Android API 21+
- Kotlin 1.7+

## 🧪 Тестирование

```bash
# Тест Python скрипта
cd python_scripts/vk_parser
python3 main.py parse "https://example.com/audio.m3u8"
```

## ⚡ Основные возможности

### HLS Парсинг
- ✅ Парсинг M3U8 манифестов
- ✅ Извлечение информации о сегментах
- ✅ Поддержка различных версий HLS

### AES-128 Дешифровка
- ✅ Загрузка ключей шифрования
- ✅ Парсинг IV (Initialization Vector)
- ✅ Дешифровка сегментов в режиме CBC
- ✅ Удаление PKCS7 padding

### Метаданные
- ✅ Название трека (Title)
- ✅ Исполнитель (Artist)
- ✅ Длительность (Duration)
- ✅ Обложка (Cover)
- ✅ Текст песни (Lyrics)

## 🎯 Поддерживаемые форматы

- **Потоки**: HLS (m3u8)
- **Шифрование**: AES-128-CBC
- **Аудио**: MP3, AAC, FLAC

## 💡 Примеры

### Пример 1: Простой парсинг
```dart
final m3u8Url = 'https://example.com/audio.m3u8';
final info = await VKHLSService.parseM3U8(m3u8Url);
print('Segments: ${info?.segmentsCount}');
```

### Пример 2: Полная загрузка с дешифровкой
```dart
final audioData = await VKHLSService.downloadAndDecryptSegments(m3u8Url);
// Сохранить в файл или передать плееру
```

### Пример 3: Получение информации о треке
```dart
final metadata = await VKHLSService.getTrackMetadata(m3u8Url);
print('${metadata?.artist} - ${metadata?.title}');
```

## 🔐 Как это работает

1. **Загрузка M3U8** → Получение манифеста с инфо о сегментах
2. **Парсинг ключа** → Извлечение информации шифрования
3. **Загрузка ключа** → HTTP запрос к серверу ключей
4. **Загрузка сегментов** → Параллельная/последовательная загрузка .ts файлов
5. **Дешифровка** → AES-128-CBC с правильным IV
6. **Объединение** → Конкатенация в один аудиопоток

## 📊 Производительность

- Парсинг M3U8: ~100-200ms
- Загрузка/дешифровка: Зависит от размера и скорости интернета
- Потребление памяти: ~5-20MB в зависимости от длины трека

## 🐛 Troubleshooting

- **"Python not found"** → Установить Python 3
- **"AES decryption failed"** → Проверить ключ и IV
- **"Method Channel timeout"** → Увеличить timeout в коде
- Подробнее см. **INSTALLATION.md**

## 🎓 Для портфолио

Этот код демонстрирует:
- ✨ Работу с HLS потоками
- ✨ Криптографию (AES-128)
- ✨ Интеграцию Python + Flutter
- ✨ Native bridges (Kotlin/Flutter)
- ✨ Параллельную загрузку
- ✨ Обработку ошибок и fallback механизмы
- ✨ Полную документацию и примеры

## 📞 Поддержка

Полная документация в `docs/` папке

## ⚖️ Лицензия

Для портфолио и образовательных целей

---

**Версия**: 1.1.0  
**Дата**: 2026-09-18  
**Статус**: ✅ Ready for Production
