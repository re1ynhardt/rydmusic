# RydMusic - VK HLS Parser & AES-128 Decryption Update

## 🎵 Что добавлено

Полная поддержка парсинга и дешифровки аудиотреков из ВКонтакте через HLS потоки с AES-128-CBC шифрованием.

## 📁 Структура файлов

```
project/
├── python_scripts/
│   └── vk_parser/
│       ├── hls_parser.py          # Парсер M3U8 + AES-128 дешифровка
│       ├── vk_metadata.py         # Экстрактор метаданных трека
│       ├── main.py                # Главный мост Flutter <-> Python
│       └── requirements.txt        # Python зависимости
│
├── lib/
│   └── services/
│       ├── vk_hls_service.dart    # Dart сервис для HLS операций
│       └── vk_service_updated.dart # Обновленный VK сервис
│
├── android/
│   └── app/src/main/kotlin/com/example/rydmusic/
│       └── VKHLSBridge.kt         # Android Method Channel мост
│
└── Документация/
    ├── VK_HLS_INTEGRATION_GUIDE.md # Подробный гайд интеграции
    └── README_UPDATES.md           # Этот файл
```

## 🚀 Быстрый старт

### 1. Установка Python зависимостей

```bash
cd python_scripts/vk_parser
pip install -r requirements.txt
```

### 2. Копирование файлов в проект

```bash
# Копировать Dart сервисы
cp lib/services/vk_hls_service.dart <YOUR_PROJECT>/lib/services/
cp lib/services/vk_service_updated.dart <YOUR_PROJECT>/lib/services/

# Копировать Python скрипты
cp -r python_scripts/vk_parser <YOUR_PROJECT>/python_scripts/

# Копировать Kotlin код
cp android/app/src/main/kotlin/com/example/rydmusic/VKHLSBridge.kt \
   <YOUR_PROJECT>/android/app/src/main/kotlin/com/example/rydmusic/
```

### 3. Обновить pubspec.yaml

Добавить Python скрипты в assets:

```yaml
flutter:
  assets:
    - python_scripts/vk_parser/hls_parser.py
    - python_scripts/vk_parser/vk_metadata.py
    - python_scripts/vk_parser/main.py
    - python_scripts/vk_parser/requirements.txt
```

### 4. Обновить Android MainActivity

```kotlin
import com.example.rydmusic.VKHLSBridge

class MainActivity: FlutterActivity() {
    private lateinit var vkHLSBridge: VKHLSBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        vkHLSBridge = VKHLSBridge(this)
        vkHLSBridge.setupChannel(flutterEngine)
    }

    override fun onDestroy() {
        vkHLSBridge.cleanup()
        super.onDestroy()
    }
}
```

## 📖 Использование

### Пример 1: Парсинг M3U8 манифеста

```dart
import 'services/vk_hls_service.dart';

final m3u8Url = 'https://example.com/audio.m3u8';
final playlistInfo = await VKHLSService.parseM3U8(m3u8Url);

if (playlistInfo != null) {
  print('Версия: ${playlistInfo.version}');
  print('Сегментов: ${playlistInfo.segmentsCount}');
  print('Длительность: ${playlistInfo.totalDuration}s');
  print('Размер: ${playlistInfo.audioSize} байт');
}
```

### Пример 2: Загрузка и дешифровка

```dart
// Загрузить и расшифровать сегменты
final audioData = await VKHLSService.downloadAndDecryptSegments(m3u8Url);

if (audioData != null) {
  print('Загружено ${audioData.length} байт');
  // Можно сохранить в файл или передать плееру
}
```

### Пример 3: Получение метаданных

```dart
final metadata = await VKHLSService.getTrackMetadata(m3u8Url);

if (metadata != null) {
  print('Название: ${metadata.title}');
  print('Исполнитель: ${metadata.artist}');
  print('Длительность: ${metadata.duration}s');
  print('Обложка: ${metadata.coverUrl}');
}
```

### Пример 4: Полная интеграция в VK сервис

```dart
import 'services/vk_service_updated.dart';

final vkService = VkService();

// Поиск трека
final tracks = await vkService.search('The Beatles');

// Получение потока (автоматически парсит HLS если нужно)
final resolvedTrack = await vkService.resolveStreamUrl(tracks.first);

// Теперь трек содержит корректный streamUrl, метаданные и обложку
print('Готов к воспроизведению: ${resolvedTrack.title}');
```

## 🔐 Как работает дешифровка

### HLS + AES-128-CBC процесс

1. **Загрузка M3U8** - Получение манифеста с информацией о сегментах
2. **Парсинг ключа** - Извлечение URL и параметров шифрования из `#EXT-X-KEY` тега
3. **Загрузка ключа** - HTTP запрос к серверу ключей
4. **Загрузка сегментов** - Последовательная загрузка `.ts` файлов
5. **Дешифровка** - Применение AES-128-CBC с правильным IV
6. **Объединение** - Конкатенация дешифрованных сегментов в один аудиопоток

### Пример M3U8 манифеста

```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="https://vk.com/key.bin",IV=0x12345678
#EXTINF:6.0,
https://vk.com/audio/segment1.ts
#EXTINF:6.0,
https://vk.com/audio/segment2.ts
```

## 🧪 Тестирование

### Тест Python скриптов командной строкой

```bash
cd python_scripts/vk_parser

# Парсинг M3U8
python3 main.py parse "https://example.com/audio.m3u8"

# Загрузка и дешифровка
python3 main.py download "https://example.com/audio.m3u8" --output audio.mp3

# Получение метаданных
python3 main.py metadata "https://example.com/audio.m3u8"

# Загрузка обложки
python3 main.py cover "https://example.com/cover.jpg" --output cover.jpg
```

### Тест в Dart

```dart
void testVKHLSIntegration() async {
  const testUrl = 'https://example.com/audio.m3u8';
  
  // Парсинг
  print('Тест парсинга M3U8...');
  final info = await VKHLSService.parseM3U8(testUrl);
  assert(info != null, 'FAILED: parseM3U8');
  print('✓ Парсинг успешен: ${info!.segmentsCount} сегментов');
  
  // Метаданные
  print('Тест получения метаданных...');
  final metadata = await VKHLSService.getTrackMetadata(testUrl);
  assert(metadata != null, 'FAILED: getTrackMetadata');
  print('✓ Метаданные: ${metadata!.title} - ${metadata.artist}');
  
  // Загрузка
  print('Тест загрузки и дешифровки...');
  final audio = await VKHLSService.downloadAndDecryptSegments(testUrl);
  assert(audio != null && audio.isNotEmpty, 'FAILED: downloadAndDecryptSegments');
  print('✓ Загрузка успешна: ${audio!.length} байт');
}
```

## ⚙️ Конфигурация

### Timeout и retry

Можно настроить в `hls_parser.py`:

```python
# requests session timeout
response = self.session.get(url, timeout=10)  # 10 секунд

# Retry логика (можно добавить с использованием urllib3.Retry)
```

### Параллельная загрузка сегментов

Для оптимизации скорости можно использовать `asyncio` в Python:

```python
import asyncio
import aiohttp

async def download_segments_parallel(playlist):
    async with aiohttp.ClientSession() as session:
        tasks = [download_segment(session, seg) for seg in playlist.segments]
        return await asyncio.gather(*tasks)
```

## 🐛 Troubleshooting

### "Python not found"

Убедитесь, что Python 3 установлен:
```bash
python3 --version
```

### "AES decryption failed"

- Проверьте, что ключ загружается корректно
- Убедитесь в правильности IV парсинга
- Проверьте целостность данных сегментов

### "Method Channel timeout"

- Увеличьте timeout в Kotlin коде
- Проверьте, что Python скрипты скопированы в assets
- Убедитесь, что все зависимости установлены

### "Empty response from Python"

- Проверьте логи Python скрипта
- Убедитесь в правильности переданного URL
- Проверьте доступ в Интернет

## 📊 Производительность

### Оптимизации

1. **Кэширование ключей** - Ключи кэшируются в памяти
2. **Потоковая обработка** - Сегменты дешифруются по мере загрузки
3. **Параллельные запросы** - Можно добавить параллельную загрузку

### Рекомендуемые настройки

- Максимум 3-5 параллельных загрузок сегментов
- Кэширование дешифрованных данных на диск
- Timeout 30 секунд для больших файлов

## 🔄 Интеграция с существующим кодом

### Замена VK сервиса

Вместо использования `lib/services/vk_service.dart`, используйте `vk_service_updated.dart`:

```dart
// Старый код:
import 'services/vk_service.dart';

// Новый код:
import 'services/vk_service_updated.dart';

// Использование остается тем же:
final vkService = VkService();
final tracks = await vkService.search('query');
```

### Fallback механизм

Если native Method Channel недоступен, код автоматически использует Python через common bridge.

## 📝 Лицензия

Этот код является частью портфолио проекта.

## 🎯 Что дальше?

1. ✅ Добавлена полная поддержка HLS парсинга
2. ✅ Реализована AES-128-CBC дешифровка
3. ✅ Добавлено получение метаданных
4. 🔄 TODO: Кэширование на диск
5. 🔄 TODO: iOS реализация
6. 🔄 TODO: Поддержка других форматов шифрования
7. 🔄 TODO: Потоковое воспроизведение

## 📧 Поддержка

Для вопросов см. файл `VK_HLS_INTEGRATION_GUIDE.md`

---

**Дата обновления**: 2026-09-18
**Версия**: 1.1.0
**Статус**: Ready for Portfolio
